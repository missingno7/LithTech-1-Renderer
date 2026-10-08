module VulkanRender;

//import vk.Device; // never committed upstream
import Memory;

//import vk_mem_alloc;

import erupted;
import vulkan_windows;

import std.stdio;
import core.sys.windows.windows;

import gl3n.linalg;
import gl3n.math;

import RendererMain;
import RendererTypes;
import Texture;
import vk.Surface: ImageSurface;
import WorldBsp: WorldBsp, MainWorld, Node, SurfaceFlags, Polygon;

File test_out; //import Main: test_out;

VkDebugUtilsMessengerEXT debug_messenger;

extern(Windows)
VkBool32 DebugCallback(VkDebugUtilsMessageSeverityFlagBitsEXT severity,
		VkDebugUtilsMessageTypeFlagsEXT type,
		const VkDebugUtilsMessengerCallbackDataEXT* callback_data,
		void* user_data) nothrow @nogc
{
	debug
	{
		import std.string: fromStringz;
		test_out.writeln(callback_data.pMessage.fromStringz);
	}
	return VK_FALSE;
}

// Logs a Vulkan result (flushed, so it survives a crash); on failure tells the user why before bailing out
VkResult VkCheck(VkResult result, string what)
{
	import std.conv: to;
	import std.string: toStringz;

	test_out.writeln(what, ": ", result);
	test_out.flush();

	if (result<VK_SUCCESS)
	{
		string message=what~" failed: "~result.to!string;
		MessageBoxA(null, message.toStringz, "d_ren", MB_ICONERROR);
		throw new Error(message);
	}

	return result;
}

enum uint MaxLightCount=40;

struct LightObj
{
	this(vec3 pos, vec3 colour, float radius)
	{
		this.pos=pos;
		this.colour=colour;
		this.radius=radius;
	}

	vec3 pos;
	private float pad;
	vec3 colour;
	float radius;
}

struct LightListUbo
{
	uint count;
	private float[3] pad;
	LightObj[MaxLightCount] lights;
}

VkBuffer[] _light_list_ubo;
VkMappedMemoryRange[] _light_list_ubo_memory;

struct UniformBufferObject
{
	mat4 model;
	mat4 view;
	mat4 proj;
}

struct Vertex
{
	vec3 pos;
	vec3 colour;
	vec2 uv;

	static VkVertexInputBindingDescription GetBindingDescription()
	{
		VkVertexInputBindingDescription binding_description={
			binding: 0,
			stride: Vertex.sizeof,
			inputRate: VK_VERTEX_INPUT_RATE_VERTEX
		};
		return binding_description;
	}

	static VkVertexInputAttributeDescription[] GetAttributeDescriptions()
	{
		VkVertexInputAttributeDescription[] attribute_descriptions=[
			{
				binding: 0,
				location: 0,
				format: VK_FORMAT_R32G32B32_SFLOAT,
				offset: pos.offsetof
			},
			{
				binding: 0,
				location: 1,
				format: VK_FORMAT_R32G32B32_SFLOAT,
				offset: colour.offsetof
			},
			{
				binding: 0,
				location: 2,
				format: VK_FORMAT_R32G32_SFLOAT,
				offset: uv.offsetof
			},
		];
		return attribute_descriptions;
	}

	static VkVertexInputAttributeDescription[] GetAttributeDescriptions2()
	{
		import std.traits;

		VkFormat GetVkFormatFromType(const size_t type) // FIXME: yes, this is really fucking stupid
		{
			switch(type)
			{
				case 1:
					return VK_FORMAT_R8_SNORM;

				case 2:
					return VK_FORMAT_R16_SNORM;

				case 4:
					return VK_FORMAT_R32_SFLOAT;

				case 8:
					return VK_FORMAT_R32G32_SFLOAT;

				case 12:
					return VK_FORMAT_R32G32B32_SFLOAT;

				default:
					return VK_FORMAT_UNDEFINED; // this will trigger the debug layers
			}
		}

		VkVertexInputAttributeDescription[] attribute_descriptions=new VkVertexInputAttributeDescription[0];

		foreach(i, m; __traits(allMembers, Vertex))
		{
			static if (!isFunction!(__traits(getMember, Vertex, m)))
			{
				VkVertexInputAttributeDescription new_;
				new_.binding=0;
				new_.location=i; // I don't think this works if there's larger than 128 bit values, eg. an array of something
				new_.format=GetVkFormatFromType(typeof(__traits(getMember, Vertex, m)).sizeof);
				new_.offset=__traits(getMember, Vertex, m).offsetof;

				attribute_descriptions~=new_;
			}
		}

		return attribute_descriptions;
	}
}

// Test stuff only!
const Vertex[] _test_triangle=[
	{ [-500f, -500f, 0f], [1f, 0f, 0f], [0f, 0f] },
	{ [500f, -500f, 0f], [0f, 1f, 0f], [0f, 0f] },
	{ [500f, 500f, 0f], [1f, 0f, 1f], [0f, 0f] },
	{ [-500f, 500f, 0f], [0f, 0f, 1f], [0f, 0f] },

	{ [-500f, 500f, -500f], [1f, 1f, 1f],  [0f, 0f] },
	{ [-500f, -500f, -500f], [1f, 1f, 1f], [0f, 0f] },
	{ [500f, 500f, -500f], [1f, 1f, 1f], [0f, 0f] },
	{ [500f, -500f, -500f], [1f, 1f, 1f],  [0f, 0f] }
];
const uint[] _test_triangle_indices=[0, 1, 2, 3, 4, 5, 6, 7];

struct SwapchainBuffer
{
	VkImage image;
	VkImageView view;
	VkFramebuffer framebuffer;
}

__gshared VkInstance g_VkInstance;
__gshared VkPhysicalDevice g_PhysicalDevice;
__gshared VkPhysicalDeviceProperties g_PhysicalDeviceProps;
__gshared VkPhysicalDeviceMemoryProperties g_PhysicalMemoryProps;
__gshared VkDevice g_Device;

class VulkanRenderer : Renderer
{
	enum uint Width=640;
	enum uint Height=480;

private:
	VkQueue _graphics_queue;
	VkQueue _present_queue;
	VkSurfaceKHR _surface;

	VkFormat _format;
	VkColorSpaceKHR _colour_space;
	VkExtent2D _extents;

	VkSwapchainKHR _swapchain;

	VkImage[] _images;
	SwapchainBuffer[] _buffers;

	VkCommandPool _command_pool;
	VkCommandBuffer[] _command_buffers;

	VkShaderModule vk_vertex_shader;
	VkShaderModule vk_frag_shader;

	VkRenderPass _render_pass;
	VkPipelineLayout _pipeline_layout;

	VkPipeline _pipeline;

	VkSemaphore _is_image_available;
	VkSemaphore _is_render_finished;

	VkBuffer _vertex_buffer;
	VkMappedMemoryRange _vertex_buffer_memory;

	VkBuffer _vertex_index_buffer;
	VkMappedMemoryRange _vertex_index_memory;

	VkImage _depth_image;
	VkMappedMemoryRange _depth_image_memory;
	VkImageView _depth_image_view;

	VkDescriptorSet _texture_descriptor;

public:
	override void Destroy()
	{
		vkDeviceWaitIdle(g_Device);
		DestroyOverlay();

		vkDestroyBuffer(g_Device, _vertex_buffer, null);
		vkFreeMemory(g_Device, _vertex_buffer_memory.memory, null);

		foreach(ref buffer; _buffers)
			vkDestroyFramebuffer(g_Device, buffer.framebuffer, null);

		vkDestroyPipeline(g_Device, _pipeline, null);

		vkDestroyPipelineLayout(g_Device, _pipeline_layout, null);
		vkDestroyRenderPass(g_Device, _render_pass, null);

		vkDestroyShaderModule(g_Device, vk_vertex_shader, null);
		vkDestroyShaderModule(g_Device, vk_frag_shader, null);

		foreach(ref buffer; _buffers)
			vkDestroyImageView(g_Device, buffer.view, null);

		vkDestroySwapchainKHR(g_Device, _swapchain, null);
		vkDestroyDevice(g_Device, null);
		vkDestroySurfaceKHR(g_VkInstance, _surface, null);
		vkDestroyInstance(g_VkInstance, null);
		test_out.close();
	}

	override void InitFrom(void* window)
	{
		test_out.open("vk_test.txt", "w");

		import erupted.vulkan_lib_loader;
		loadGlobalLevelFunctions(test_out.getFP());

		{
			/+
			 + possible avenue for replacing the window with a 32 bit pixel format: GetWindowLong(window, GWL_WNDPROC) -> create new window
			 +/
			test_out.writeln("hDC: ", GetDC(window), ", WndProc: ", cast(void*)GetWindowLong(window, GWL_WNDPROC));

			RECT rect={ 0, 0, Width, Height };
			DWORD style=GetWindowLong(window, GWL_STYLE);
			AdjustWindowRectEx(&rect, style, 0, 0);
			SetWindowPos(window, HWND_NOTOPMOST, rect.left, rect.top, rect.right-rect.left, rect.bottom-rect.top, SWP_NOCOPYBITS | SWP_NOMOVE | SWP_NOACTIVATE);
		}

		EnumerateVkExtensions();
		CreateVkInstance();
		CreateVkPhysicalDevice();
		VkCheck(CreateVkSurface(g_VkInstance, window, _surface), "vkCreateWin32SurfaceKHR");
		CreateVkLogicalDevice(g_VkInstance, g_Device);

		g_Allocator=Allocator.GetAllocator();

		vkGetDeviceQueue(g_Device, GetQueueFamily().graphics_family, 0, &_graphics_queue);

		VkCheck(CreateVkSwapchain(_format, _colour_space, _swapchain), "vkCreateSwapchainKHR");
		CreateVkImageViews(_swapchain, _images, _buffers);

		//// Render Pass
		CreateRenderPass();

		//// Graphics Pipeline
		CreateGraphicsPipeline();

		///
		CreateDepthBuffer();

		CreateFramebuffers();

		CreateVkCommandPool();

		CreateTextureImage();

		_texture_image_view=CreateImageView(_texture_image, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT);
		CreateTextureSampler();

		CreateVertexBuffer(cast(VkDeviceSize)(Vertex.sizeof*_test_triangle.length), cast(void*)_test_triangle.ptr, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, _vertex_buffer, _vertex_buffer_memory);
		CreateVertexBuffer(cast(VkDeviceSize)(uint.sizeof*_test_triangle_indices.length), cast(void*)_test_triangle_indices.ptr, VK_BUFFER_USAGE_INDEX_BUFFER_BIT, _vertex_index_buffer, _vertex_index_memory);

		CreateUniformBuffers();
		CreateLightListUniformBuffers();

		CreateDescriptorPool();
		CreateTextureDescriptorPool();
		CreateDescriptorSets();

		CreateTextureDescriptorSet(_texture_image_view, _texture_descriptor);

		CreateCommandBuffers();

		CreateOverlay();

		///
		VkSemaphoreCreateInfo semaphore_info;
		vkCreateSemaphore(g_Device, &semaphore_info, null, &_is_image_available);
		vkCreateSemaphore(g_Device, &semaphore_info, null, &_is_render_finished);

		test_out.writeln("Vulkan done.");
	}

