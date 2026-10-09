module Memory;

import erupted;

import VulkanRender: g_VkInstance, g_Device, g_PhysicalDevice, g_PhysicalDeviceProps, g_PhysicalMemoryProps, test_out;

// Maximum size of a memory heap in Vulkan to consider it "small".
immutable VkDeviceSize VMA_SMALL_HEAP_MAX_SIZE=512*1024*1024;
// Default size of a block allocated as single VkDeviceMemory from a "large" heap.
immutable VkDeviceSize VMA_DEFAULT_LARGE_HEAP_BLOCK_SIZE=256*1024*1024;
// Default size of a block allocated as single VkDeviceMemory from a "small" heap.
immutable VkDeviceSize VMA_DEFAULT_SMALL_HEAP_BLOCK_SIZE=64*1024*1024;

struct SubAllocation
{
	VkDeviceSize offset;
	VkDeviceSize size;
}

// one VkDeviceMemory, handed out in ranges kept sorted by offset; host-visible blocks stay mapped
class Allocation
{
	VkDeviceMemory memory;
	VkDeviceSize size;
	uint type_index;
	bool dedicated; // holds a single resource and is freed with it
	void* mapped;

	SubAllocation[] suballocs;

	static Allocation Create(uint memory_type_index, VkDeviceSize block_size, bool dedicated)
	{
		VkMemoryAllocateInfo alloc_info={
			allocationSize: block_size,
			memoryTypeIndex: memory_type_index
		};

		VkDeviceMemory memory;
		VkResult res=vkAllocateMemory(g_Device, &alloc_info, null, &memory);
		if (res!=VK_SUCCESS)
		{
			test_out.writeln("vkAllocateMemory failed: ", res, ", ", block_size, " bytes, type ", memory_type_index);
			test_out.flush();
			return null;
		}

		Allocation block=new Allocation();
		block.memory=memory;
		block.size=block_size;
		block.type_index=memory_type_index;
		block.dedicated=dedicated;

		if (g_PhysicalMemoryProps.memoryTypes[memory_type_index].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
		{
			if (vkMapMemory(g_Device, memory, 0, VK_WHOLE_SIZE, 0, &block.mapped)!=VK_SUCCESS)
				block.mapped=null;
		}

		debug { test_out.writeln("New memory block: ", block_size, " bytes, type ", memory_type_index, dedicated ? " (dedicated)" : ""); test_out.flush(); }
		return block;
	}

	void Release()
	{
		if (mapped!=null)
			vkUnmapMemory(g_Device, memory);
		vkFreeMemory(g_Device, memory, null);
		memory=VK_NULL_ND_HANDLE;
		mapped=null;
		suballocs=null;
	}

	@property bool empty() const { return suballocs.length==0; }

	// first fit: the lowest aligned gap that holds size bytes
	bool Chunk(VkDeviceSize req_size, VkDeviceSize align_, out VkMappedMemoryRange alloc_out)
	{
		if (align_==0)
			align_=1;

		VkDeviceSize gap_start=0;
		foreach(i; 0..suballocs.length+1)
		{
			const VkDeviceSize gap_end=(i<suballocs.length) ? suballocs[i].offset : size;
			const VkDeviceSize offset=VmaAlignUp(gap_start, align_);

			if (offset<=gap_end && gap_end-offset>=req_size)
			{
				SubAllocation sub_alloc={ offset: offset, size: req_size };

				import std.array: insertInPlace;
				suballocs.insertInPlace(i, sub_alloc);

				alloc_out.memory=memory;
				alloc_out.offset=offset;
				alloc_out.size=req_size;
				return true;
			}

			if (i<suballocs.length)
				gap_start=suballocs[i].offset+suballocs[i].size;
		}

		return false;
	}

	bool Free(VkDeviceSize offset)
	{
		foreach(i, ref sub_alloc; suballocs)
		{
			if (sub_alloc.offset==offset)
			{
				import std.algorithm: remove;
				suballocs=suballocs.remove(i);
				return true;
			}
		}
		return false;
	}

	VkDeviceSize UsedMemory() const
	{
		VkDeviceSize used=0;
		foreach(ref sub_alloc; suballocs)
			used+=sub_alloc.size;
		return used;
	}
}

__gshared Allocator g_Allocator;

class Allocator
{
	VkDeviceSize m_PreferredLargeHeapBlockSize=VMA_DEFAULT_LARGE_HEAP_BLOCK_SIZE;
	VkDeviceSize m_PreferredSmallHeapBlockSize=VMA_DEFAULT_SMALL_HEAP_BLOCK_SIZE;

