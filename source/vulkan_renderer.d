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
import SceneGeometry: ObjectGeometry;
import LTObjects: LTObject, DynamicLight;
import EffectsDraw: EffectView;

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
	vec2 lightmap_uv; // in the lightmap atlas, normalised
	float lightmapped; // 1 = lit by the lightmap, 0 = by the pre-lit colour

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
	VkPipeline _pipeline_depth_only; // sky portals: depth, no colour

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
		DestroyObjectRendering();

		DestroyAllocBuffer(g_Allocator, _vertex_buffer);

		foreach(ref buffer; _buffers)
			vkDestroyFramebuffer(g_Device, buffer.framebuffer, null);

		vkDestroyPipeline(g_Device, _pipeline, null);
		vkDestroyPipeline(g_Device, _pipeline_depth_only, null);

		vkDestroyPipelineLayout(g_Device, _pipeline_layout, null);
		vkDestroyRenderPass(g_Device, _render_pass, null);

		vkDestroyShaderModule(g_Device, vk_vertex_shader, null);
		vkDestroyShaderModule(g_Device, vk_frag_shader, null);

		foreach(ref buffer; _buffers)
			vkDestroyImageView(g_Device, buffer.view, null);

		vkDestroySwapchainKHR(g_Device, _swapchain, null);

		// the blocks belong to this device; a later InitFrom gets a fresh allocator
		if (g_Allocator !is null)
		{
			g_Allocator.ReleaseAll();
			g_Allocator=null;
		}
		vkDestroyDevice(g_Device, null);
		vkDestroySurfaceKHR(g_VkInstance, _surface, null);
		vkDestroyInstance(g_VkInstance, null);
		ShowCursor(TRUE);
		test_out.close();
	}

	override void InitFrom(void* window)
	{
		test_out.open("vk_test.txt", "w");

		import erupted.vulkan_lib_loader;
		loadGlobalLevelFunctions(test_out.getFP());

		{
			import Main: _renderer;

			test_out.writeln("hDC: ", GetDC(window), ", WndProc: ", cast(void*)GetWindowLong(window, GWL_WNDPROC));

			// the mode the engine picked (screen_width/height are set by Init before this)
			_screen_width=(_renderer && _renderer.screen_width>0) ? _renderer.screen_width : Width;
			_screen_height=(_renderer && _renderer.screen_height>0) ? _renderer.screen_height : Height;
			SetupWindow(cast(HWND)window);

			// d3d.ren hides the cursor for the renderer's lifetime (d3d_init.cpp, shown again in d3d_FreeDDraw)
			ShowCursor(FALSE);
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
		UpdateFrameViewport();

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
		CreateObjectPipelines();

		///
		VkSemaphoreCreateInfo semaphore_info;
		vkCreateSemaphore(g_Device, &semaphore_info, null, &_is_image_available);
		vkCreateSemaphore(g_Device, &semaphore_info, null, &_is_render_finished);

		test_out.writeln("Vulkan done.");
	}

	float[3] _global_light_scale=[1f, 1f, 1f]; // SceneDesc GlobalLightScale of the last scene

	enum FogKind { None, World, Sky }

	// D3D table fog from the renderer console variables, read every normal scene (d3d_extra_consolevars.cpp): FogEnable,
	// FogNearZ / FogFarZ (0 / 2000), FogR/G/B (255); the sky pass uses SkyFogNearZ / SkyFogFarZ (0 / 2000). Fog is off
	// when near and far are equal.
	bool _fog_enable;
	float[3] _fog_colour=[1f, 1f, 1f];
	float[2] _fog_range=[0f, 2000f], _sky_fog_range=[0f, 2000f];
	// d3d.ren draws pre-transformed vertices, so D3D table fog compares the ranges with the device depth (0..1), not world
	// units, and Blood II's ranges (e.g. 700..2000) fog nothing; verified against d3d.ren under dgVoodoo (the opening train
	// level is unfogged). Console "d_FogMode 1" fogs by eye distance instead, as the ranges suggest was meant.
	bool _fog_by_distance;
	// console "Saturate" (Blood II's autoexec sets 1): the lightmap pass B blends SRCBLEND DESTCOLOR, doubling lightmapped
	// surfaces (blood2_recon port_notes/world.md 4.1)
	bool _saturate;

	// shader.frag / object.frag push constants: GlobalLightScale and texture mode (0 normal, 1 fullbright, 2 untextured,
	// 3 world fullbright), fog colour and switch, fog range
	void PushBatchConstants(VkCommandBuffer buffer, float texture_mode, FogKind fog=FogKind.World)
	{
		const float[2] range=fog==FogKind.Sky ? _sky_fog_range : _fog_range;
		const bool fog_on=_fog_enable && fog!=FogKind.None && range[0]!=range[1];
		const float[12] constants=[
			_global_light_scale[0], _global_light_scale[1], _global_light_scale[2], texture_mode,
			_fog_colour[0], _fog_colour[1], _fog_colour[2], fog_on ? 1f : 0f,
			range[0], range[1], _fog_by_distance ? 1f : 0f, _saturate ? 1f : 0f
		];
		vkCmdPushConstants(buffer, _pipeline_layout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, constants.sizeof, constants.ptr);
	}

	void ReadFogSettings()
	{
		import Main: _renderer;

		float ConsoleFloat(const(char)* name, float default_value)
		{
			void* variable=_renderer ? _renderer.GetConsoleVar(name) : null;
			return variable ? _renderer.GetVarValueFloat(variable) : default_value;
		}

		_fog_enable=ConsoleFloat("FogEnable", 0f)!=0f;
		_fog_colour=[ConsoleFloat("FogR", 255f)/255f, ConsoleFloat("FogG", 255f)/255f, ConsoleFloat("FogB", 255f)/255f];
		_fog_range=[ConsoleFloat("FogNearZ", 0f), ConsoleFloat("FogFarZ", 2000f)];
		_sky_fog_range=[ConsoleFloat("SkyFogNearZ", 0f), ConsoleFloat("SkyFogFarZ", 2000f)];
		if (_fog_range[0]==_fog_range[1])
			_fog_enable=false;
		_fog_by_distance=ConsoleFloat("d_FogMode", 0f)!=0f;
		_saturate=ConsoleFloat("Saturate", 0f)!=0f;
	}

	//// Window: borderless fullscreen on the window's monitor (3D at the monitor's resolution), or with the engine's
	//// "windowed" console variable a window whose client area is the mode's size

	void SetupWindow(HWND window)
	{
		import Main: _renderer;

		void* windowed_var=_renderer ? _renderer.GetConsoleVar("windowed") : null;
		const bool windowed=windowed_var && _renderer.GetVarValueFloat(windowed_var)!=0f;

		if (windowed)
		{
			RECT rect={ 0, 0, _screen_width, _screen_height };
			AdjustWindowRectEx(&rect, GetWindowLong(window, GWL_STYLE), FALSE, GetWindowLong(window, GWL_EXSTYLE));
			SetWindowPos(window, HWND_NOTOPMOST, 0, 0, rect.right-rect.left, rect.bottom-rect.top, SWP_NOCOPYBITS | SWP_NOMOVE | SWP_NOACTIVATE);
		}
		else
		{
			// the primary monitor, like exclusive fullscreen: the engine recentres the cursor every frame at the
			// window's width/2, height/2 in screen coordinates (client.cpp), which assumes the window is at 0,0
			POINT origin={ 0, 0 };
			HMONITOR monitor=MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
			MONITORINFO info;
			info.cbSize=MONITORINFO.sizeof;
			GetMonitorInfoA(monitor, &info);

			SetWindowLong(window, GWL_STYLE, WS_POPUP | WS_VISIBLE);
			SetWindowLong(window, GWL_EXSTYLE, WS_EX_APPWINDOW);
			SetWindowPos(window, HWND_TOP, info.rcMonitor.left, info.rcMonitor.top, info.rcMonitor.right-info.rcMonitor.left,
				info.rcMonitor.bottom-info.rcMonitor.top, SWP_FRAMECHANGED | SWP_NOCOPYBITS | SWP_SHOWWINDOW);
		}

		RECT client;
		GetClientRect(window, &client);
		test_out.writeln(windowed ? "Windowed" : "Borderless fullscreen", ", mode ", _screen_width, "x", _screen_height,
			", window client ", client.right-client.left, "x", client.bottom-client.top);
	}

	// window resized or minimised; false while there's nothing to present to
	bool RecreateSwapchain()
	{
		vkDeviceWaitIdle(g_Device);

		VkSurfaceCapabilitiesKHR capabilities;
		vkGetPhysicalDeviceSurfaceCapabilitiesKHR(g_PhysicalDevice, _surface, &capabilities);
		if (capabilities.currentExtent.width==0 || capabilities.currentExtent.height==0)
			return false;

		const size_t image_count=_buffers.length;
		foreach(ref buffer; _buffers)
		{
			vkDestroyFramebuffer(g_Device, buffer.framebuffer, null);
			vkDestroyImageView(g_Device, buffer.view, null);
		}
		vkDestroyImageView(g_Device, _depth_image_view, null);
		DestroyAllocImage(g_Allocator, _depth_image);
		vkDestroySwapchainKHR(g_Device, _swapchain, null);

		// render pass and pipelines don't depend on the size (dynamic viewport/scissor), only these do
		VkCheck(CreateVkSwapchain(_format, _colour_space, _swapchain), "vkCreateSwapchainKHR (recreate)");
		CreateVkImageViews(_swapchain, _images, _buffers);
		if (_buffers.length!=image_count) // command buffers, uniform buffers and descriptor sets are per image
			VkCheck(VK_ERROR_INITIALIZATION_FAILED, "swapchain image count changed on recreate");
		CreateDepthBuffer();
		CreateFramebuffers();
		UpdateFrameViewport();

		test_out.writeln("Swapchain recreated: ", _extents.width, "x", _extents.height);
		return true;
	}

	//// Framing: the engine draws in its mode's coordinates (_screen_width x _screen_height); that area is scaled into the
	//// swapchain keeping its aspect (pillar/letterboxed), and the scene's view rect is mapped into it

	VkViewport _frame_viewport; // the whole mode, for the 2D layer
	VkViewport _scene_viewport; // SceneDesc.view_rect, for the 3D scene

	void UpdateFrameViewport()
	{
		import std.algorithm: min;

		const float scale=min(_extents.width/cast(float)_screen_width, _extents.height/cast(float)_screen_height);
		const float width=_screen_width*scale, height=_screen_height*scale;
		_frame_viewport=VkViewport((_extents.width-width)*0.5f, (_extents.height-height)*0.5f, width, height, 0f, 1f);
		_scene_viewport=_frame_viewport;
	}

	VkViewport MapToFrame(const ref Rect rect)
	{
		const float scale=_frame_viewport.width/_screen_width;
		if (rect.x2<=rect.x1 || rect.y2<=rect.y1)
			return _frame_viewport;
		return VkViewport(_frame_viewport.x+rect.x1*scale, _frame_viewport.y+rect.y1*scale,
			(rect.x2-rect.x1)*scale, (rect.y2-rect.y1)*scale, 0f, 1f);
	}

	static VkRect2D ScissorOf(const ref VkViewport viewport)
	{
		return VkRect2D(VkOffset2D(cast(int)viewport.x, cast(int)viewport.y),
			VkExtent2D(cast(uint)(viewport.width+0.5f), cast(uint)(viewport.height+0.5f)));
	}

	void SetViewport(VkCommandBuffer buffer, const ref VkViewport viewport)
	{
		vkCmdSetViewport(buffer, 0, 1, &viewport);
		VkRect2D scissor=ScissorOf(viewport);
		vkCmdSetScissor(buffer, 0, 1, &scissor);
	}

	vec3 camera_pos;
	quat camera_view=quat.identity;
	float fov_x=1.5708f, fov_y=1.2f; // radians, from the scene
	override void RenderScene(SceneDesc* scene_desc) // vkCmd*
	{
		_scene_rendered=true;
		_global_light_scale=scene_desc.global_light_scale.vector;

		camera_pos=vec3(scene_desc.camera_position);
		camera_view=quat(scene_desc.camera_rotation[3], vec3(scene_desc.camera_rotation[0..3]));

		// the engine's horizontal and vertical FOV already match its view rect's aspect
		if (scene_desc.fov_x>0f && scene_desc.fov_y>0f)
		{
			fov_x=scene_desc.fov_x;
			fov_y=scene_desc.fov_y;
		}
		_scene_viewport=MapToFrame(scene_desc.view_rect);

		if (scene_desc.draw_mode!=DrawMode.ObjectList)
			ReadFogSettings();

		CollectObjects(scene_desc);

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

		// window resized/minimised: nothing was acquired, rebuild and skip this frame (suboptimal still presents)
		if (res==VK_ERROR_OUT_OF_DATE_KHR || res==VK_ERROR_SURFACE_LOST_KHR)
		{
			RecreateSwapchain();
			_scene_rendered=false;
			_objects.Clear();
			return;
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
				// release clears to black, there's holes in some maps (notably the train levels) that let you see the clear
				// colour and black is expected; debug clears the scene area separately below
				VkClearValue[] clear_colour=[ { color: {[ 0f, 0f, 0f, 1f ]} }, { depthStencil: { 1f, 0 } } ];

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

				// dynamic state of the world pipeline
				SetViewport(buffer, _scene_viewport);

				// the render pass clears to black (the bars around the mode's area); debug builds show holes in the
				// world in a loud colour instead
				debug if (_scene_rendered)
				{
					VkClearAttachment clear_attachment={
						aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
						colorAttachment: 0,
						clearValue: { color: {[ 0.4f, 0.58f, 0.93f, 1f ]} } // never clear to black! Black hides bugs!
					};
					VkClearRect clear_rect={ rect: ScissorOf(_scene_viewport), baseArrayLayer: 0, layerCount: 1 };
					vkCmdClearAttachments(buffer, 1, &clear_attachment, 1, &clear_rect);
				}

				// d3d.ren draws the sky before any world geometry, without depth (port_notes/sky.md)
				RecordObjectDraws(buffer, image_index, true);

				vkCmdBindPipeline(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _pipeline);
				vkCmdSetLineWidth(buffer, 1f);
				vkCmdBindDescriptorSets(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _pipeline_layout, 0, 1, &_descriptor_sets[image_index], 0, null);
				vkCmdBindDescriptorSets(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _pipeline_layout, 1, 1, &_texture_descriptor, 0, null);
				PushBatchConstants(buffer, 0f);

				if (g_RenderContext !is null && _vertex_buffer!=VK_NULL_ND_HANDLE)
				{
					VkBuffer[] vertex_buffers=[ _vertex_buffer ];
					VkDeviceSize[] offsets=[ 0 ];

					vkCmdBindVertexBuffers(buffer, 0, vertex_buffers.length, vertex_buffers.ptr, offsets.ptr);
					vkCmdBindIndexBuffer(buffer, _vertex_index_buffer, 0, VK_INDEX_TYPE_UINT32);

					WorldBsp* bsp=g_RenderContext.main_world.world_bsp;

					// the index buffer holds every visible polygon in order; sky_portals selects which ones a pass draws
					void DrawPolygons(bool sky_portals)
					{
						size_t index_start=0;
						RenderTexture last_texture=null;
						bool first=true;

						foreach(i, polygon; bsp.polygons[0..bsp.polygon_count])
						{
							if (polygon.surface.flags & SurfaceFlags.Invisible)
								continue;

							const int vert_count=(polygon.DiskVerts().length-2)*3;
							scope(exit) index_start+=vert_count;

							if (((polygon.surface.flags & SurfaceFlags.Sky)!=0)!=sky_portals)
								continue;

							// unbound (or never bound) textures fall back to the dummy texture
							SharedTexture* shared_texture=polygon.surface.shared_texture;
							RenderTexture this_texture=shared_texture ? cast(RenderTexture)shared_texture.render_data : null;
							if (!sky_portals && (first || last_texture !is this_texture))
							{
								first=false;
								last_texture=this_texture;
								VkDescriptorSet texture_image=this_texture ? this_texture.texture_descriptor : _texture_descriptor;
								vkCmdBindDescriptorSets(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _pipeline_layout, 1, 1, &texture_image, 0, null);
								PushBatchConstants(buffer, (this_texture && this_texture.fullbright) ? 1f : 0f);
							}

							vkCmdDrawIndexed(buffer, vert_count, 1, index_start, 0, 0);
						}
					}

					// sky portals are never drawn in d3d.ren, so the sky shows through them; here they write depth only, which
					// keeps world geometry behind them (that d3d.ren's visibility wouldn't draw) from covering the sky
					vkCmdBindPipeline(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _pipeline_depth_only);
					DrawPolygons(true);
					vkCmdBindPipeline(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _pipeline);
					DrawPolygons(false);
				}

				RecordObjectDraws(buffer, image_index, false);
				RecordOverlayDraw(buffer);

				vkCmdEndRenderPass(buffer);
				vkEndCommandBuffer(buffer);
			}

			UploadOverlay();
			UploadObjects();
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

		vkQueueWaitIdle(_graphics_queue);

		if (res==VK_ERROR_OUT_OF_DATE_KHR || res==VK_SUBOPTIMAL_KHR || res==VK_ERROR_SURFACE_LOST_KHR)
			RecreateSwapchain();
		_scene_rendered=false;
		_object_vertex_count+=_objects.vertices.length;
		_objects.Clear(); // built again by the next RenderScene

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
			// per-frame averages: scenes rendered, objects by type (model, world model, sprite, light, camera, particles,
			// polygrid, line system, container), object vertices
			uint[9] objects_per_frame=_object_type_counts[1..$];
			objects_per_frame[]/=_fps_frames;
			test_out.writefln("fps: %.1f scenes: %.1f objects: %s vertices: %d sky objects: %d fog: %s %s %s", _fps_frames/(elapsed.total!"usecs"/1_000_000.0),
				cast(float)_scene_count/_fps_frames, objects_per_frame, _object_vertex_count/_fps_frames, _sky_object_count,
				_fog_enable, _fog_range, _fog_colour);
			test_out.flush();
			_object_type_counts[]=0;
			_scene_count=0;
			_object_vertex_count=0;
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
		DestroyAllocImage(g_Allocator, _overlay_image);
		DestroyAllocBuffer(g_Allocator, _overlay_staging);
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

		SetViewport(buffer, _frame_viewport); // the 2D layer covers the mode's whole area

		vkCmdBindDescriptorSets(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _overlay_pipeline_layout, 0, 1, &_overlay_descriptor, 0, null);
		vkCmdDraw(buffer, 3, 1, 0, 0);
	}

	//// Objects (models now): world-space triangles built in RenderScene, drawn after the world

	ObjectGeometry _objects;
	bool[LTObject*] _objects_seen;

	// per-second statistics for the fps log line
	uint[10] _object_type_counts;
	uint _scene_count;
	size_t _object_vertex_count;

	import SceneGeometry: ObjectPipe;
	VkPipeline[ObjectPipe.max+1] _object_pipelines;
	VkShaderModule _object_vert_shader;
	VkShaderModule _object_frag_shader;

	VkBuffer _object_vertex_buffer;
	VkMappedMemoryRange _object_vertex_memory;
	size_t _object_vertex_capacity; // bytes

	// the allocator's blocks are 64 MiB and it can't allocate past one
	enum size_t MaxObjectVertexBytes=32*1024*1024;

	// d3d.ren RenderScene: DRAWMODE_OBJECTLIST draws only the given objects, DRAWMODE_NORMAL everything visible in the world
	void CollectObjects(SceneDesc* scene_desc)
	{
		import Main: g_RenderContext, _renderer, EnsureTextureBound;
		import LTObjects;
		import ModelDraw: DrawModel;
		import WorldModelDraw: DrawWorldModel;
		import Objects.BaseObject: BaseObject, Attachment, ObjectType;

		// the client may render several scenes per frame (e.g. the view weapon through an object list), so the frame's
		// geometry accumulates until SwapBuffers
		_objects_seen.clear();
		_scene_count++;

		// diagnostic switches; typing e.g. "d_ModelFlip 0" in the game console creates/sets them
		{
			import ModelDraw: g_DisableModelFlip, g_DisableVertexAnimation;

			float ConsoleFloat(const(char)* name, float default_value)
			{
				void* variable=_renderer.GetConsoleVar(name);
				return variable ? _renderer.GetVarValueFloat(variable) : default_value;
			}

			// d3d.ren negates the object matrix's third column; verified against d3d.ren (Caleb faces the camera in the
			// opening cutscene only with it)
			g_DisableModelFlip=ConsoleFloat("d_ModelFlip", 1f)==0f;
			g_DisableVertexAnimation=ConsoleFloat("d_ModelVertexAnim", 1f)==0f;
		}

		import EffectsDraw;
		import SceneGeometry: DrawGroup, ObjectPipe;
		import WorldModelDraw: DrawSkyWorldModel;

		float ConsoleFloat(const(char)* name, float default_value)
		{
			void* variable=_renderer.GetConsoleVar(name);
			return variable ? _renderer.GetVarValueFloat(variable) : default_value;
		}

		MainWorld* world=g_RenderContext ? g_RenderContext.main_world : null;
		const bool normal_mode=scene_desc.draw_mode!=DrawMode.ObjectList;

		// the fixed model light comes from above and behind the camera (port_notes/model.md, Lighting)
		const Mat4 camera=QuatToMatrix(scene_desc.camera_rotation);
		const float[3] right=[camera.m[0][0], camera.m[1][0], camera.m[2][0]];
		const float[3] up=[camera.m[0][1], camera.m[1][1], camera.m[2][1]];
		const float[3] forward=[camera.m[0][2], camera.m[1][2], camera.m[2][2]];
		const float[3] light_direction=Normalised([2f*up[0]-forward[0], 2f*up[1]-forward[1], 2f*up[2]-forward[2]]);

		RenderTexture ResolveTexture(SharedTexture* texture)
		{
			return EnsureTextureBound(texture);
		}

		// the frame's dynamic lights (d3d_CalcLightAdd's list), gathered from the world; object-list scenes reuse them
		if (normal_mode && world && world.world_bsp)
		{
			_scene_lights.length=0;
			_scene_lights.assumeSafeAppend();
			ForEachWorldObject(world.world_bsp, (LTObject* object) {
				if (object.type==ObjectType.Light && (object.flags & ObjectFlag.Visible) && !(object.flags & ObjectFlag.SkyObject))
					_scene_lights~=DynamicLight(object.pos, [cast(float)object.r, cast(float)object.g, cast(float)object.b], At!float(object, LightRadiusOffset));
			});
		}

		import std.math: tan;
		EffectView view={
			camera: scene_desc.camera_position.vector,
			right: right, up: up, forward: forward,
			offset: [0f, 0f, 0f],
			tan_half_fov_x: tan(fov_x*0.5f), tan_half_fov_y: tan(fov_y*0.5f),
			near_z: 0.1f, far_z: scene_desc.far_clipping_plane>0f ? scene_desc.far_clipping_plane : 15000f,
			sky: false,
			world: world,
			lights: _scene_lights,
			light_scale: scene_desc.global_light_scale.vector,
			resolve_texture: &ResolveTexture
		};

		const bool draw_sprites=ConsoleFloat("DrawSprites", 1f)!=0f;
		const bool draw_particles=ConsoleFloat("DrawParticles", 1f)!=0f;
		const bool draw_polygrids=ConsoleFloat("DrawPolyGrids", 1f)!=0f;
		const bool draw_line_systems=ConsoleFloat("DrawLineSystems", 1f)!=0f;

		void Process(LTObject* object)
		{
			if (object is null || !(object.flags & ObjectFlag.Visible) || (object in _objects_seen))
				return;
			_objects_seen[object]=true;

			if (cast(uint)object.type<_object_type_counts.length)
				_object_type_counts[object.type]++;

			switch(object.type)
			{
				case ObjectType.Model:
					_objects.Route(DrawGroup.SolidModels, ObjectPipe.Opaque, DrawGroup.TranslucentModels, ObjectPipe.Blend);
					DrawModel(_objects, object, scene_desc, world, light_direction, _scene_lights, &ResolveTexture);
					break;
				case ObjectType.WorldModel:
				case ObjectType.Container: // d3d.ren handles both with d3d_ProcessWorldModel
					_objects.Route(DrawGroup.SolidWorldModels, ObjectPipe.Opaque, DrawGroup.TranslucentWorldModels, ObjectPipe.Blend);
					DrawWorldModel(_objects, object, scene_desc, _scene_lights, &ResolveTexture);
					break;
				case ObjectType.Sprite:
					if (draw_sprites)
						DrawSprite(_objects, object, view);
					break;
				case ObjectType.ParticleSystem:
					if (draw_particles)
						DrawParticleSystem(_objects, object, view);
					break;
				case ObjectType.Polygrid:
					if (draw_polygrids)
						DrawPolyGrid(_objects, object, view);
					break;
				case ObjectType.LineSystem:
					if (draw_line_systems)
						DrawLineSystem(_objects, object, view);
					break;
				default:
					break; // lights, cameras, normal objects
			}
		}

		void ProcessWithAttachments(LTObject* object)
		{
			if (object is null || !(object.flags & ObjectFlag.Visible))
				return;

			Process(object);

			// attached objects (weapons in hands etc.) are processed with their parent, one level deep like d3d.ren
			for (void* attachment=object.attachments; attachment !is null; attachment=At!(void*)(attachment, AttachmentNextOffset))
				Process(cast(LTObject*)_renderer.GetAttachmentObject(cast(BaseObject*)object, cast(Attachment*)attachment));
		}

		if (!normal_mode)
		{
			if (scene_desc.obj_list_head)
				foreach(object; (cast(LTObject**)scene_desc.obj_list_head)[0..scene_desc.obj_count])
					Process(object);
		}
		else if (world && world.world_bsp)
		{
			// the world tree's objects, without sky objects and polygrids (world_visibility.cpp r_CollectVisibleObjects)
			ForEachWorldObject(world.world_bsp, (LTObject* object) {
				if (object.type!=ObjectType.Polygrid && !(object.flags & ObjectFlag.SkyObject))
					ProcessWithAttachments(object);
			});

			// polygrids come from the leaves' object lists (r_VLTagPolies); without visibility, every leaf's
			ForEachLeafObject(world.world_bsp, (LTObject* object) {
				if (object.type==ObjectType.Polygrid && !(object.flags & ObjectFlag.SkyObject))
					ProcessWithAttachments(object);
			});

			CollectSky(scene_desc, view, &ResolveTexture, ConsoleFloat("DrawSky", 1f)!=0f);

			if (ConsoleFloat("LightAddPoly", 1f)!=0f)
				CollectLightAdd(scene_desc, view);
		}
	}

	// d3d_draw.cpp r_DrawLightAddPoly: the camera's light add (screen flashes) as an untextured quad over the whole view,
	// ONE / ONE, no depth, no fog, last in the frame; only when a channel reaches 0.001
	void CollectLightAdd(SceneDesc* scene_desc, const ref EffectView view)
	{
		import SceneGeometry: ObjectVertex, DrawGroup, ObjectPipe, TextureMode;

		const float[3] add=scene_desc.global_light_add;
		if (add[0]<0.001f && add[1]<0.001f && add[2]<0.001f)
			return;

		float[4] colour;
		foreach(channel; 0..3)
		{
			// truncated to a byte like the original
			const float c=add[channel]<0f ? 0f : add[channel]>1f ? 1f : add[channel];
			colour[channel]=cast(int)(c*255f)/255f;
		}
		colour[3]=1f;

		// a camera-facing quad one unit ahead, a little larger than the view
		const float half_x=view.tan_half_fov_x*1.1f, half_y=view.tan_half_fov_y*1.1f;
		float[3] Corner(float x, float y)
		{
			float[3] p;
			foreach(axis; 0..3)
				p[axis]=view.camera[axis]+view.forward[axis]+view.right[axis]*x+view.up[axis]*y;
			return p;
		}

		ObjectVertex[4] corners=[
			ObjectVertex(Corner(-half_x, half_y), colour, [0f, 0f]),
			ObjectVertex(Corner(half_x, half_y), colour, [0f, 0f]),
			ObjectVertex(Corner(half_x, -half_y), colour, [0f, 0f]),
			ObjectVertex(Corner(-half_x, -half_y), colour, [0f, 0f])
		];
		_objects.Begin(VkDescriptorSet.init, DrawGroup.LightAdd, ObjectPipe.Additive, TextureMode.Untextured);
		static immutable size_t[6] order=[0, 1, 2, 0, 2, 3];
		foreach(i; order)
			_objects.Add(corners[i]);
		_objects.End();
	}

	DynamicLight[] _scene_lights;
	int _sky_object_count; // of the last normal scene, for the log

	// d3d.ren r_DrawSky / sky-object pass (port_notes/sky.md): the sky objects seen from a sky camera that moves through
	// the sky box (SkyDef ViewMin..ViewMax) in proportion to the camera's position in the level, with the main camera's
	// rotation and FOV. Drawn first, without depth, so the world covers it everywhere but the sky portals.
	void CollectSky(SceneDesc* scene_desc, EffectView main_view, RenderTexture delegate(SharedTexture*) resolve,
		bool draw_sky)
	{
		import LTObjects;
		import EffectsDraw;
		import SceneGeometry: DrawGroup, ObjectPipe;
		import WorldModelDraw: DrawSkyWorldModel;
		import Main: g_RenderContext;
		import Objects.BaseObject: ObjectType;

		_sky_object_count=scene_desc.sky_objects ? scene_desc.sky_object_count : 0;
		if (!draw_sky || scene_desc.sky_objects is null || scene_desc.sky_object_count<=0)
			return;

		WorldBsp* bsp=(g_RenderContext && g_RenderContext.main_world) ? g_RenderContext.main_world.world_bsp : null;

		// r_SetupSkyStuff: the fraction of the camera's way through the world's box, per axis
		float[3] fraction=[0.5f, 0.5f, 0.5f];
		if (bsp && scene_desc.draw_mode==DrawMode.Normal)
			foreach(axis; 0..3)
			{
				const float extent=bsp.extents_max.vector[axis]-bsp.extents_min.vector[axis];
				if (extent!=0f)
					fraction[axis]=(main_view.camera[axis]-bsp.extents_min.vector[axis])/extent;
			}

		const float[3] view_min=scene_desc.sky_def[2], view_max=scene_desc.sky_def[3];
		float[3] sky_camera;
		foreach(axis; 0..3)
			sky_camera[axis]=view_min[axis]+(view_max[axis]-view_min[axis])*fraction[axis];

		EffectView view=main_view;
		view.sky=true;
		view.camera=sky_camera;
		view.offset=[main_view.camera[0]-sky_camera[0], main_view.camera[1]-sky_camera[1], main_view.camera[2]-sky_camera[2]];

		// in SceneDesc order, painter's algorithm; only sprites, polygrids and world models
		foreach(object; (cast(LTObject**)scene_desc.sky_objects)[0..scene_desc.sky_object_count])
		{
			if (object is null || !(object.flags & ObjectFlag.Visible))
				continue;

			switch(object.type)
			{
				case ObjectType.Sprite:
					DrawSprite(_objects, object, view);
					break;
				case ObjectType.Polygrid:
					DrawPolyGrid(_objects, object, view);
					break;
				case ObjectType.WorldModel:
					_objects.Route(DrawGroup.Sky, ObjectPipe.OpaqueNoZ, DrawGroup.Sky, ObjectPipe.BlendNoZ);
					DrawSkyWorldModel(_objects, object, scene_desc, sky_camera, view.offset, resolve);
					break;
				default:
					break; // models, particles, line systems are ignored in the sky
			}
		}
	}

	void CreateObjectPipelines()
	{
		_object_vert_shader=Shader.CreateShaderModule(g_Device, Shader.ReadShader("object_vert.spv"));
		_object_frag_shader=Shader.CreateShaderModule(g_Device, Shader.ReadShader("object_frag.spv"));

		foreach(pipe; 0..ObjectPipe.max+1)
			_object_pipelines[pipe]=CreateObjectPipeline(cast(ObjectPipe)pipe);
	}

	VkPipeline CreateObjectPipeline(ObjectPipe pipe)
	{
		import SceneGeometry: ObjectVertex;

		const bool additive=pipe==ObjectPipe.Additive;
		const bool blend=pipe==ObjectPipe.Blend || pipe==ObjectPipe.BlendNoZ || pipe==ObjectPipe.Lines || additive;
		const bool depth_test=pipe==ObjectPipe.Opaque || pipe==ObjectPipe.Blend || pipe==ObjectPipe.Lines;
		const bool depth_write=pipe==ObjectPipe.Opaque;

		VkPipelineShaderStageCreateInfo[] shader_stages=[
			{ stage: VK_SHADER_STAGE_VERTEX_BIT, module_: _object_vert_shader, pName: "main" },
			{ stage: VK_SHADER_STAGE_FRAGMENT_BIT, module_: _object_frag_shader, pName: "main" }
		];

		auto binding_description=ObjectVertex.GetBindingDescription();
		auto attribute_descriptions=ObjectVertex.GetAttributeDescriptions();
		VkPipelineVertexInputStateCreateInfo vertex_input_info={
			vertexBindingDescriptionCount: 1,
			pVertexBindingDescriptions: &binding_description,
			vertexAttributeDescriptionCount: attribute_descriptions.length,
			pVertexAttributeDescriptions: attribute_descriptions.ptr
		};

		VkPipelineInputAssemblyStateCreateInfo input_assembly_info={
			topology: pipe==ObjectPipe.Lines ? VK_PRIMITIVE_TOPOLOGY_LINE_LIST : VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
		};

		VkPipelineViewportStateCreateInfo viewport_state_info={
			viewportCount: 1,
			scissorCount: 1
		};

		// d3d.ren culls model faces in software by screen winding; the handedness flip makes that easy to get backwards,
		// so leave culling off until it's verified
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
			depthTestEnable: depth_test ? VK_TRUE : VK_FALSE,
			depthWriteEnable: depth_write ? VK_TRUE : VK_FALSE,
			depthCompareOp: VK_COMPARE_OP_LESS_OR_EQUAL // D3D's default ZFUNC; a polygrid's env pass redraws at equal depth
		};

		VkPipelineColorBlendAttachmentState colour_blend_attachment={
			blendEnable: blend ? VK_TRUE : VK_FALSE,
			srcColorBlendFactor: additive ? VK_BLEND_FACTOR_ONE : VK_BLEND_FACTOR_SRC_ALPHA,
			dstColorBlendFactor: additive ? VK_BLEND_FACTOR_ONE : VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
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

		// same descriptor layout as the world: set 0 = UBO + sampler, set 1 = texture
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
			layout: _pipeline_layout,
			renderPass: _render_pass,
			basePipelineIndex: -1
		};

		VkPipeline pipeline;
		VkCheck(vkCreateGraphicsPipelines(g_Device, VK_NULL_ND_HANDLE, 1, &pipeline_info, null, &pipeline),
			"vkCreateGraphicsPipelines (objects)");
		return pipeline;
	}

	void DestroyObjectRendering()
	{
		foreach(pipeline; _object_pipelines)
			vkDestroyPipeline(g_Device, pipeline, null);
		vkDestroyShaderModule(g_Device, _object_vert_shader, null);
		vkDestroyShaderModule(g_Device, _object_frag_shader, null);
		DestroyAllocBuffer(g_Allocator, _object_vertex_buffer);
	}

	// called between frames (the GPU is idle), so the buffer can be replaced and rewritten
	void UploadObjects()
	{
		import SceneGeometry: ObjectVertex;
		import core.stdc.string: memcpy;

		size_t bytes=_objects.vertices.length*ObjectVertex.sizeof;
		if (bytes==0)
			return;

		if (bytes>MaxObjectVertexBytes)
		{
			debug test_out.writeln("Object geometry too large: ", bytes, " bytes, dropping this frame's objects");
			_objects.Clear();
			return;
		}

		if (bytes>_object_vertex_capacity)
		{
			DestroyAllocBuffer(g_Allocator, _object_vertex_buffer);

			size_t capacity=1024*1024;
			while (capacity<bytes)
				capacity*=2;
			if (capacity>MaxObjectVertexBytes)
				capacity=MaxObjectVertexBytes;

			CreateVkBuffer(capacity, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, _object_vertex_buffer, _object_vertex_memory);
			_object_vertex_capacity=capacity;
		}

		void* data;
		if (vmaMapMemory(_object_vertex_memory, &data)!=VK_SUCCESS)
		{
			_objects.Clear();
			return;
		}
		memcpy(data, _objects.vertices.ptr, bytes);
		vmaUnmapMemory(_object_vertex_memory);
	}

	// recorded inside the render pass: the sky group before the world (sky = true), every other group after it
	void RecordObjectDraws(VkCommandBuffer buffer, uint image_index, bool sky)
	{
		import SceneGeometry: ObjectBatch, DrawGroup, TextureMode;

		if (_objects.vertices.length==0 || _object_vertex_buffer==VK_NULL_ND_HANDLE)
			return;

		VkDeviceSize offset=0;
		vkCmdBindVertexBuffers(buffer, 0, 1, &_object_vertex_buffer, &offset);
		SetViewport(buffer, _scene_viewport);

		ObjectPipe bound_pipe=ObjectPipe.max;
		bool pipe_bound=false;
		VkDescriptorSet bound_texture=VK_NULL_ND_HANDLE;

		const size_t first_group=sky ? DrawGroup.Sky : DrawGroup.SolidModels;
		const size_t end_group=sky ? DrawGroup.Sky+1 : DrawGroup.max+1;
		foreach(group; first_group..end_group)
		{
			foreach(ref batch; _objects.groups[group])
			{
				if (!pipe_bound || batch.pipe!=bound_pipe)
				{
					vkCmdBindPipeline(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _object_pipelines[batch.pipe]);
					if (!pipe_bound)
						vkCmdBindDescriptorSets(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _pipeline_layout, 0, 1, &_descriptor_sets[image_index], 0, null);
					bound_pipe=batch.pipe;
					pipe_bound=true;
				}

				VkDescriptorSet texture=batch.texture!=VK_NULL_ND_HANDLE ? batch.texture : _texture_descriptor;
				if (texture!=bound_texture)
				{
					vkCmdBindDescriptorSets(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _pipeline_layout, 1, 1, &texture, 0, null);
					bound_texture=texture;
				}
				// lines and the light-add poly are never fogged; the sky uses the sky fog range
				const FogKind fog=group==DrawGroup.Sky ? FogKind.Sky :
					(group==DrawGroup.LineSystems || group==DrawGroup.LightAdd) ? FogKind.None : FogKind.World;
				PushBatchConstants(buffer, cast(float)batch.mode, fog);
				vkCmdDraw(buffer, batch.vertex_count, 1, batch.first_vertex, 0);
			}
		}
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

		// viewport and scissor follow the scene's view rect and survive swapchain resizes
		VkDynamicState[] dynamic_states=[ VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR, VK_DYNAMIC_STATE_LINE_WIDTH ];

		VkPipelineDynamicStateCreateInfo dynamic_state_info={
			dynamicStateCount: dynamic_states.length,
			pDynamicStates: dynamic_states.ptr
		};

		CreateDescriptorSetLayout();
		CreateTextureDescriptorLayout();

		VkDescriptorSetLayout[] pipeline_descriptor_layouts=[_descriptor_set_layout, _texture_descriptor_layout];
		// per texture batch: GlobalLightScale and texture mode, fog colour, fog range (shader.frag / object.frag)
		VkPushConstantRange push_constant_range={
			stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
			offset: 0,
			size: float.sizeof*12
		};
		VkPipelineLayoutCreateInfo pipeline_layout_info={
			setLayoutCount: pipeline_descriptor_layouts.length,
			pSetLayouts: pipeline_descriptor_layouts.ptr,
			pushConstantRangeCount: 1,
			pPushConstantRanges: &push_constant_range
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
			pDynamicState: &dynamic_state_info, // was missing: the viewport stayed fixed at creation size
			layout: _pipeline_layout,
			renderPass: _render_pass,
			basePipelineHandle: VK_NULL_ND_HANDLE,
			basePipelineIndex: -1
		};

		vkCreateGraphicsPipelines(g_Device, VK_NULL_ND_HANDLE, 1, &graphics_pipe_info, null, &_pipeline);
		test_out.writeln("Graphics Pipeline created.");

		// the same with colour writes off and both faces, for the sky portals
		colour_blend_attachment.colorWriteMask=0;
		rasterizer_info.cullMode=VK_CULL_MODE_NONE;
		VkCheck(vkCreateGraphicsPipelines(g_Device, VK_NULL_ND_HANDLE, 1, &graphics_pipe_info, null, &_pipeline_depth_only),
			"vkCreateGraphicsPipelines (sky portals)");
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

		DestroyAllocBuffer(g_Allocator, staging_buffer);
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
								ubo.lights[ubo.count++]=LightObj(obj.position, vec3(obj.colour[0]/255f, obj.colour[1]/255f, obj.colour[2]/255f), obj.ToLight().radius);
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

		// both angles come from the engine, so the projection matches its view rect whatever the window's aspect
		{
			import std.math: tan;

			enum float near=0.1f, far=15000f;
			const float x_max=near*tan(fov_x*0.5f), y_max=near*tan(fov_y*0.5f);
			ubo.proj=mat4.perspective(-x_max, x_max, -y_max, y_max, near, far).transposed(); // the frustum overload
		}

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

		VkDescriptorSetLayoutBinding lightmap_layout_binding={
			binding: 3,
			descriptorType: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
			descriptorCount: 1,
			stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT
		};

		VkDescriptorSetLayoutBinding[] bindings=[ ubo_layout_binding, sampler_layout_binding, lights_ubo_layout_binding, lightmap_layout_binding ];

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
		},
		{
			type: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, // lightmap atlas
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

		BindLightmapAtlas(); // the white dummy until a world is loaded
	}

	//// Lightmap atlas: every lightmapped world poly's block (WorldPoly +0x34: w, h, RGB565 texels) packed into one texture

	enum uint LightmapAtlasWidth=2048;
	enum uint LightmapPadding=1; // replicated border so bilinear filtering never reads a neighbouring block

	VkImage _lightmap_image;
	VkMappedMemoryRange _lightmap_image_memory;
	VkImageView _lightmap_image_view;
	VkImage _lightmap_dummy_image;
	VkMappedMemoryRange _lightmap_dummy_memory;
	VkImageView _lightmap_dummy_view;

	// uploads RGBA8 pixels into a new sampled image
	void CreateLightmapImage(uint width, uint height, const(uint)[] pixels, out VkImage image, out VkMappedMemoryRange memory, out VkImageView view)
	{
		import core.stdc.string: memcpy;

		VkBuffer staging;
		VkMappedMemoryRange staging_memory;
		CreateVkBuffer(pixels.length*uint.sizeof, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, staging, staging_memory);
		void* data;
		vmaMapMemory(staging_memory, &data);
		memcpy(data, pixels.ptr, pixels.length*uint.sizeof);
		vmaUnmapMemory(staging_memory);

		CreateVkImage(width, height, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TILING_OPTIMAL, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, image, memory);
		TransitionImageLayout(image, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
		CopyBufferToImage(staging, image, width, height);
		TransitionImageLayout(image, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
		DestroyAllocBuffer(g_Allocator, staging);

		view=CreateImageView(image, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT);
	}

	// points binding 3 of every frame's set 0 at the atlas (or the white dummy); only called between frames
	void BindLightmapAtlas()
	{
		if (_lightmap_dummy_view==VK_NULL_ND_HANDLE)
		{
			const uint[1] white=[ 0xFFFFFFFF ];
			CreateLightmapImage(1, 1, white[], _lightmap_dummy_image, _lightmap_dummy_memory, _lightmap_dummy_view);
		}

		VkDescriptorImageInfo image_info={
			imageView: _lightmap_image_view!=VK_NULL_ND_HANDLE ? _lightmap_image_view : _lightmap_dummy_view,
			imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
		};
		foreach(set; _descriptor_sets)
		{
			VkWriteDescriptorSet write={
				dstSet: set,
				dstBinding: 3,
				descriptorCount: 1,
				descriptorType: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
				pImageInfo: &image_info
			};
			vkUpdateDescriptorSets(g_Device, 1, &write, 0, null);
		}
	}

	void DestroyLightmapAtlas()
	{
		{
			// the polygons belong to the level being unloaded
			import WorldModelDraw: g_LightmapOrigins;
			g_LightmapOrigins=null;
		}

		if (_lightmap_image_view==VK_NULL_ND_HANDLE)
			return;

		vkDeviceWaitIdle(g_Device);
		VkImageView view=_lightmap_image_view;
		_lightmap_image_view=VK_NULL_ND_HANDLE;
		BindLightmapAtlas();
		vkDestroyImageView(g_Device, view, null);
		DestroyAllocImage(g_Allocator, _lightmap_image);
		_lightmap_image=VK_NULL_ND_HANDLE;
	}

	// packs the blocks with a shelf packer; returns each poly's block origin in the atlas (texels, inside the padding)
	uint[2][Polygon*] BuildLightmapAtlas(Polygon*[] polygons)
	{
		import std.algorithm: max, sort;

		DestroyLightmapAtlas();

		struct Block { Polygon* poly; uint w, h; }
		Block[] blocks;
		foreach(polygon; polygons)
		{
			if (polygon is null || polygon.surface is null || !(polygon.surface.flags & SurfaceFlags.LightMap) || polygon.lightmap_data is null)
				continue;
			const uint w=polygon.lightmap_data[0], h=polygon.lightmap_data[1];
			if (w && h)
				blocks~=Block(polygon, w, h);
		}

		uint[2][Polygon*] origins;
		if (blocks.length==0)
			return origins;

		// tallest first keeps the shelves tight
		blocks.sort!((a, b) => a.h>b.h);

		uint x=0, y=0, shelf_height=0;
		uint[2][] positions=new uint[2][blocks.length];
		foreach(i, ref block; blocks)
		{
			const uint w=block.w+LightmapPadding*2, h=block.h+LightmapPadding*2;
			if (x+w>LightmapAtlasWidth)
			{
				y+=shelf_height;
				x=0;
				shelf_height=0;
			}
			positions[i]=[x, y];
			x+=w;
			shelf_height=max(shelf_height, h);
		}
		const uint atlas_height=y+shelf_height;
		if (atlas_height>8192)
		{
			test_out.writeln("Lightmap atlas would be ", atlas_height, " texels high, lightmaps disabled");
			return origins;
		}

		uint[] pixels=new uint[LightmapAtlasWidth*atlas_height];

		// RGB565 expanded by a shift, no bit replication (d3d.ren dynamic lightmap builder)
		static uint Expand565(ushort p)
		{
			const uint r=((p >> 11) & 0x1F) << 3, g=((p >> 5) & 0x3F) << 2, b=(p & 0x1F) << 3;
			return r | (g << 8) | (b << 16) | 0xFF000000;
		}

		foreach(i, ref block; blocks)
		{
			const ushort* texels=cast(ushort*)(block.poly.lightmap_data+2);
			const uint origin_x=positions[i][0]+LightmapPadding, origin_y=positions[i][1]+LightmapPadding;
			// the padded rectangle samples the clamped block texel
			foreach(py; 0..block.h+LightmapPadding*2)
				foreach(px; 0..block.w+LightmapPadding*2)
				{
					const int sx=cast(int)px-cast(int)LightmapPadding, sy=cast(int)py-cast(int)LightmapPadding;
					const uint cx=sx<0 ? 0 : (sx>=cast(int)block.w ? block.w-1 : sx);
					const uint cy=sy<0 ? 0 : (sy>=cast(int)block.h ? block.h-1 : sy);
					pixels[(positions[i][1]+py)*LightmapAtlasWidth+positions[i][0]+px]=Expand565(texels[cy*block.w+cx]);
				}
			origins[block.poly]=[origin_x, origin_y];
		}

		CreateLightmapImage(LightmapAtlasWidth, atlas_height, pixels, _lightmap_image, _lightmap_image_memory, _lightmap_image_view);
		_lightmap_atlas_height=atlas_height;
		BindLightmapAtlas();

		{
			import WorldModelDraw: g_LightmapOrigins, g_LightmapAtlasScale;
			g_LightmapOrigins=origins;
			g_LightmapAtlasScale=[1f/LightmapAtlasWidth, 1f/atlas_height];
		}

		test_out.writeln("Lightmap atlas: ", blocks.length, " blocks, ", LightmapAtlasWidth, "x", atlas_height);
		return origins;
	}

	uint _lightmap_atlas_height=1;

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

			DestroyAllocBuffer(g_Allocator, staging_buffer);
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

			DestroyAllocBuffer(g_Allocator, staging_buffer);
		}
	}

	// the GPU is idle between frames (SwapBuffers waits), so this is safe whenever the engine calls it
	public void DestroyTextureImage(VkImage image, VkImageView image_view, VkDescriptorSet descriptor)
	{
		if (descriptor!=VK_NULL_ND_HANDLE)
			vkFreeDescriptorSets(g_Device, _texture_descriptor_pool, 1, &descriptor);
		vkDestroyImageView(g_Device, image_view, null);
		DestroyAllocImage(g_Allocator, image);
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

		DestroyAllocBuffer(g_Allocator, _vertex_buffer);
		DestroyAllocBuffer(g_Allocator, _vertex_index_buffer);
		_vertex_buffer=VK_NULL_ND_HANDLE;
		_vertex_index_buffer=VK_NULL_ND_HANDLE;
		index_count=0;

		DestroyLightmapAtlas();
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

		// d3d.ren pages in the main world's lightmaps, then every world model's original BSP (solid world models are
		// lightmapped like the world)
		Polygon*[] lightmapped_polygons=polygons.dup;
		{
			import Main: g_RenderContext;
			import WorldBsp: WorldData;

			MainWorld* world=g_RenderContext ? g_RenderContext.main_world : null;
			if (world && world.world_models)
				foreach(data; world.world_models[0..world.world_model_count])
				{
					WorldBsp* original=data ? (data.objs[1] ? data.objs[1] : data.objs[0]) : null;
					if (original && original!=bsp && original.polygons)
						lightmapped_polygons~=original.polygons[0..original.polygon_count];
				}
		}

		// block-local lightmap UVs first: this also clears the lightmap flag of polies without lightmap data, like d3d.ren
		foreach(polygon; lightmapped_polygons)
		{
			import WorldBsp: GenerateLightmapUvs;
			if (polygon && polygon.surface)
				GenerateLightmapUvs(*polygon);
		}

		uint[2][Polygon*] lightmap_origins=BuildLightmapAtlas(lightmapped_polygons);

		foreach(i, polygon; polygons)
		{
			vert_count=vert_buffer.length;

			if (polygon.surface.flags & SurfaceFlags.Invisible)
				continue;

			const uint[2]* lightmap_origin=polygon in lightmap_origins;

			foreach(j, vertex; polygon.DiskVerts())
			{
				Vertex new_vert;
				with(new_vert)
				{
					pos=(*vertex.vertex_data).xyz;
					// pre-lit vertex colours are stored b, g, r, a (port ABI 2.6, SPolyVertex +0x14)
					colour.r=vertex.colour[2]/255f;
					colour.g=vertex.colour[1]/255f;
					colour.b=vertex.colour[0]/255f;
					uv=vertex.uv;

					if (lightmap_origin)
					{
						lightmap_uv.x=(vertex.lightmap_uv.x+(*lightmap_origin)[0])/LightmapAtlasWidth;
						lightmap_uv.y=(vertex.lightmap_uv.y+(*lightmap_origin)[1])/_lightmap_atlas_height;
						lightmapped=1f;
					}
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