	vec3 camera_pos;
	quat camera_view=quat.identity;
	float fov_global=45f;
	override void RenderScene(SceneDesc* scene_desc) // vkCmd*
	{
		_scene_rendered=true;

		camera_pos=vec3(scene_desc.camera_position);
		camera_view=quat(scene_desc.camera_rotation[3], vec3(scene_desc.camera_rotation[0..3]));

		fov_global=degrees(scene_desc.fov_y);

		/+
		uVar9 = 0;
		local_2c.process_obj_callback = DummyIterateObject__FP7DObjectPv;
		local_2c.process_leaf_callback = DummyIterateLeaf__FP6Leaf_tPv;
		local_2c.add_render_obj_callback = AddClientObjects__FP10FastNode_tRPP7DObjectRi;
		local_2c.portal_vis_callback = DummyPortalTest__FP12UserPortal_t;
		r_DrawBSP__FP6Node_t(g_pWorldBsp->root_node?);
		if (g_pWorldBsp->leaf_count != 0) {
			iVar10 = 0;
			do {
				uVar9 = uVar9 + 1;
				r_AddLeafPolyGrids__FP6Leaf_t((int)g_pWorldBsp->leaves->field_0x0 + iVar10);
				iVar10 = iVar10 + 0x30;
			} while (uVar9 < g_pWorldBsp->leaf_count);
		}
		+/
	}

	private void DrawBSP(Node* node)
	{
		/*if (node.next.flags & 8)
		{
			DrawBSP(node.next);
		}*/

		//

		/+

		uint *puVar1;
		float fVar2;
		Plane *pPVar3;
		Polygon *pPVar4;
		float fVar5;
		float fVar6;
		Polygon *pPVar7;
		int *piVar8;
		int *piVar9;
		int iVar10;
		byte bVar11;
		float *local_10;
		Polygon *pfVar3;

		piVar9 = (int *)param_1->objects?;
		piVar8 = piVar9;
		if (piVar9 != NULL) {
			while ((pListHead.1122 = piVar8, pCur.1123 = (int *)*piVar9, pCur.1123 != pListHead.1122 &&
						 (pObject.1124 = (DObject *)pCur.1123[2], pObject.1124->field_0x124 == 0))) {
				r_CheckAndProcessObject__FP7DObject(pObject.1124);
				piVar9 = pCur.1123;
				piVar8 = pListHead.1122;
			}
		}
		if (((*(byte *)&param_1->next->flags & 8) != 0) &&
			 (iVar10 = r_RejectBackside__FP8DPlane_t(param_1->plane), iVar10 == 0)) {
			r_DrawBSP__FP6Node_t(param_1->next);
		}
		pPVar3 = param_1->plane;
		fVar2 = ((pPVar3->vector).z * g_ViewParams._956_4_ +
						(pPVar3->vector).x * g_ViewParams._948_4_ + (pPVar3->vector).y * g_ViewParams._952_4_) -
						pPVar3->distance;
		if ((((char)((uint)(ushort)((ushort)(fVar2 < 0.001) << 8 | (ushort)(fVar2 == 0.001) << 0xe) >> 8)
					== '\0') && (pPVar4 = param_1->polygons, pPVar4 != NULL)) &&
			 (pPoly.1121 = pPVar4, pPVar4->frame_code? != g_CurFrameCode)) {
			fVar2 = pPVar4->field_0x0[3];
			pPVar4->frame_code? = g_CurFrameCode;
			pPVar4->field_0x3c[0] = 0x3f;
			fVar6 = -fVar2;
			local_10 = (float *)(g_ViewParams + 0x330);
			puVar1 = (uint *)pPVar4->field_0x3c;
			iVar10 = 0;
			do {
				fVar5 = (local_10[2] * pPVar4->field_0x0[2] +
								*local_10 * pPVar4->field_0x0[0] + local_10[1] * pPVar4->field_0x0[1]) - local_10[3];
				if ((char)((uint)(ushort)((ushort)(fVar5 < fVar6) << 8 | (ushort)(fVar5 == fVar6) << 0xe) >> 8
									) == '\x01') goto LAB_0004814b;
				bVar11 = (byte)iVar10;
				if ((char)((uint)(ushort)((ushort)(fVar5 < fVar2) << 8 | (ushort)(fVar5 == fVar2) << 0xe) >> 8
									) == '\0') {
					*puVar1 = *puVar1 & (1 << (bVar11 & 0x1f) ^ 0xffffffffU);
				}
				fVar5 = (local_10[6] * pPVar4->field_0x0[2] +
								local_10[4] * pPVar4->field_0x0[0] + local_10[5] * pPVar4->field_0x0[1]) - local_10[7]
				;
				if ((char)((uint)(ushort)((ushort)(fVar5 < fVar6) << 8 | (ushort)(fVar5 == fVar6) << 0xe) >> 8
									) == '\x01') goto LAB_0004814b;
				if ((char)((uint)(ushort)((ushort)(fVar5 < fVar2) << 8 | (ushort)(fVar5 == fVar2) << 0xe) >> 8
									) == '\0') {
					*puVar1 = *puVar1 & (1 << (bVar11 + 1 & 0x1f) ^ 0xffffffffU);
				}
				fVar5 = (local_10[10] * pPVar4->field_0x0[2] +
								local_10[8] * pPVar4->field_0x0[0] + local_10[9] * pPVar4->field_0x0[1]) -
								local_10[0xb];
				if ((char)((uint)(ushort)((ushort)(fVar5 < fVar6) << 8 | (ushort)(fVar5 == fVar6) << 0xe) >> 8
									) == '\x01') goto LAB_0004814b;
				if ((char)((uint)(ushort)((ushort)(fVar5 < fVar2) << 8 | (ushort)(fVar5 == fVar2) << 0xe) >> 8
									) == '\0') {
					*puVar1 = *puVar1 & (1 << (bVar11 + 2 & 0x1f) ^ 0xffffffffU);
				}
				pPVar7 = pPoly.1121;
				local_10 = local_10 + 0xc;
				iVar10 = iVar10 + 3;
			} while (iVar10 < 6);
			pPoly.1121->frame_code? = g_CurFrameCode;
			if (((*(byte *)&pPVar7->surface->plane & 0x10) == 0) || (g_CV_DrawFlat != 0)) {
				if (g_nVisiblePolies < g_VisiblePolies._4_4_) {
					*(Polygon **)(g_VisiblePolies._0_4_ + (int)g_nVisiblePolies * 4) = pPoly.1121;
				}
				else {
					Insert__t8CMoArray2ZP11WorldPoly_tZ12DefaultCacheUlRCP11WorldPoly_t
										(g_VisiblePolies,g_VisiblePolies._4_4_,&pPoly.1121);
				}
				g_nVisiblePolies = (WorldPoly_t *)&g_nVisiblePolies->field_0x1;
			}
			else {
				r_QueueSkyClipperPoly__FP11WorldPoly_t(pPVar7);
			}
		}
LAB_0004814b:
		if (((*(byte *)param_1[1].flags & 8) != 0) &&
			 (iVar10 = r_RejectFrontside__FP8DPlane_t(param_1->plane), iVar10 == 0)) {
			r_DrawBSP__FP6Node_t((Node *)param_1[1].flags);
		}
		return;

		+/
	}

	/// 	It seems that I was working under incorrect assumptions that once a pipeline was bound it was there for the entire renderpass, this
	/// seems to be false and means that we could obey Start3D/End3D functions to start and end a renderpass. I am unsure how Start2D/End2D
	/// will fit, but in theory we could just do a g_IsIn3D check and bind a HUD pipeline, and draw (also have to re-bind the original back?)
	///
	/// FIXME: move most of this into RenderScene so we don't need to use g_RenderContext and try use a null reference during loading screens
	override void SwapBuffers() // vkQueuePresent
	{
		uint image_index;
		VkResult res=vkAcquireNextImageKHR(g_Device, _swapchain, uint.max, _is_image_available, VK_NULL_ND_HANDLE, &image_index);

		if (res==VK_ERROR_SURFACE_LOST_KHR || res==VK_SUBOPTIMAL_KHR)
		{
			test_out.writeln("Trying to recreate surface.");

			vkDeviceWaitIdle(g_Device);

			DestroyVkSwapchain();
			//
			VkCheck(CreateVkSwapchain(_format, _colour_space, _swapchain), "vkCreateSwapchainKHR");
			CreateVkImageViews(_swapchain, _images, _buffers);
			CreateRenderPass();
			CreateGraphicsPipeline();
			CreateFramebuffers();
			CreateCommandBuffers();
		}

		VkSemaphore[] wait_semaphores=[ _is_image_available ];
		VkSemaphore[] signal_semaphores=[ _is_render_finished ];

		import Main: g_IsIn3D, g_RenderContext;
		//if (g_IsIn3D)
		{
			UpdateUniformBuffer(image_index);
			UpdateLightListUbo(image_index);

			void SetCommandBuffer(size_t image_index)
			{
				debug
				{
					VkClearValue[] clear_colour=[ { color: {[ 0.4f, 0.58f, 0.93f, 1f ]} }, { depthStencil: { 1f, 0 } } ]; // never clear to black! Black hides bugs!
				}
				else
				{
					// release should clear to black, there's holes in some maps (notably the train levels) that let you see the clear colour and black is expected
					VkClearValue[] clear_colour=[ { color: {[ 0f, 0f, 0f, 1f ]} }, { depthStencil: { 1f, 0 } } ];
				}

				auto buffer=_command_buffers[image_index];

				VkRenderPassBeginInfo render_pass_begin_info={
					renderPass: _render_pass,
					framebuffer: _buffers[image_index].framebuffer,
					renderArea: {
						offset: { 0, 0 },
						extent: _extents
					},
					clearValueCount: clear_colour.length,
					pClearValues: clear_colour.ptr
				};

				VkCommandBufferBeginInfo command_buffer_begin_info;

				vkBeginCommandBuffer(buffer, &command_buffer_begin_info);
				RecordOverlayCopy(buffer);
				vkCmdBeginRenderPass(buffer, &render_pass_begin_info, VK_SUBPASS_CONTENTS_INLINE);
				vkCmdBindPipeline(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _pipeline);

				// both are dynamic state of the world pipeline
				VkViewport viewport={ 0f, 0f, _extents.width, _extents.height, 0f, 1f };
				vkCmdSetViewport(buffer, 0, 1, &viewport);
				vkCmdSetLineWidth(buffer, 1f);

				vkCmdBindDescriptorSets(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _pipeline_layout, 0, 1, &_descriptor_sets[image_index], 0, null);
				vkCmdBindDescriptorSets(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _pipeline_layout, 1, 1, &_texture_descriptor, 0, null);

				if (g_RenderContext !is null && _vertex_buffer!=VK_NULL_ND_HANDLE)
				{
					VkBuffer[] vertex_buffers=[ _vertex_buffer ];
					VkDeviceSize[] offsets=[ 0 ];

					vkCmdBindVertexBuffers(buffer, 0, vertex_buffers.length, vertex_buffers.ptr, offsets.ptr);
					vkCmdBindIndexBuffer(buffer, _vertex_index_buffer, 0, VK_INDEX_TYPE_UINT32);

					WorldBsp* bsp=g_RenderContext.main_world.world_bsp;

					size_t index_start=0;

					RenderTexture last_texture=null;

					foreach(i, polygon; bsp.polygons[0..bsp.polygon_count])
					{
						if (polygon.surface.flags & SurfaceFlags.Invisible)
							continue;

						// unbound (or never bound) textures fall back to the dummy texture
						SharedTexture* shared_texture=polygon.surface.shared_texture;
						RenderTexture this_texture=shared_texture ? cast(RenderTexture)shared_texture.render_data : null;
						if (last_texture !is this_texture)
						{
							last_texture=this_texture;
							VkDescriptorSet texture_image=this_texture ? this_texture.texture_descriptor : _texture_descriptor;
							vkCmdBindDescriptorSets(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _pipeline_layout, 1, 1, &texture_image, 0, null);
						}

						int vert_count=(polygon.DiskVerts().length-2)*3;
						vkCmdDrawIndexed(buffer, vert_count, 1, index_start, 0, 0);
						index_start+=vert_count;
					}
				}

				//vkCmdDrawIndexed(buffer, index_count, 1, 0, 0, 0);

				RecordOverlayDraw(buffer);

				vkCmdEndRenderPass(buffer);
				vkEndCommandBuffer(buffer);
			}

			UploadOverlay();
			SetCommandBuffer(image_index);

			VkPipelineStageFlags[] wait_stages = [ VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT ];
			VkSubmitInfo submit_info={
				waitSemaphoreCount: 1,
				pWaitSemaphores: wait_semaphores.ptr,
				pWaitDstStageMask: wait_stages.ptr,
				commandBufferCount: 1,
				pCommandBuffers: &_command_buffers[image_index],
				signalSemaphoreCount: 1,
				pSignalSemaphores: signal_semaphores.ptr
			};

			vkQueueSubmit(_graphics_queue, 1, &submit_info, VK_NULL_ND_HANDLE);
		}

		VkPresentInfoKHR present_info={
			pNext: null,
			swapchainCount: 1,
			pSwapchains: &_swapchain,
			pImageIndices: &image_index,
			waitSemaphoreCount: 1,
			pWaitSemaphores: signal_semaphores.ptr
		};

		res=vkQueuePresentKHR(_graphics_queue, &present_info);
		// recover lost screen if necessary?
		if (res==VK_ERROR_SURFACE_LOST_KHR || res==VK_SUBOPTIMAL_KHR)
		{
			test_out.writeln("Trying to recreate surface.");
			vkDeviceWaitIdle(g_Device);
			DestroyVkSwapchain();
			//
			VkCheck(CreateVkSwapchain(_format, _colour_space, _swapchain), "vkCreateSwapchainKHR");
			CreateVkImageViews(_swapchain, _images, _buffers);
			CreateRenderPass();
			CreateGraphicsPipeline();
			CreateFramebuffers();
			CreateCommandBuffers();
		}

		vkQueueWaitIdle(_graphics_queue);
		_scene_rendered=false;

		LogFrameRate();
	}