	Allocation[][VK_MAX_MEMORY_TYPES] allocs;

	VkMappedMemoryRange[VkBuffer] m_BufferToMemoryMap;
	VkMappedMemoryRange[VkImage] m_ImageToMemoryMap;

	static Allocator GetAllocator()
	{
		if (g_Allocator is null)
			g_Allocator=new Allocator();
		return g_Allocator;
	}

	// from the first memory type that has the properties; if the driver refuses a block there (small device-local
	// heaps on integrated GPUs), from smaller blocks, then from the next matching type
	VkResult Allocate(const VkMemoryRequirements mem_reqs, const VkMemoryPropertyFlags mem_props, out VkMappedMemoryRange memory_range)
	{
		uint tried_types=0;
		for (;;)
		{
			const uint mem_type_index=FindMemoryType(g_PhysicalMemoryProps, mem_reqs.memoryTypeBits & ~tried_types, mem_props);
			if (mem_type_index==uint.max)
			{
				test_out.writeln("No memory type for bits ", mem_reqs.memoryTypeBits, ", properties ", mem_props);
				test_out.flush();
				return VK_ERROR_OUT_OF_DEVICE_MEMORY;
			}
			if (AllocateFromType(mem_type_index, mem_reqs, memory_range))
				return VK_SUCCESS;
			tried_types|=1u << mem_type_index;
		}
	}

	private bool AllocateFromType(uint mem_type_index, const VkMemoryRequirements mem_reqs, out VkMappedMemoryRange memory_range)
	{
		// linear buffers and optimal images can share a block, so keep them a granularity apart
		VkDeviceSize alignment=mem_reqs.alignment;
		const VkDeviceSize granularity=g_PhysicalDeviceProps.limits.bufferImageGranularity;
		if (granularity>alignment)
			alignment=granularity;

		const VkDeviceSize block_size=GetPreferredBlockSize(mem_type_index);

		if (mem_reqs.size>block_size/2)
		{
			Allocation dedicated=Allocation.Create(mem_type_index, mem_reqs.size, true);
			if (dedicated is null || !dedicated.Chunk(mem_reqs.size, 1, memory_range))
				return false;
			allocs[mem_type_index]~=dedicated;
			return true;
		}

		foreach(block; allocs[mem_type_index])
		{
			if (!block.dedicated && block.Chunk(mem_reqs.size, alignment, memory_range))
				return true;
		}

		for (VkDeviceSize size=block_size; ; size/=2)
		{
			if (size<mem_reqs.size+alignment)
				size=mem_reqs.size+alignment;
			Allocation new_block=Allocation.Create(mem_type_index, size, false);
			if (new_block !is null)
			{
				if (!new_block.Chunk(mem_reqs.size, alignment, memory_range))
				{
					new_block.Release();
					return false;
				}
				allocs[mem_type_index]~=new_block;
				return true;
			}
			if (size<=mem_reqs.size+alignment || size<=4*1024*1024)
				return false;
		}
	}

	void Free(ref const VkMappedMemoryRange memory_range)
	{
		if (memory_range.memory==VK_NULL_ND_HANDLE)
			return;

		foreach(type_index, ref blocks; allocs)
		{
			foreach(i, block; blocks)
			{
				if (block.memory!=memory_range.memory)
					continue;

				if (!block.Free(memory_range.offset))
				{
					test_out.writeln("Freeing an unknown range: ", memory_range);
					test_out.flush();
				}

				// release dedicated blocks, and empty blocks beyond the first of their type
				if (block.empty && (block.dedicated || blocks.length>1))
				{
					block.Release();
					import std.algorithm: remove;
					blocks=blocks.remove(i);
				}
				return;
			}
		}
	}

