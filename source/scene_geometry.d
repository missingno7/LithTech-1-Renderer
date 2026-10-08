module SceneGeometry;

/+
 + Per-frame geometry of the scene's objects (models now; sprites, particles etc. later), built on the CPU during
 + RenderScene in world space and drawn after the world by SwapBuffers.
 +/

import erupted;

struct ObjectVertex
{
	float[3] pos; // world space
	float[4] colour; // 0..1, alpha included
	float[2] uv; // normalised (0..1 across the texture), as d3d.ren hands them to D3D

	static VkVertexInputBindingDescription GetBindingDescription()
	{
		VkVertexInputBindingDescription description={
			binding: 0,
			stride: ObjectVertex.sizeof,
			inputRate: VK_VERTEX_INPUT_RATE_VERTEX
		};
		return description;
	}

	static VkVertexInputAttributeDescription[3] GetAttributeDescriptions()
	{
		return [
			VkVertexInputAttributeDescription(0, 0, VK_FORMAT_R32G32B32_SFLOAT, pos.offsetof),
			VkVertexInputAttributeDescription(1, 0, VK_FORMAT_R32G32B32A32_SFLOAT, colour.offsetof),
			VkVertexInputAttributeDescription(2, 0, VK_FORMAT_R32G32_SFLOAT, uv.offsetof)
		];
	}
}

struct ObjectBatch
{
	VkDescriptorSet texture; // VK_NULL_ND_HANDLE: the renderer's dummy texture
	uint first_vertex;
	uint vertex_count;
}

// d3d.ren flushes solid objects before translucent ones and sorts neither (port ABI section 5)
struct ObjectGeometry
{
	ObjectVertex[] vertices;
	ObjectBatch[] solid;
	ObjectBatch[] translucent;

	void Clear()
	{
		vertices.length=0;
		vertices.assumeSafeAppend();
		solid.length=0;
		solid.assumeSafeAppend();
		translucent.length=0;
		translucent.assumeSafeAppend();
	}

	// opens a batch; vertices appended until the next Begin belong to it
	void Begin(VkDescriptorSet texture, bool is_translucent)
	{
		ObjectBatch batch={ texture: texture, first_vertex: cast(uint)vertices.length, vertex_count: 0 };
		if (is_translucent)
			translucent~=batch;
		else
			solid~=batch;
		_current_translucent=is_translucent;
	}

	void Add(const ref ObjectVertex vertex)
	{
		vertices~=vertex;
		(_current_translucent ? translucent : solid)[$-1].vertex_count++;
	}

	// drops the current batch if nothing was added to it
	void End()
	{
		ObjectBatch[]* list=_current_translucent ? &translucent : &solid;
		if ((*list).length && (*list)[$-1].vertex_count==0)
			(*list).length--;
	}

private:
	bool _current_translucent;
}