	import core.time: MonoTime, seconds;
	MonoTime _fps_start;
	uint _fps_frames;

	void LogFrameRate()
	{
		const MonoTime now=MonoTime.currTime;
		if (_fps_frames==0 && _fps_start==MonoTime.init)
			_fps_start=now;

		++_fps_frames;
		const elapsed=now-_fps_start;
		if (elapsed>=1.seconds)
		{
			test_out.writefln("fps: %.1f", _fps_frames/(elapsed.total!"usecs"/1_000_000.0));
			test_out.flush();
			_fps_frames=0;
			_fps_start=now;
		}
	}

	//// 2D layer
	/// LT1 draws menus, fonts, the console and the HUD into the same 16-bit back buffer as the 3D scene (d3d.ren: g_pOffscreen).
	/// Here they go into a CPU-side 565 screen plus a coverage mask; SwapBuffers uploads it and composites it over the 3D scene.

	ushort[] _screen;
	ubyte[] _screen_mask; // 255 where 2D has been drawn since the last clear
	ushort[] _screen_lock_copy;
	uint _screen_width, _screen_height;
	bool _screen_locked;
	Rect _screen_lock_rect;
	bool _scene_rendered; // RenderScene ran since the last SwapBuffers

	// clips a rectangle against the screen, false if nothing is left
	bool ClipToScreen(ref Rect rect)
	{
		import std.algorithm: clamp;

		rect.x1=clamp(rect.x1, 0, cast(int)_screen_width);
		rect.x2=clamp(rect.x2, 0, cast(int)_screen_width);
		rect.y1=clamp(rect.y1, 0, cast(int)_screen_height);
		rect.y2=clamp(rect.y2, 0, cast(int)_screen_height);
		return rect.x1<rect.x2 && rect.y1<rect.y2;
	}

	override void Clear(Rect* rect, ClearFlags flags)
	{
		if (!(flags & ClearFlags.Colour))
			return;

		Rect clear_rect=rect ? *rect : Rect(0, 0, _screen_width, _screen_height);
		if (!ClipToScreen(clear_rect))
			return;

		foreach(y; clear_rect.y1..clear_rect.y2)
		{
			const size_t row=y*_screen_width;
			_screen[row+clear_rect.x1..row+clear_rect.x2]=0;
			_screen_mask[row+clear_rect.x1..row+clear_rect.x2]=0;
		}
	}

	override void* CreateSurface(const int width, const int height)
	{
		if (width<=0 || height<=0)
			return null;

		return ImageSurface.Create(width, height);
	}

	override void DeleteSurface(void* surface)
	{
		ImageSurface.Free(cast(ImageSurface*)surface);
	}

	override void* LockSurface(void* surface)
	{
		if (surface is null)
			return null;

		return (cast(ImageSurface*)surface).pixels.ptr;
	}

	override void UnlockSurface(void* surface)
	{
		//
	}

	override void GetSurfaceInfo(void* surface, int* width, int* height, int* pitch)
	{
		if (surface is null)
			return;

		ImageSurface* image=cast(ImageSurface*)surface;
		if (width) *width=image.width;
		if (height) *height=image.height;
		if (pitch) *pitch=image.stride; // in bytes
	}

	override int LockScreen(int left, int top, int right, int bottom, void** pixels, int* pitch)
	{
		Rect lock_rect=Rect(left, top, right, bottom);
		if (_screen_locked || !ClipToScreen(lock_rect))
			return 0;

		// remember what was there so UnlockScreen can tell which pixels the engine drew
		foreach(y; lock_rect.y1..lock_rect.y2)
		{
			const size_t row=y*_screen_width;
			_screen_lock_copy[row+lock_rect.x1..row+lock_rect.x2]=_screen[row+lock_rect.x1..row+lock_rect.x2];
		}

		// like DirectDraw's Lock with a rect: the pointer is to the rect's first pixel
		if (pixels) *pixels=&_screen[lock_rect.y1*_screen_width+lock_rect.x1];
		if (pitch) *pitch=_screen_width*ushort.sizeof;

		_screen_lock_rect=lock_rect;
		_screen_locked=true;
		return 1;
	}

	override void UnlockScreen()
	{
		if (!_screen_locked)
			return;

		foreach(y; _screen_lock_rect.y1.._screen_lock_rect.y2)
		{
			const size_t row=y*_screen_width;
			foreach(i; row+_screen_lock_rect.x1..row+_screen_lock_rect.x2)
				if (_screen[i]!=_screen_lock_copy[i])
					_screen_mask[i]=255;
		}

		_screen_locked=false;
	}

	override void BlitToScreen(BlitRequest* blit_request)
	{
		if (blit_request is null || blit_request.surface_ptr is null || blit_request.source_rect is null || blit_request.dest_rect is null)
			return;

		ImageSurface* surface=blit_request.surface_ptr;
		const Rect src=*blit_request.source_rect;
		const Rect dst=*blit_request.dest_rect;

		const int src_w=src.x2-src.x1, src_h=src.y2-src.y1;
		const int dst_w=dst.x2-dst.x1, dst_h=dst.y2-dst.y1;
		if (src_w<=0 || src_h<=0 || dst_w<=0 || dst_h<=0)
			return;

		Rect clipped=dst;
		if (!ClipToScreen(clipped))
			return;

		const bool keyed=(blit_request.flags & BlitRequestFlags.ColourKey)!=0;
		const ushort key=blit_request.colour_key;
		ushort[] src_pixels=surface.Pixels16;
		const int src_pitch=surface.stride/2;

		// DirectDraw Blt semantics: stretch src onto dst, colour key only with BLIT_TRANSPARENT
		foreach(dy; clipped.y1..clipped.y2)
		{
			const int sy=src.y1+(dy-dst.y1)*src_h/dst_h;
			if (sy<0 || sy>=surface.height)
				continue;

			const size_t src_row=sy*src_pitch;
			const size_t dst_row=dy*_screen_width;
			foreach(dx; clipped.x1..clipped.x2)
			{
				const int sx=src.x1+(dx-dst.x1)*src_w/dst_w;
				if (sx<0 || sx>=surface.width)
					continue;

				const ushort pixel=src_pixels[src_row+sx];
				if (keyed && pixel==key)
					continue;

				_screen[dst_row+dx]=pixel;
				_screen_mask[dst_row+dx]=255;
			}
		}
	}

	//// 2D layer upload and compositing

	VkBuffer _overlay_staging;
	VkMappedMemoryRange _overlay_staging_memory;
	VkImage _overlay_image;
	VkMappedMemoryRange _overlay_image_memory;
	VkImageView _overlay_image_view;
	VkSampler _overlay_sampler;
	VkDescriptorSetLayout _overlay_descriptor_layout;
	VkDescriptorPool _overlay_descriptor_pool;
	VkDescriptorSet _overlay_descriptor;
	VkPipelineLayout _overlay_pipeline_layout;
	VkPipeline _overlay_pipeline;
	VkShaderModule _overlay_vert_shader;
	VkShaderModule _overlay_frag_shader;