	void* Mapped(ref const VkMappedMemoryRange memory_range)
	{
		foreach(ref blocks; allocs)
			foreach(block; blocks)
				if (block.memory==memory_range.memory)
					return (block.mapped!=null) ? block.mapped+cast(size_t)memory_range.offset : null;
		return null;
	}

	void LogUsage()
	{
		foreach(type_index, ref blocks; allocs)
		{
			if (blocks.length==0)
				continue;

			VkDeviceSize used=0, total=0;
			foreach(block; blocks)
			{
				used+=block.UsedMemory();
				total+=block.size;
			}
			test_out.writeln("Memory type ", type_index, ": ", blocks.length, " blocks, ", used/1024, " / ", total/1024, " KB used");
		}
		test_out.flush();
	}

	void ReleaseAll()
	{
		foreach(ref blocks; allocs)
		{
			foreach(block; blocks)
				block.Release();
			blocks=null;
		}
		m_BufferToMemoryMap=null;
		m_ImageToMemoryMap=null;
	}

	VkDeviceSize GetPreferredBlockSize(uint32_t memTypeIndex) const
	{
		VkDeviceSize heapSize = g_PhysicalMemoryProps.memoryHeaps[g_PhysicalMemoryProps.memoryTypes[memTypeIndex].heapIndex].size;
		return (heapSize <= VMA_SMALL_HEAP_MAX_SIZE) ? m_PreferredSmallHeapBlockSize : m_PreferredLargeHeapBlockSize;
	}