	void CreateOverlay()
	{
		import Main: _renderer;

		_screen_width=(_renderer && _renderer.screen_width>0) ? _renderer.screen_width : Width;
		_screen_height=(_renderer && _renderer.screen_height>0) ? _renderer.screen_height : Height;

		const size_t pixel_count=_screen_width*_screen_height;
		_screen=new ushort[pixel_count];
		_screen_mask=new ubyte[pixel_count];
		_screen_lock_copy=new ushort[pixel_count];

		CreateVkBuffer(pixel_count*uint.sizeof, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, _overlay_staging, _overlay_staging_memory);

		CreateVkImage(_screen_width, _screen_height, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TILING_OPTIMAL, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, _overlay_image, _overlay_image_memory);
		TransitionImageLayout(_overlay_image, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
		TransitionImageLayout(_overlay_image, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
		_overlay_image_view=CreateImageView(_overlay_image, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT);

		VkSamplerCreateInfo sampler_info={
			magFilter: VK_FILTER_NEAREST,
			minFilter: VK_FILTER_NEAREST,
			mipmapMode: VK_SAMPLER_MIPMAP_MODE_NEAREST,
			addressModeU: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
			addressModeV: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
			addressModeW: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
			maxLod: 0f
		};
		VkCheck(vkCreateSampler(g_Device, &sampler_info, null, &_overlay_sampler), "vkCreateSampler (overlay)");

		VkDescriptorSetLayoutBinding binding={
			binding: 0,
			descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
			descriptorCount: 1,
			stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT
		};
		VkDescriptorSetLayoutCreateInfo layout_info={
			bindingCount: 1,
			pBindings: &binding
		};
		VkCheck(vkCreateDescriptorSetLayout(g_Device, &layout_info, null, &_overlay_descriptor_layout), "vkCreateDescriptorSetLayout (overlay)");

		VkDescriptorPoolSize pool_size={
			type: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
			descriptorCount: 1
		};
		VkDescriptorPoolCreateInfo pool_info={
			poolSizeCount: 1,
			pPoolSizes: &pool_size,
			maxSets: 1
		};
		VkCheck(vkCreateDescriptorPool(g_Device, &pool_info, null, &_overlay_descriptor_pool), "vkCreateDescriptorPool (overlay)");

		VkDescriptorSetAllocateInfo alloc_info={
			descriptorPool: _overlay_descriptor_pool,
			descriptorSetCount: 1,
			pSetLayouts: &_overlay_descriptor_layout
		};
		VkCheck(vkAllocateDescriptorSets(g_Device, &alloc_info, &_overlay_descriptor), "vkAllocateDescriptorSets (overlay)");

		VkDescriptorImageInfo image_info={
			sampler: _overlay_sampler,
			imageView: _overlay_image_view,
			imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
		};
		VkWriteDescriptorSet descriptor_write={
			dstSet: _overlay_descriptor,
			dstBinding: 0,
			descriptorCount: 1,
			descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
			pImageInfo: &image_info
		};
		vkUpdateDescriptorSets(g_Device, 1, &descriptor_write, 0, null);

		VkPipelineLayoutCreateInfo pipeline_layout_info={
			setLayoutCount: 1,
			pSetLayouts: &_overlay_descriptor_layout
		};
		VkCheck(vkCreatePipelineLayout(g_Device, &pipeline_layout_info, null, &_overlay_pipeline_layout), "vkCreatePipelineLayout (overlay)");

		CreateOverlayPipeline();
	}

	void CreateOverlayPipeline()
	{
		_overlay_vert_shader=Shader.CreateShaderModule(g_Device, Shader.ReadShader("overlay_vert.spv"));
		_overlay_frag_shader=Shader.CreateShaderModule(g_Device, Shader.ReadShader("overlay_frag.spv"));

		VkPipelineShaderStageCreateInfo[] shader_stages=[
			{ stage: VK_SHADER_STAGE_VERTEX_BIT, module_: _overlay_vert_shader, pName: "main" },
			{ stage: VK_SHADER_STAGE_FRAGMENT_BIT, module_: _overlay_frag_shader, pName: "main" }
		];

		VkPipelineVertexInputStateCreateInfo vertex_input_info; // fullscreen triangle comes from gl_VertexIndex

		VkPipelineInputAssemblyStateCreateInfo input_assembly_info={
			topology: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
		};

		VkPipelineViewportStateCreateInfo viewport_state_info={
			viewportCount: 1,
			scissorCount: 1
		};

		VkPipelineRasterizationStateCreateInfo rasterizer_info={
			polygonMode: VK_POLYGON_MODE_FILL,
			cullMode: VK_CULL_MODE_NONE,
			frontFace: VK_FRONT_FACE_CLOCKWISE,
			lineWidth: 1f
		};

		VkPipelineMultisampleStateCreateInfo multisampling_info={
			rasterizationSamples: VK_SAMPLE_COUNT_1_BIT
		};

		VkPipelineDepthStencilStateCreateInfo depth_stencil_info={
			depthTestEnable: VK_FALSE,
			depthWriteEnable: VK_FALSE
		};

		VkPipelineColorBlendAttachmentState colour_blend_attachment={
			blendEnable: VK_TRUE,
			srcColorBlendFactor: VK_BLEND_FACTOR_SRC_ALPHA,
			dstColorBlendFactor: VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
			colorBlendOp: VK_BLEND_OP_ADD,
			srcAlphaBlendFactor: VK_BLEND_FACTOR_ONE,
			dstAlphaBlendFactor: VK_BLEND_FACTOR_ZERO,
			alphaBlendOp: VK_BLEND_OP_ADD,
			colorWriteMask: VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT
		};

		VkPipelineColorBlendStateCreateInfo colour_blend_info={
			attachmentCount: 1,
			pAttachments: &colour_blend_attachment
		};

		VkDynamicState[] dynamic_states=[ VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR ];
		VkPipelineDynamicStateCreateInfo dynamic_state_info={
			dynamicStateCount: dynamic_states.length,
			pDynamicStates: dynamic_states.ptr
		};

		VkGraphicsPipelineCreateInfo pipeline_info={
			stageCount: shader_stages.length,
			pStages: shader_stages.ptr,
			pVertexInputState: &vertex_input_info,
			pInputAssemblyState: &input_assembly_info,
			pViewportState: &viewport_state_info,
			pRasterizationState: &rasterizer_info,
			pMultisampleState: &multisampling_info,
			pDepthStencilState: &depth_stencil_info,
			pColorBlendState: &colour_blend_info,
			pDynamicState: &dynamic_state_info,
			layout: _overlay_pipeline_layout,
			renderPass: _render_pass,
			basePipelineIndex: -1
		};

		VkCheck(vkCreateGraphicsPipelines(g_Device, VK_NULL_ND_HANDLE, 1, &pipeline_info, null, &_overlay_pipeline), "vkCreateGraphicsPipelines (overlay)");
	}

	void DestroyOverlay()
	{
		vkDestroyPipeline(g_Device, _overlay_pipeline, null);
		vkDestroyPipelineLayout(g_Device, _overlay_pipeline_layout, null);
		vkDestroyShaderModule(g_Device, _overlay_vert_shader, null);
		vkDestroyShaderModule(g_Device, _overlay_frag_shader, null);
		vkDestroyDescriptorPool(g_Device, _overlay_descriptor_pool, null);
		vkDestroyDescriptorSetLayout(g_Device, _overlay_descriptor_layout, null);
		vkDestroySampler(g_Device, _overlay_sampler, null);
		vkDestroyImageView(g_Device, _overlay_image_view, null);
		vkDestroyImage(g_Device, _overlay_image, null);
		vkDestroyBuffer(g_Device, _overlay_staging, null);
	}

	// 565 screen -> RGBA8 staging buffer
	void UploadOverlay()
	{
		void* data;
		if (vmaMapMemory(_overlay_staging_memory, &data)!=VK_SUCCESS)
			return;

		uint[] rgba=(cast(uint*)data)[0.._screen.length];

		// without a 3D scene the 2D layer is the whole frame, cleared areas are black like the original back buffer
		const bool opaque=!_scene_rendered;

		foreach(i, pixel; _screen)
		{
			uint r=(pixel >> 11) & 0x1F, g=(pixel >> 5) & 0x3F, b=pixel & 0x1F;
			r=(r << 3) | (r >> 2);
			g=(g << 2) | (g >> 4);
			b=(b << 3) | (b >> 2);
			const uint a=(opaque || _screen_mask[i]) ? 0xFF : 0;
			rgba[i]=r | (g << 8) | (b << 16) | (a << 24);
		}

		vmaUnmapMemory(_overlay_staging_memory);
	}

	// recorded outside the render pass
	void RecordOverlayCopy(VkCommandBuffer buffer)
	{
		VkImageMemoryBarrier barrier={
			srcAccessMask: VK_ACCESS_SHADER_READ_BIT,
			dstAccessMask: VK_ACCESS_TRANSFER_WRITE_BIT,
			oldLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
			newLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
			image: _overlay_image,
			subresourceRange: {
				aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
				baseMipLevel: 0,
				levelCount: 1,
				baseArrayLayer: 0,
				layerCount: 1
			}
		};
		vkCmdPipelineBarrier(buffer, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);

		VkBufferImageCopy image_copy={
			imageSubresource: {
				aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
				mipLevel: 0,
				baseArrayLayer: 0,
				layerCount: 1
			},
			imageExtent: { _screen_width, _screen_height, 1 }
		};
		vkCmdCopyBufferToImage(buffer, _overlay_staging, _overlay_image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &image_copy);

		barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;
		barrier.dstAccessMask=VK_ACCESS_SHADER_READ_BIT;
		barrier.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
		barrier.newLayout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
		vkCmdPipelineBarrier(buffer, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
	}

	// recorded inside the render pass, after the 3D scene
	void RecordOverlayDraw(VkCommandBuffer buffer)
	{
		vkCmdBindPipeline(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _overlay_pipeline);

		VkViewport viewport={ 0f, 0f, _extents.width, _extents.height, 0f, 1f };
		vkCmdSetViewport(buffer, 0, 1, &viewport);
		VkRect2D scissor={ { 0, 0 }, _extents };
		vkCmdSetScissor(buffer, 0, 1, &scissor);

		vkCmdBindDescriptorSets(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _overlay_pipeline_layout, 0, 1, &_overlay_descriptor, 0, null);
		vkCmdDraw(buffer, 3, 1, 0, 0);
	}

private:
	auto EnumerateVkExtensions()
	{
		uint extension_count;
		vkEnumerateInstanceExtensionProperties(null, &extension_count, null);
		VkExtensionProperties[] extensions=new VkExtensionProperties[extension_count];
		vkEnumerateInstanceExtensionProperties(null, &extension_count, extensions.ptr);

		test_out.writeln("Available Vulkan extensions:");
		import std.string: fromStringz;
		foreach(extension; extensions)
			test_out.writeln(extension.extensionName.ptr.fromStringz);
	}

	auto CreateVkInstance()
	{
		VkApplicationInfo app_info={
			pApplicationName: "Blood 2",
			applicationVersion: VK_MAKE_VERSION(1, 0, 0),
			pEngineName: "LithTech",
			engineVersion: VK_MAKE_VERSION(1, 0, 0),
			apiVersion: VK_API_VERSION_1_0
		};

		VkDebugUtilsMessengerCreateInfoEXT debug_create_info={
			pNext: null,
			messageSeverity: VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
			messageType: VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
			pfnUserCallback: &DebugCallback,
			pUserData: null
		};

		// validation layer only ships with the Vulkan SDK, requesting it when missing fails instance creation
		const(char)*[] layers;
		debug if (HasInstanceLayer("VK_LAYER_KHRONOS_validation"))
			layers~="VK_LAYER_KHRONOS_validation";
		test_out.writeln("Validation layer: ", layers.length ? "enabled" : "not available");

		const char*[] extensions=[ VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_WIN32_SURFACE_EXTENSION_NAME, VK_EXT_DEBUG_UTILS_EXTENSION_NAME ];

		VkInstanceCreateInfo create_info={
			pNext: layers.length ? &debug_create_info : null,
			flags: 0,
			pApplicationInfo: &app_info,
			enabledLayerCount: layers.length,
			ppEnabledLayerNames: layers.ptr,
			enabledExtensionCount: extensions.length,
			ppEnabledExtensionNames: extensions.ptr
		};

		VkCheck(vkCreateInstance(&create_info, null, &g_VkInstance), "vkCreateInstance");
		loadInstanceLevelFunctionsExt(g_VkInstance);

		if (layers.length)
			return vkCreateDebugUtilsMessengerEXT(g_VkInstance, &debug_create_info, null, &debug_messenger);
		return VK_SUCCESS;
	}

	bool HasInstanceLayer(string name)
	{
		import std.string: fromStringz;

		uint layer_count;
		vkEnumerateInstanceLayerProperties(&layer_count, null);
		VkLayerProperties[] layer_props=new VkLayerProperties[layer_count];
		vkEnumerateInstanceLayerProperties(&layer_count, layer_props.ptr);

		foreach(ref layer; layer_props)
			if (layer.layerName.ptr.fromStringz==name)
				return true;
		return false;
	}

	auto CreateVkPhysicalDevice()
	{
		uint device_count;
		vkEnumeratePhysicalDevices(g_VkInstance, &device_count, null);

		if (device_count==0)
			VkCheck(VK_ERROR_INCOMPATIBLE_DRIVER, "vkEnumeratePhysicalDevices (no 32-bit Vulkan driver found)");

		VkPhysicalDevice[] devices=new VkPhysicalDevice[device_count];
		vkEnumeratePhysicalDevices(g_VkInstance, &device_count, devices.ptr);

		foreach(device; devices)
		{
			import std.string: fromStringz;

			VkPhysicalDeviceProperties props;
			vkGetPhysicalDeviceProperties(device, &props);
			VkPhysicalDeviceFeatures features;
			vkGetPhysicalDeviceFeatures(device, &features);
			test_out.writeln("Physical device: ", props.deviceName.ptr.fromStringz, " (", props.deviceType, ")");
			//test_out.writeln(features);
		}

		g_PhysicalDevice=devices[0];

		vkGetPhysicalDeviceMemoryProperties(g_PhysicalDevice, &g_PhysicalMemoryProps);
	}

	struct QueueFamily
	{
		uint graphics_family=uint.max;
		uint present_family=uint.max;
	}

	auto GetQueueFamily()
	{
		uint queue_count;
		vkGetPhysicalDeviceQueueFamilyProperties(g_PhysicalDevice, &queue_count, null);

		VkQueueFamilyProperties[] queue_props=new VkQueueFamilyProperties[queue_count];
		vkGetPhysicalDeviceQueueFamilyProperties(g_PhysicalDevice, &queue_count, queue_props.ptr);
		//test_out.writeln(queue_props);

		QueueFamily queue_family;

		foreach(i, queue; queue_props)
		{
			if ((queue.queueFlags & VK_QUEUE_GRAPHICS_BIT)!=0)
				queue_family.graphics_family=i;

			VkBool32 present_support=VK_FALSE;
			vkGetPhysicalDeviceSurfaceSupportKHR(g_PhysicalDevice, i, _surface, &present_support);
			if (present_support)
				queue_family.present_family=i;
		}

		return queue_family;
	}

	auto CreateVkLogicalDevice(ref VkInstance instance, out VkDevice device_out)
	{
		QueueFamily queue_family=GetQueueFamily();

		VkDeviceQueueCreateInfo[] queue_create_infos=[];
		test_out.writeln(queue_family);
		// a family may only be requested once
		uint[] unique_queue_families=[ queue_family.graphics_family ];
		if (queue_family.present_family!=queue_family.graphics_family)
			unique_queue_families~=queue_family.present_family;

		float[] priorities=[ 1f ];
		foreach(family; unique_queue_families)
		{
			VkDeviceQueueCreateInfo queue_info={
				pNext: null,
				queueFamilyIndex: family,
				queueCount: 1,
				pQueuePriorities: priorities.ptr
			};

			queue_create_infos~=queue_info;
		}

		const char*[] extensions=[ VK_KHR_SWAPCHAIN_EXTENSION_NAME ];

		VkPhysicalDeviceFeatures device_features={
			samplerAnisotropy: VK_TRUE
		};

		VkDeviceCreateInfo create_info={
			pNext: null,
			queueCreateInfoCount: queue_create_infos.length,
			pQueueCreateInfos: queue_create_infos.ptr,
			enabledExtensionCount: extensions.length,
			ppEnabledExtensionNames: extensions.ptr,
			pEnabledFeatures: &device_features
		};

		VkCheck(vkCreateDevice(g_PhysicalDevice, &create_info, null, &g_Device), "vkCreateDevice");
		loadDeviceLevelFunctionsExt(g_VkInstance);

		vkGetDeviceQueue(g_Device, queue_family.graphics_family, 0, &_graphics_queue);
		vkGetDeviceQueue(g_Device, queue_family.present_family, 0, &_present_queue);
	}

	auto CreateVkSurface(ref VkInstance instance, void* window, out VkSurfaceKHR surface)
	{
		VkWin32SurfaceCreateInfoKHR surface_info={
			pNext: null,
			flags: 0,
			hinstance: GetModuleHandle(null),
			hwnd: window
		};

		//VkSurfaceKHR surface;
		return vkCreateWin32SurfaceKHR(instance, &surface_info, null, &surface);
	}

	auto CreateVkSwapchain(out VkFormat format, out VkColorSpaceKHR colour_space, out VkSwapchainKHR swap_chain)
	{
		VkSurfaceCapabilitiesKHR surface_capabilities;
		vkGetPhysicalDeviceSurfaceCapabilitiesKHR(g_PhysicalDevice, _surface, &surface_capabilities);
		VkExtent2D swapchain_rect=surface_capabilities.currentExtent;
		_extents=swapchain_rect;
		test_out.writeln(surface_capabilities);

		uint format_count;
		vkGetPhysicalDeviceSurfaceFormatsKHR(g_PhysicalDevice, _surface, &format_count, null);

		VkSurfaceFormatKHR[] formats=new VkSurfaceFormatKHR[format_count];
		vkGetPhysicalDeviceSurfaceFormatsKHR(g_PhysicalDevice, _surface, &format_count, formats.ptr);
		test_out.writeln(formats);

		format=formats[0].format;
		colour_space=formats[0].colorSpace;

		uint present_mode_count;
		vkGetPhysicalDeviceSurfacePresentModesKHR(g_PhysicalDevice, _surface, &present_mode_count, null);
		VkPresentModeKHR[] present_modes=new VkPresentModeKHR[present_mode_count];
		vkGetPhysicalDeviceSurfacePresentModesKHR(g_PhysicalDevice, _surface, &present_mode_count, present_modes.ptr);
		VkPresentModeKHR present_mode=VK_PRESENT_MODE_FIFO_KHR;
		test_out.writeln(present_modes);

		//uint[] queue_family=[ _graphics_queue, _present_queue ];
		auto queue_family=GetQueueFamily();
		uint[] queue_family_indices=[ queue_family.graphics_family, queue_family.present_family ];

		VkSwapchainCreateInfoKHR create_info={
			pNext: null,
			flags: 0,
			surface: _surface,
			minImageCount: surface_capabilities.minImageCount+1,
			imageFormat: format,
			imageColorSpace: colour_space,
			imageExtent: swapchain_rect,
			imageArrayLayers: 1,
			imageUsage: VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
			// concurrent sharing requires distinct families
			imageSharingMode: queue_family.graphics_family==queue_family.present_family ? VK_SHARING_MODE_EXCLUSIVE : VK_SHARING_MODE_CONCURRENT,
			queueFamilyIndexCount: queue_family.graphics_family==queue_family.present_family ? 0 : 2,
			pQueueFamilyIndices: queue_family_indices.ptr,
			preTransform: VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
			compositeAlpha: VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
			presentMode: present_mode
		};

		return vkCreateSwapchainKHR(g_Device, &create_info, null, &swap_chain);
	}

	void CreateVkImageViews(ref const VkSwapchainKHR swapchain, out VkImage[] images, out SwapchainBuffer[] buffers)
	{
		uint image_count;
		vkGetSwapchainImagesKHR(g_Device, swapchain, &image_count, null);
		images=new VkImage[image_count];
		buffers=new SwapchainBuffer[image_count];
		vkGetSwapchainImagesKHR(g_Device, swapchain, &image_count, images.ptr);

		test_out.writeln("Swapchain Images acquired.");
	}

	void DestroyVkSwapchain()
	{
		foreach(i; 0.._buffers.length)
		{
			vkDestroyFramebuffer(g_Device, _buffers[i].framebuffer, null);
		}

		vkFreeCommandBuffers(g_Device, _command_pool, _command_buffers.length, _command_buffers.ptr);

		vkDestroyPipeline(g_Device, _pipeline, null);
		//vkDestroyPipelineLayout(g_Device, _pipeline_layout, null);
		vkDestroyRenderPass(g_Device, _render_pass, null);

		foreach(i; 0.._buffers.length)
		{
			vkDestroyImageView(g_Device, _buffers[i].view, null);
		}

		vkDestroySwapchainKHR(g_Device, _swapchain, null);
	}

	void CreateVkViews()
	{
		foreach(size_t i, ref image; _images)
		{
			VkImageViewCreateInfo create_info={
				pNext: null,
				flags: 0,
				image: image,
				viewType: VK_IMAGE_VIEW_TYPE_2D,
				format: _format,
				components: { VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY },
				subresourceRange: {
					aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
					baseMipLevel: 0,
					levelCount: 1,
					baseArrayLayer: 0,
					layerCount: 1
				}
			};
			_buffers[i].image=image;
			//SetImageLayout(_initial_command_buffer, image, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
			vkCreateImageView(g_Device, &create_info, null, &_buffers[i].view);
		}
	}

	void CreateRenderPass()
	{
		VkAttachmentDescription colour_attachment={
			format: _format,
			samples: VK_SAMPLE_COUNT_1_BIT,
			loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
			storeOp: VK_ATTACHMENT_STORE_OP_STORE,
			stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
			stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
			initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
			finalLayout: VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
		};

		VkAttachmentReference colour_attachment_ref={
			attachment: 0,
			layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
		};

		VkAttachmentDescription depth_attachment={
			format: FindDepthFormat(),
			samples: VK_SAMPLE_COUNT_1_BIT,
			loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
			storeOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
			stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
			stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
			initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
			finalLayout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
		};

		VkAttachmentReference depth_attachment_ref={
			attachment: 1,
			layout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
		};

		VkSubpassDescription subpass={
			pipelineBindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS,
			colorAttachmentCount: 1,
			pColorAttachments: &colour_attachment_ref,
			pDepthStencilAttachment: &depth_attachment_ref
		};

		VkSubpassDependency dependency={
			srcSubpass: VK_SUBPASS_EXTERNAL,
			dstSubpass: 0,
			srcStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
			srcAccessMask: 0,
			dstStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
			dstAccessMask: VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT
		};

		VkAttachmentDescription[] attachments=[ colour_attachment, depth_attachment ];
		VkRenderPassCreateInfo render_pass_info={
			attachmentCount: attachments.length,
			pAttachments: attachments.ptr,
			subpassCount: 1,
			pSubpasses: &subpass,
			dependencyCount: 1,
			pDependencies: &dependency
		};

		vkCreateRenderPass(g_Device, &render_pass_info, null, &_render_pass);

		test_out.writeln("Render Pass created.");
	}

	void CreateGraphicsPipeline()
	{
		ubyte[] vertex_shader=Shader.ReadShader("vert.spv");
		ubyte[] frag_shader=Shader.ReadShader("frag.spv");

		vk_vertex_shader=Shader.CreateShaderModule(g_Device, vertex_shader);
		vk_frag_shader=Shader.CreateShaderModule(g_Device, frag_shader);

		VkPipelineShaderStageCreateInfo vert_stage_info={
			pNext: null,
			stage: VK_SHADER_STAGE_VERTEX_BIT,
			module_: vk_vertex_shader,
			pName: "main"
		};

		VkPipelineShaderStageCreateInfo frag_stage_info={
			pNext: null,
			stage: VK_SHADER_STAGE_FRAGMENT_BIT,
			module_: vk_frag_shader,
			pName: "main"
		};

		VkPipelineShaderStageCreateInfo[] shader_stages=[ vert_stage_info, frag_stage_info ];

		auto binding_description=Vertex.GetBindingDescription();
		auto attribute_descriptions=Vertex.GetAttributeDescriptions2();

		VkPipelineVertexInputStateCreateInfo vertex_input_info={
			pNext: null,
			vertexBindingDescriptionCount: 1,
			pVertexBindingDescriptions: &binding_description,
			vertexAttributeDescriptionCount: attribute_descriptions.length,
			pVertexAttributeDescriptions: attribute_descriptions.ptr
		};

		VkPipelineInputAssemblyStateCreateInfo input_assembly_info={
			pNext: null,
			topology: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, // VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN,
			primitiveRestartEnable: VK_FALSE
		};

		VkViewport viewport={
			x: 0f,
			y: 0f,
			width: _extents.width,
			height:_extents.height,
			minDepth: 0f,
			maxDepth: 1f
		};

		VkRect2D scissor={
			offset: { 0, 0 },
			extent: _extents
		};

		VkPipelineViewportStateCreateInfo viewport_state_info={
			viewportCount: 1,
			pViewports: &viewport,
			scissorCount: 1,
			pScissors: &scissor
		};

		VkPipelineRasterizationStateCreateInfo rasterizer_info={
			depthClampEnable: VK_FALSE,
			rasterizerDiscardEnable: VK_FALSE,
			polygonMode: VK_POLYGON_MODE_FILL,
			lineWidth: 1f,
			cullMode: VK_CULL_MODE_BACK_BIT,
			frontFace: VK_FRONT_FACE_CLOCKWISE, // VK_FRONT_FACE_COUNTER_CLOCKWISE
			depthBiasEnable: VK_FALSE,
			depthBiasConstantFactor: 0f,
			depthBiasClamp: 0f,
			depthBiasSlopeFactor: 0f
		};

		VkPipelineMultisampleStateCreateInfo multisampling_info={
			sampleShadingEnable: VK_FALSE,
			rasterizationSamples: VK_SAMPLE_COUNT_1_BIT,
			minSampleShading: 1f,
			pSampleMask: null,
			alphaToCoverageEnable: VK_FALSE,
			alphaToOneEnable: VK_FALSE
		};

		VkPipelineColorBlendAttachmentState colour_blend_attachment={
			colorWriteMask: VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
			blendEnable: VK_FALSE,
			srcColorBlendFactor: VK_BLEND_FACTOR_ONE,
			dstColorBlendFactor: VK_BLEND_FACTOR_ZERO,
			colorBlendOp: VK_BLEND_OP_ADD,
			srcAlphaBlendFactor: VK_BLEND_FACTOR_ONE,
			dstAlphaBlendFactor: VK_BLEND_FACTOR_ZERO,
			alphaBlendOp: VK_BLEND_OP_ADD
		};

		VkPipelineColorBlendStateCreateInfo colour_blend_info={
			logicOpEnable: VK_FALSE,
			logicOp: VK_LOGIC_OP_COPY,
			attachmentCount: 1,
			pAttachments: &colour_blend_attachment,
			blendConstants: [ 0f, 0f, 0f, 0f ]
		};

		VkDynamicState[] dynamic_states=[ VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_LINE_WIDTH ];

		VkPipelineDynamicStateCreateInfo dynamic_state_info={
			dynamicStateCount: 2,
			pDynamicStates: dynamic_states.ptr
		};

		CreateDescriptorSetLayout();
		CreateTextureDescriptorLayout();

		VkDescriptorSetLayout[] pipeline_descriptor_layouts=[_descriptor_set_layout, _texture_descriptor_layout];
		VkPipelineLayoutCreateInfo pipeline_layout_info={
			setLayoutCount: pipeline_descriptor_layouts.length,
			pSetLayouts: pipeline_descriptor_layouts.ptr,
			pushConstantRangeCount: 0,
			pPushConstantRanges: null
		};

		VkResult res=vkCreatePipelineLayout(g_Device, &pipeline_layout_info, null, &_pipeline_layout);
		test_out.writeln("Pipeline Layout created. ", res);

		/// Pipeline for real!

		VkPipelineDepthStencilStateCreateInfo depth_stencil_info={
			depthTestEnable: VK_TRUE,
			depthWriteEnable: VK_TRUE,
			depthCompareOp: VK_COMPARE_OP_LESS,
			depthBoundsTestEnable: VK_FALSE,
			minDepthBounds: 0f,
			maxDepthBounds: 1f,
			stencilTestEnable: VK_FALSE
		};

		VkGraphicsPipelineCreateInfo graphics_pipe_info={
			stageCount: 2,
			pStages: shader_stages.ptr,
			pVertexInputState: &vertex_input_info,
			pInputAssemblyState: &input_assembly_info,
			pViewportState: &viewport_state_info,
			pRasterizationState: &rasterizer_info,
			pMultisampleState: &multisampling_info,
			pColorBlendState: &colour_blend_info,
			pDepthStencilState: &depth_stencil_info,
			layout: _pipeline_layout,
			renderPass: _render_pass,
			basePipelineHandle: VK_NULL_ND_HANDLE,
			basePipelineIndex: -1
		};

		vkCreateGraphicsPipelines(g_Device, VK_NULL_ND_HANDLE, 1, &graphics_pipe_info, null, &_pipeline);
		test_out.writeln("Graphics Pipeline created.");
	}

	void CreateFramebuffers()
	{
		foreach(size_t i, ref buffer; _buffers)
		{
			buffer.image=_images[i];
			buffer.view=CreateImageView(_images[i], _format, VK_IMAGE_ASPECT_COLOR_BIT);
			VkImageView[] fb_attachments=[ buffer.view, _depth_image_view ];
			VkFramebufferCreateInfo fb_create_info={
				renderPass: _render_pass,
				attachmentCount: fb_attachments.length,
				pAttachments: fb_attachments.ptr,
				width: _extents.width,
				height: _extents.height,
				layers: 1
			};
			vkCreateFramebuffer(g_Device, &fb_create_info, null, &buffer.framebuffer);
			test_out.writeln(buffer.framebuffer);
		}
	}

	void CreateVkCommandPool()
	{
		auto queue_family=GetQueueFamily();

		VkCommandPoolCreateInfo pool_info={
			pNext: null,
			flags: VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
			queueFamilyIndex: queue_family.graphics_family
		};

		vkCreateCommandPool(g_Device, &pool_info, null, &_command_pool);
		test_out.writeln(_command_pool);
	}

	void CreateCommandBuffers()
	{
		_command_buffers=new VkCommandBuffer[_buffers.length];

		VkCommandBufferAllocateInfo alloc_info={
			pNext: null,
			commandPool: _command_pool,
			level: VK_COMMAND_BUFFER_LEVEL_PRIMARY,
			commandBufferCount: _command_buffers.length
		};
		vkAllocateCommandBuffers(g_Device, &alloc_info, _command_buffers.ptr);

		test_out.writeln(_command_buffers);
	}

	uint FindMemoryType(uint filter, VkMemoryPropertyFlags properties)
	{
		VkPhysicalDeviceMemoryProperties memory_properties;
		vkGetPhysicalDeviceMemoryProperties(g_PhysicalDevice, &memory_properties);

		test_out.writeln(memory_properties);

		foreach(prop; 0..memory_properties.memoryTypeCount)
		{
			if ((filter & (1 << prop)) && (memory_properties.memoryTypes[prop].propertyFlags & properties))
				return prop;
		}
		assert(0, "No valid memory types.");
	}

	void CreateVkBuffer(VkDeviceSize size, VkBufferUsageFlags usage, VkMemoryPropertyFlags properties, out VkBuffer buffer, out VkMappedMemoryRange memory)
	{
		VkBufferCreateInfo buffer_info={
			size: size,
			usage: usage,
			sharingMode: VK_SHARING_MODE_EXCLUSIVE
		};
		CreateAllocBuffer(g_Allocator, buffer_info, properties, buffer, &memory, null);
	}

	void CopyVkBuffer(VkBuffer source, VkBuffer dest, VkDeviceSize size)
	{
		VkCommandBuffer cmd_buffer=BeginSingleTimeCommands();

		VkBufferCopy copy_region={
			srcOffset: 0,
			dstOffset: 0,
			size: size
		};
		vkCmdCopyBuffer(cmd_buffer, source, dest, 1, &copy_region);

		EndSingleTimeCommands(cmd_buffer);
	}

	// rename to PopulateBuffer, or something?
	void CreateVertexBuffer(VkDeviceSize size, void* data, VkBufferUsageFlags flags, out VkBuffer buffer_out, out VkMappedMemoryRange memory_out)
	{
		VkBuffer staging_buffer;
		VkDeviceMemory staging_memory;

		VkBufferCreateInfo buffer_info={
			size: size,
			usage: VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
			sharingMode: VK_SHARING_MODE_EXCLUSIVE
		};
		VkMappedMemoryRange range;
		CreateAllocBuffer(g_Allocator, buffer_info, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, staging_buffer, &range, null);

		void* staging_data;
		vmaMapMemory(range, &staging_data);
		import core.stdc.string: memcpy;
		memcpy(staging_data, data, cast(size_t)size);
		vmaUnmapMemory(range);

		buffer_info.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT | flags;
		CreateAllocBuffer(g_Allocator, buffer_info, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, buffer_out, &memory_out, null);
		CopyVkBuffer(staging_buffer, buffer_out, size);

		vkDestroyBuffer(g_Device, staging_buffer, null);
		vkFreeMemory(g_Device, staging_memory, null);
	}

	VkBuffer[] _uniform_buffers;
	VkMappedMemoryRange[] _uniform_buffers_memory;

	void CreateUniformBuffers()
	{
		VkDeviceSize buffer_size=UniformBufferObject.sizeof;

		_uniform_buffers=new VkBuffer[_buffers.length];
		_uniform_buffers_memory=new VkMappedMemoryRange[_buffers.length];

		foreach(i; 0.._buffers.length)
		{
			CreateVkBuffer(buffer_size, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, _uniform_buffers[i], _uniform_buffers_memory[i]);
		}
	}

	void CreateLightListUniformBuffers()
	{
		VkDeviceSize buffer_size=LightListUbo.sizeof;

		_light_list_ubo=new VkBuffer[_buffers.length];
		_light_list_ubo_memory=new VkMappedMemoryRange[_buffers.length];

		foreach(i; 0.._buffers.length)
		{
			CreateVkBuffer(buffer_size, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, _light_list_ubo[i], _light_list_ubo_memory[i]);
		}
	}

	void UpdateLightListUbo(uint image_index)
	{
		import Main: g_IsIn3D, g_RenderContext;
		import Objects.BaseObject;
		import Objects.Light;
		import WorldBsp: WorldBsp;

		LightListUbo ubo;
		// iterate lights, set count
		if (g_RenderContext !is null) // FIXME: pls kill me
		{
			debug(FrameTrace) test_out.writeln("--- Updating Light List");

			WorldBsp* bsp=g_RenderContext.main_world.world_bsp;

			void ProcessNodeLights(Node* node)
			{
				if (node.objects!=null)
				{
					ObjectList* curr=node.objects.prev;

					while(curr!=node.objects)
					{
						BaseObject* obj=curr.data;

						if (obj.class_!=null) break;

						if ((obj.flags & ObjectFlags.Visible) && !(obj.flags & ObjectFlags.SkyObject) && obj.type_id==ObjectType.Light)
						{
							if (ubo.count<40 && !(obj.flags & ObjectFlags.OnlyLightWorld) && !(obj.flags & ObjectFlags.FogLight))
							{
								ubo.lights[ubo.count++]=LightObj(obj.position, vec3(obj.colour[0]/255f, obj.colour[1]/255f, obj.colour[3]/255f), obj.ToLight().radius);
							}
						}
						curr=curr.prev;
					}
				}

				if (node.next[0].flags & 8)
					ProcessNodeLights(node.next[0]);
				if (node.next[1].flags & 8)
					ProcessNodeLights(node.next[1]);
			}

			ProcessNodeLights(bsp.root_node);
		}

		debug(FrameTrace) test_out.writeln(ubo);

		void* data;
		vmaMapMemory(_light_list_ubo_memory[image_index], &data);

		import core.stdc.string: memcpy;
		memcpy(data, &ubo, ubo.sizeof);

		vmaUnmapMemory(_light_list_ubo_memory[image_index]);
	}

	void UpdateUniformBuffer(uint image_index)
	{
		UniformBufferObject ubo;
		ubo.model=mat4.identity.translate(0f, 0f, 0f).transposed();

		void RotTransCamera(vec3 pos, quat rot, out mat4 mat4_out)
		{
			//float x_scale=1f, y_scale=-1f, z_scale=-1f; // rotation scaling

			float x2=rot.x*rot.x;
			float y2=rot.y*rot.y;
			float z2=rot.z*rot.z;
			float w2=rot.w*rot.w;

			mat4_out[0][0]=x2-y2-z2+w2;
			mat4_out[1][1]=-(-x2+y2-z2+w2);
			mat4_out[2][2]=-(-x2-y2+z2+w2);

			float xy=rot.x*rot.y;
			float zw=rot.z*rot.w;
			mat4_out[0][1]=2f*(xy+zw);
			mat4_out[1][0]=-2f*(xy-zw);

			float xz=rot.x*rot.z;
			float yw=rot.y*rot.w;
			mat4_out[0][2]=2f*(xz-yw);
			mat4_out[2][0]=-2f*(xz+yw);

			float yz=rot.y*rot.z;
			float xw=rot.x*rot.w;
			mat4_out[1][2]=-2f*(yz+xw);
			mat4_out[2][1]=-2f*(yz-xw);

			float x=-pos.x, y=-pos.y, z=-pos.z;
			mat4_out[0][3]=x-x*mat4_out[0][0]-y*mat4_out[0][1]-z*mat4_out[0][2];
			mat4_out[1][3]=y-x*mat4_out[1][0]-y*mat4_out[1][1]-z*mat4_out[1][2];
			mat4_out[2][3]=z-x*mat4_out[2][0]-y*mat4_out[2][1]-z*mat4_out[2][2];

			// this isn't an exact match to the original renderer, but it's 3-4 decimal accurate, which is probably fine
			mat4_out[0][3]=-(mat4_out[0][3]-x);
			mat4_out[1][3]=-(mat4_out[1][3]-y);
			mat4_out[2][3]=-(mat4_out[2][3]-z);

			mat4_out[3][0]=mat4_out[3][1]=mat4_out[3][2]=0f;
			mat4_out[3][3]=1f;
		}

		mat4 test_camera_out=mat4.identity();
		RotTransCamera(camera_pos, camera_view, test_camera_out);
		ubo.view=test_camera_out.transposed();

		ubo.proj=mat4.perspective(_extents.width, _extents.height, fov_global, 0.1f, 15000f).transposed();

		void* data;
		//vkMapMemory(g_Device, _uniform_buffers_memory[image_index], 0, ubo.sizeof, 0, &data);
		vmaMapMemory(_uniform_buffers_memory[image_index], &data);

		import core.stdc.string: memcpy;
		memcpy(data, &ubo, ubo.sizeof);

		//vkUnmapMemory(g_Device, _uniform_buffers_memory[image_index]);
		vmaUnmapMemory(_uniform_buffers_memory[image_index]);
	}

	VkDescriptorSetLayout _descriptor_set_layout;
	VkDescriptorPool _descriptor_pool;
	VkDescriptorSet[] _descriptor_sets;

	void CreateDescriptorSetLayout()
	{
		VkDescriptorSetLayoutBinding ubo_layout_binding={
			binding: 0,
			descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
			descriptorCount: 1,
			stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
			pImmutableSamplers: null
		};

		VkDescriptorSetLayoutBinding lights_ubo_layout_binding={
			binding: 2,
			descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
			descriptorCount: 1,
			stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
			pImmutableSamplers: null
		};

		VkDescriptorSetLayoutBinding sampler_layout_binding={
			binding: 1,
			descriptorType: VK_DESCRIPTOR_TYPE_SAMPLER,
			descriptorCount: 1,
			pImmutableSamplers: null,
			stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT
		};

		VkDescriptorSetLayoutBinding[] bindings=[ ubo_layout_binding, sampler_layout_binding, lights_ubo_layout_binding ];

		VkDescriptorSetLayoutCreateInfo create_info={
			bindingCount: bindings.length,
			pBindings: bindings.ptr
		};

		vkCreateDescriptorSetLayout(g_Device, &create_info, null, &_descriptor_set_layout);
	}

	void CreateDescriptorPool()
	{
		VkDescriptorPoolSize[] pool_size=[
		{
			type: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
			descriptorCount: _buffers.length*2
		},
		{
			type: VK_DESCRIPTOR_TYPE_SAMPLER,
			descriptorCount: _buffers.length
		} ];

		VkDescriptorPoolCreateInfo pool_info={
			poolSizeCount: pool_size.length,
			pPoolSizes: pool_size.ptr,
			maxSets: _buffers.length
		};

		vkCreateDescriptorPool(g_Device, &pool_info, null, &_descriptor_pool);
	}

	public void CreateDescriptorSets()
	{
		VkDescriptorSetLayout[] layouts=new VkDescriptorSetLayout[_buffers.length];
		layouts[]=_descriptor_set_layout;

		VkDescriptorSetAllocateInfo alloc_info={
			descriptorPool: _descriptor_pool,
			descriptorSetCount: _buffers.length,
			pSetLayouts: layouts.ptr
		};

		_descriptor_sets=new VkDescriptorSet[_buffers.length];
		vkAllocateDescriptorSets(g_Device, &alloc_info, _descriptor_sets.ptr);

		foreach(i; 0.._buffers.length)
		{
			VkDescriptorBufferInfo buffer_info={
				buffer: _uniform_buffers[i],
				offset: 0,
				range: UniformBufferObject.sizeof
			};

			VkDescriptorBufferInfo lights_buffer_info={
				buffer: _light_list_ubo[i],
				offset: 0,
				range: LightListUbo.sizeof
			};

			VkDescriptorImageInfo image_info={
				imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
				//imageView: _texture_image_view,
				sampler: _texture_sampler
			};

			VkWriteDescriptorSet[] descriptor_write=[
			{
				dstSet: _descriptor_sets[i],
				dstBinding: 0,
				dstArrayElement: 0,
				descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
				descriptorCount: 1,
				pBufferInfo: &buffer_info
			},
			{
				dstSet: _descriptor_sets[i],
				dstBinding: 1,
				dstArrayElement: 0,
				descriptorType: VK_DESCRIPTOR_TYPE_SAMPLER,
				descriptorCount: 1,
				pImageInfo: &image_info
			},
			{
				dstSet: _descriptor_sets[i],
				dstBinding: 2,
				dstArrayElement: 0,
				descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
				descriptorCount: 1,
				pBufferInfo: &lights_buffer_info
			} ];

			vkUpdateDescriptorSets(g_Device, descriptor_write.length, descriptor_write.ptr, 0, null);
		}
	}

	VkDescriptorSetLayout _texture_descriptor_layout;
	VkDescriptorPool _texture_descriptor_pool;
	void CreateTextureDescriptorLayout()
	{
		VkDescriptorSetLayoutBinding texture_binding={
			binding: 0,
			descriptorType: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
			descriptorCount: 1,
			stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT
		};

		VkDescriptorSetLayoutCreateInfo create_info={
			bindingCount: 1,
			pBindings: &texture_binding
		};

		vkCreateDescriptorSetLayout(g_Device, &create_info, null, &_texture_descriptor_layout);
	}

	void CreateTextureDescriptorPool()
	{
		// sets are freed again by UnbindTexture
		VkDescriptorPoolSize[] pool_size=[ {
			type: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
			descriptorCount: 4096
		} ];

		VkDescriptorPoolCreateInfo pool_info={
			flags: VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
			poolSizeCount: pool_size.length,
			pPoolSizes: pool_size.ptr,
			maxSets: 4096
		};

		vkCreateDescriptorPool(g_Device, &pool_info, null, &_texture_descriptor_pool);
	}

	public void CreateTextureDescriptorSet(VkImageView image_view, out VkDescriptorSet set_out)
	{
		VkDescriptorSetAllocateInfo alloc_info={
			descriptorPool: _texture_descriptor_pool,
			descriptorSetCount: 1,
			pSetLayouts: &_texture_descriptor_layout
		};

		vkAllocateDescriptorSets(g_Device, &alloc_info, &set_out);

		VkDescriptorImageInfo image_info={
			imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
			imageView: image_view,
			//sampler: _texture_sampler
		};

		VkWriteDescriptorSet[] descriptor_write=[ {
			dstSet: set_out,
			dstBinding: 0,
			dstArrayElement: 0,
			descriptorType: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
			descriptorCount: 1,
			pImageInfo: &image_info
		} ];

		vkUpdateDescriptorSets(g_Device, descriptor_write.length, descriptor_write.ptr, 0, null);
	}

	VkImage _texture_image;
	VkMappedMemoryRange _texture_image_memory;

	public void CreateTextureImage()
	{
		//if (TextureData* tex_data=texture.engine_data)
		{
			import std.string: toStringz;
			import dimage;

			int width=16, height=16, channels=4;

			// get pixels
			File source=File("test_texture.png");
			Image texture=PNG.load(source);
			width=texture.width;
			height=texture.height;
			ubyte[] pixels=texture.imageData.raw; //=TransitionTexturePixels(texture);

			size_t image_size=width*height*channels;

			VkBuffer staging_buffer;
			VkMappedMemoryRange staging_memory;

			CreateVkBuffer(image_size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, staging_buffer, staging_memory);

			void* data;
			vmaMapMemory(staging_memory, &data);
			import core.stdc.string: memcpy;
			memcpy(data, pixels.ptr, cast(size_t)image_size);
			vmaUnmapMemory(staging_memory);

			// free pixels
			pixels=null;

			CreateVkImage(width, height, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TILING_OPTIMAL, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, _texture_image, _texture_image_memory);
			TransitionImageLayout(_texture_image, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
			CopyBufferToImage(staging_buffer, _texture_image, width, height);
			TransitionImageLayout(_texture_image, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

			vkDestroyBuffer(g_Device, staging_buffer, null);
			//vkFreeMemory(g_Device, staging_memory.memory, null);
		}
	}

	public void CreateTextureImage(SharedTexture* texture, out VkImage texture_img, out VkMappedMemoryRange texture_mem)
	{
		if (TextureData* tex_data=texture.engine_data)
		{
			int width, height, channels;

			ubyte[] pixels=TransitionTexturePixels(tex_data, width, height, channels, 8);

			size_t image_size=width*height*channels;

			VkBuffer staging_buffer;
			VkMappedMemoryRange staging_memory;

			CreateVkBuffer(image_size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, staging_buffer, staging_memory);

			void* data;
			vmaMapMemory(staging_memory, &data);
			import core.stdc.string: memcpy;
			memcpy(data, pixels.ptr, cast(size_t)image_size);
			vmaUnmapMemory(staging_memory);

			// free pixels
			pixels=null;

			CreateVkImage(width, height, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TILING_OPTIMAL, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, texture_img, texture_mem);
			TransitionImageLayout(texture_img, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
			CopyBufferToImage(staging_buffer, texture_img, width, height);
			TransitionImageLayout(texture_img, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

			vkDestroyBuffer(g_Device, staging_buffer, null);
			//vkFreeMemory(g_Device, staging_memory.memory, null);
		}
	}

	// the GPU is idle between frames (SwapBuffers waits), so this is safe whenever the engine calls it
	public void DestroyTextureImage(VkImage image, VkImageView image_view, VkDescriptorSet descriptor)
	{
		if (descriptor!=VK_NULL_ND_HANDLE)
			vkFreeDescriptorSets(g_Device, _texture_descriptor_pool, 1, &descriptor);
		vkDestroyImageView(g_Device, image_view, null);
		vkDestroyImage(g_Device, image, null);
	}

	void CreateVkImage(uint width, uint height, VkFormat format, VkImageTiling tiling, VkImageUsageFlags usage, VkMemoryPropertyFlags properties, out VkImage image, out VkMappedMemoryRange memory)
	{
		VkImageCreateInfo image_info={
			imageType: VK_IMAGE_TYPE_2D,
			extent: {
				width: width,
				height: height,
				depth: 1
			},
			mipLevels: 1,
			arrayLayers: 1,
			format: format,
			tiling: tiling,
			initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
			usage: usage,
			samples: VK_SAMPLE_COUNT_1_BIT,
			sharingMode: VK_SHARING_MODE_EXCLUSIVE
		};

		CreateAllocImage(g_Allocator, image_info, properties, image, &memory, null);
	}

	public VkCommandBuffer BeginSingleTimeCommands()
	{
		VkCommandBufferAllocateInfo alloc_info={
			level: VK_COMMAND_BUFFER_LEVEL_PRIMARY,
			commandPool: _command_pool,
			commandBufferCount: 1
		};
		VkCommandBuffer command_buffer;
		vkAllocateCommandBuffers(g_Device, &alloc_info, &command_buffer);

		VkCommandBufferBeginInfo begin_info={
			flags: VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
		};
		vkBeginCommandBuffer(command_buffer, &begin_info);

		return command_buffer;
	}

	public void EndSingleTimeCommands(VkCommandBuffer command_buffer)
	{
		vkEndCommandBuffer(command_buffer);

		VkSubmitInfo submit_info={
			commandBufferCount: 1,
			pCommandBuffers: &command_buffer
		};
		vkQueueSubmit(_graphics_queue, 1, &submit_info, VK_NULL_ND_HANDLE);
		vkQueueWaitIdle(_graphics_queue);
		vkFreeCommandBuffers(g_Device, _command_pool, 1, &command_buffer);
	}

	void TransitionImageLayout(VkImage image, VkFormat format, VkImageLayout layout_out, VkImageLayout layout_new)
	{
		VkCommandBuffer cmd_buffer=BeginSingleTimeCommands();

		VkImageMemoryBarrier barrier={
			oldLayout: layout_out,
			newLayout: layout_new,
			srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
			image: image,
			subresourceRange: {
				aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
				baseMipLevel: 0,
				levelCount: 1,
				baseArrayLayer: 0,
				layerCount: 1
			},
			srcAccessMask: 0,
			dstAccessMask: 0
		};

		VkPipelineStageFlags source_stage, dest_stage;

		if (layout_out==VK_IMAGE_LAYOUT_UNDEFINED && layout_new==VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
		{
			barrier.srcAccessMask=0;
			barrier.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;
			source_stage=VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
			dest_stage=VK_PIPELINE_STAGE_TRANSFER_BIT;
		}
		else if (layout_out==VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL && layout_new==VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
		{
			barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;
			barrier.dstAccessMask=VK_ACCESS_SHADER_READ_BIT;
			source_stage=VK_PIPELINE_STAGE_TRANSFER_BIT;
			dest_stage=VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
		}
		else
		{
			assert(0, "Unhandled layout types in " ~ __FUNCTION__);
		}

		vkCmdPipelineBarrier(cmd_buffer, source_stage, dest_stage, 0, 0, null, 0, null, 1, &barrier);

		EndSingleTimeCommands(cmd_buffer);
	}

	void CopyBufferToImage(VkBuffer buffer, VkImage image, uint width, uint height)
	{
		VkCommandBuffer cmd_buffer=BeginSingleTimeCommands();

		VkBufferImageCopy image_copy={
			bufferOffset: 0,
			bufferRowLength: 0,
			bufferImageHeight: 0,
			imageSubresource: {
				aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
				mipLevel: 0,
				baseArrayLayer: 0,
				layerCount: 1
			},
			imageOffset: { 0, 0, 0 },
			imageExtent: { width, height, 1 }
		};
		vkCmdCopyBufferToImage(cmd_buffer, buffer, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &image_copy);

		EndSingleTimeCommands(cmd_buffer);
	}

	VkImageView _texture_image_view;

	public VkImageView CreateImageView(VkImage image, VkFormat format, VkImageAspectFlags aspect_flags, VkComponentMapping* colour_map=null)
	{
		VkImageViewCreateInfo view_info={
			image: image,
			viewType: VK_IMAGE_VIEW_TYPE_2D,
			format: format,
			components: colour_map ? *colour_map : VkComponentMapping(VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY),
			subresourceRange: {
				aspectMask: aspect_flags,
				baseMipLevel: 0,
				levelCount: 1,
				baseArrayLayer: 0,
				layerCount: 1
			}
		};

		VkImageView image_view;
		vkCreateImageView(g_Device, &view_info, null, &image_view);

		return image_view;
	}

	VkSampler _texture_sampler;
	public void CreateTextureSampler()
	{
		VkPhysicalDeviceProperties properties;
		vkGetPhysicalDeviceProperties(g_PhysicalDevice, &properties);

		VkSamplerCreateInfo create_info={
			magFilter: VK_FILTER_LINEAR,
			minFilter: VK_FILTER_LINEAR,
			addressModeU: VK_SAMPLER_ADDRESS_MODE_REPEAT,
			addressModeV: VK_SAMPLER_ADDRESS_MODE_REPEAT,
			addressModeW: VK_SAMPLER_ADDRESS_MODE_REPEAT,
			anisotropyEnable: VK_TRUE,
			maxAnisotropy: properties.limits.maxSamplerAnisotropy,
			borderColor: VK_BORDER_COLOR_INT_OPAQUE_BLACK,
			unnormalizedCoordinates: VK_FALSE,
			compareEnable: VK_FALSE,
			compareOp: VK_COMPARE_OP_ALWAYS,
			mipmapMode: VK_SAMPLER_MIPMAP_MODE_LINEAR,
			mipLodBias: 0f,
			minLod: 0f,
			maxLod: 0f
		};
		vkCreateSampler(g_Device, &create_info, null, &_texture_sampler);
	}

	VkFormat FindSupportedFormat(const VkFormat[] candidates, VkImageTiling tiling, VkFormatFeatureFlags features)
	{
		foreach(format; candidates)
		{
			VkFormatProperties properties;
			vkGetPhysicalDeviceFormatProperties(g_PhysicalDevice, format, &properties);

			if (tiling==VK_IMAGE_TILING_LINEAR && (properties.linearTilingFeatures & features)==features)
				return format;
			else if (tiling==VK_IMAGE_TILING_OPTIMAL && (properties.optimalTilingFeatures & features)==features)
				return format;
		}

		assert(0, "No supported formats found!");
	}

	VkFormat FindDepthFormat()
	{
		return FindSupportedFormat([ VK_FORMAT_D32_SFLOAT, VK_FORMAT_D32_SFLOAT_S8_UINT, VK_FORMAT_D24_UNORM_S8_UINT ], VK_IMAGE_TILING_OPTIMAL, VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT);
	}

	bool HasStencilComponent(VkFormat format)
	{
		return format==VK_FORMAT_D32_SFLOAT_S8_UINT || VK_FORMAT_D24_UNORM_S8_UINT;
	}

	void CreateDepthBuffer()
	{
		VkFormat depth_format=FindDepthFormat();
		CreateVkImage(_extents.width, _extents.height, depth_format, VK_IMAGE_TILING_OPTIMAL, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, _depth_image, _depth_image_memory);
		_depth_image_view=CreateImageView(_depth_image, depth_format, VK_IMAGE_ASPECT_DEPTH_BIT);
	}

	uint index_count=0;

	// world geometry is rebuilt per level (CreateContext); the allocator never reclaims the memory itself
	public void DestroyBspBuffers()
	{
		vkDeviceWaitIdle(g_Device);

		vkDestroyBuffer(g_Device, _vertex_buffer, null);
		vkDestroyBuffer(g_Device, _vertex_index_buffer, null);
		_vertex_buffer=VK_NULL_ND_HANDLE;
		_vertex_index_buffer=VK_NULL_ND_HANDLE;
		index_count=0;
	}

	public void CreateBspVertexBuffer(WorldBsp* bsp)
	{
		DestroyBspBuffers(); // the previous level's, or the startup test geometry

		test_out.writeln("-- Begin create BSP");
		//

		Polygon*[] polygons=bsp.polygons[0..bsp.polygon_count];

		Vertex[] vert_buffer=new Vertex[0];
		uint[] indices=new uint[0];

		uint vert_count=0;

		foreach(i, polygon; polygons)
		{
			import WorldBsp: GenerateLightmapUvs;
			GenerateLightmapUvs(*polygon);

			vert_count=vert_buffer.length;

			if (polygon.surface.flags & SurfaceFlags.Invisible)
				continue;

			foreach(j, vertex; polygon.DiskVerts())
			{
				Vertex new_vert;
				with(new_vert)
				{
					pos=(*vertex.vertex_data).xyz;
					colour.r=vertex.colour[0]/255f;
					colour.g=vertex.colour[1]/255f;
					colour.b=vertex.colour[2]/255f;
					uv=vertex.uv;
				}

				vert_buffer~=new_vert;

				if (j>2)
				{
					indices~=cast(uint)(vert_count);
					indices~=cast(uint)(vert_count+j-1);
				}

				indices~=cast(uint)(vert_count+j);
			}
		}

		bool DoNode(Node* node, out Vertex[] verts_out, out uint[] indices_out)
		{
			test_out.writeln(*node);

			return false;
		}

		Vertex[] verts_extra;
		uint[] indices_extra;

		DoNode(bsp.root_node, verts_extra, indices_extra);

		index_count=indices.length;
		test_out.writeln(index_count);

		CreateVertexBuffer(cast(VkDeviceSize)(Vertex.sizeof*vert_buffer.length), vert_buffer.ptr, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, _vertex_buffer, _vertex_buffer_memory);
		CreateVertexBuffer(cast(VkDeviceSize)(uint.sizeof*indices.length), indices.ptr, VK_BUFFER_USAGE_INDEX_BUFFER_BIT, _vertex_index_buffer, _vertex_index_memory);

		test_out.writeln("-- End create BSP, ", vert_buffer.length);
	}
}

class Shader
{
	static ubyte[] ReadShader(inout string file_name)
	{
		import std.stdio;
		File shader_file;
		shader_file.open(file_name, "rb");
		scope(exit) shader_file.close();
		ulong file_size=shader_file.size;
		return shader_file.rawRead(new ubyte[cast(uint)file_size]);
	}

	static VkShaderModule CreateShaderModule(ref VkDevice device, const ubyte[] shader_bytecode)
	{
		VkShaderModuleCreateInfo shader_create_info={
			pNext: null,
			codeSize: shader_bytecode.length,
			pCode: cast(uint*)shader_bytecode.ptr
		};

		VkShaderModule shader_module;
		test_out.writeln("Shader: ", vkCreateShaderModule(device, &shader_create_info, null, &shader_module));

		return shader_module;
	}
}