	uint32_t GetMemoryHeapCount() const { return g_PhysicalMemoryProps.memoryHeapCount; }
	uint32_t GetMemoryTypeCount() const { return g_PhysicalMemoryProps.memoryTypeCount; }
}

// Taken from Vulkan spec
// Find a memory in `memoryTypeBitsRequirement` that includes all of `requiredProperties`
uint FindMemoryType(ref const VkPhysicalDeviceMemoryProperties pMemoryProperties,
	uint memoryTypeBitsRequirement,
	VkMemoryPropertyFlags requiredProperties)
{
	const uint memoryCount = pMemoryProperties.memoryTypeCount;

	for (size_t memoryIndex = 0; memoryIndex < memoryCount; ++memoryIndex)
	{
		const uint memoryTypeBits = (1 << memoryIndex);
		const bool isRequiredMemoryType = cast(bool)(memoryTypeBitsRequirement & memoryTypeBits);
		const VkMemoryPropertyFlags properties=pMemoryProperties.memoryTypes[memoryIndex].propertyFlags;

		const bool hasRequiredProperties = (properties & requiredProperties) == requiredProperties;

		if (isRequiredMemoryType && hasRequiredProperties)
			return cast(uint)(memoryIndex);
	}

	// failed to find memory type
	return uint.max;
}

// Aligns given value up to nearest multiply of align value. For example: VmaAlignUp(11, 8) = 16.
// Use types like uint32_t, uint64_t as T.
pragma(inline) T VmaAlignUp(T)(T val, T align_)
{
	return (val + align_ - 1) / align_ * align_;
}

// Division with mathematical rounding to nearest number.
pragma(inline) T VmaRoundDiv(T)(T x, T y)
{
	return (x + (y / cast(T)2)) / y;
}

// host-visible blocks are mapped once for their lifetime (a VkDeviceMemory can only be mapped once at a time,
// and blocks are shared), so this hands out a pointer into that mapping and unmapping does nothing
VkResult vmaMapMemory(ref const VkMappedMemoryRange pMemory, void** ppData)
{
	*ppData=(g_Allocator !is null) ? g_Allocator.Mapped(pMemory) : null;
	return (*ppData!=null) ? VK_SUCCESS : VK_ERROR_MEMORY_MAP_FAILED;
}

void vmaUnmapMemory(ref const VkMappedMemoryRange pMemory)
{
}

// on failure the buffer is VK_NULL_HANDLE and the failure is logged, instead of binding memory that isn't there
void CreateAllocBuffer(
	Allocator alloc,
	const VkBufferCreateInfo create_info,
	VkMemoryPropertyFlags properties,
	out VkBuffer buffer,
	VkMappedMemoryRange* pMemory,
	uint* memory_type_index)
{
	if (pMemory!=null) *pMemory=VkMappedMemoryRange.init;

	VkResult res=vkCreateBuffer(g_Device, &create_info, null, &buffer);
	if (res!=VK_SUCCESS)
	{
		test_out.writeln("vkCreateBuffer failed: ", res, ", ", create_info.size, " bytes");
		test_out.flush();
		buffer=VK_NULL_ND_HANDLE;
		return;
	}

	VkMemoryRequirements memory_reqs;
	vkGetBufferMemoryRequirements(g_Device, buffer, &memory_reqs);

	VkMappedMemoryRange buf_alloc;
	res=alloc.Allocate(memory_reqs, properties, buf_alloc);
	if (res==VK_SUCCESS)
		res=vkBindBufferMemory(g_Device, buffer, buf_alloc.memory, buf_alloc.offset);

	if (res!=VK_SUCCESS)
	{
		test_out.writeln("Buffer allocation failed: ", res, ", ", memory_reqs.size, " bytes, properties ", properties);
		alloc.LogUsage();
		alloc.Free(buf_alloc);
		vkDestroyBuffer(g_Device, buffer, null);
		buffer=VK_NULL_ND_HANDLE;
		return;
	}

	if (pMemory!=null) *pMemory=buf_alloc;

	alloc.m_BufferToMemoryMap[buffer]=buf_alloc;
}

void CreateAllocImage(
	Allocator alloc,
	const VkImageCreateInfo create_info,
	VkMemoryPropertyFlags properties,
	out VkImage image,
	VkMappedMemoryRange* pMemory,
	uint* memory_type_index)
{
	if (pMemory!=null) *pMemory=VkMappedMemoryRange.init;

	VkResult res=vkCreateImage(g_Device, &create_info, null, &image);
	if (res!=VK_SUCCESS)
	{
		test_out.writeln("vkCreateImage failed: ", res, ", ", create_info.extent.width, "x", create_info.extent.height);
		test_out.flush();
		image=VK_NULL_ND_HANDLE;
		return;
	}

	VkMemoryRequirements memory_reqs;
	vkGetImageMemoryRequirements(g_Device, image, &memory_reqs);

	VkMappedMemoryRange buf_alloc;
	res=alloc.Allocate(memory_reqs, properties, buf_alloc);
	if (res==VK_SUCCESS)
		res=vkBindImageMemory(g_Device, image, buf_alloc.memory, buf_alloc.offset);

	if (res!=VK_SUCCESS)
	{
		test_out.writeln("Image allocation failed: ", res, ", ", create_info.extent.width, "x", create_info.extent.height, ", ", memory_reqs.size, " bytes");
		alloc.LogUsage();
		alloc.Free(buf_alloc);
		vkDestroyImage(g_Device, image, null);
		image=VK_NULL_ND_HANDLE;
		return;
	}

	if (pMemory!=null) *pMemory=buf_alloc;

	alloc.m_ImageToMemoryMap[image]=buf_alloc;
}

// destroy a buffer made by CreateAllocBuffer and give its range back
void DestroyAllocBuffer(Allocator alloc, ref VkBuffer buffer)
{
	if (buffer==VK_NULL_ND_HANDLE)
		return;

	vkDestroyBuffer(g_Device, buffer, null);
	if (alloc !is null)
	{
		if (VkMappedMemoryRange* range=buffer in alloc.m_BufferToMemoryMap)
		{
			alloc.Free(*range);
			alloc.m_BufferToMemoryMap.remove(buffer);
		}
	}
	buffer=VK_NULL_ND_HANDLE;
}

void DestroyAllocImage(Allocator alloc, ref VkImage image)
{
	if (image==VK_NULL_ND_HANDLE)
		return;

	vkDestroyImage(g_Device, image, null);
	if (alloc !is null)
	{
		if (VkMappedMemoryRange* range=image in alloc.m_ImageToMemoryMap)
		{
			alloc.Free(*range);
			alloc.m_ImageToMemoryMap.remove(image);
		}
	}
	image=VK_NULL_ND_HANDLE;
}
