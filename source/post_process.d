module PostProcess;

/+
 + Post-processing: with any post effect on, the 3D scene renders into an offscreen colour image (scene_pass, compatible
 + with the main render pass, so every scene pipeline works in it). A second pass (present_pass) then draws post.frag
 + over the whole swapchain image, sampling that image, and the 2D layer goes on top, so the HUD and menus are never
 + post-processed. With every effect off the renderer keeps drawing straight into the swapchain as before.
 +/

import erupted;
import Memory: g_Allocator, CreateAllocImage, DestroyAllocImage;
import VulkanRender: g_Device, test_out, VkCheck, Shader;

// post.frag's effects; the values are the console's d_AntiAliasing
enum AntiAliasing { Off, Fxaa }

struct PostProcess
{
	VkRenderPass scene_pass; // the main pass' attachments, colour left readable by the fragment shader
	VkRenderPass present_pass; // the swapchain image only: post.frag, then the 2D layer

	VkImage scene_image;
	VkMappedMemoryRange scene_memory;
	VkImageView scene_view;
	VkFramebuffer scene_framebuffer;
	VkFramebuffer[] present_framebuffers; // per swapchain image
	VkExtent2D extent;

	VkSampler sampler;
	VkDescriptorSetLayout set_layout;
	VkDescriptorPool pool;
	VkDescriptorSet set;
	VkPipelineLayout layout;
	VkPipeline pipeline;
	VkShaderModule vert_shader, frag_shader;
	VkFormat colour_format;

	void Create(VkFormat colour_format_, VkFormat depth_format)
	{
		colour_format=colour_format_;
		CreateRenderPasses(depth_format);

		VkSamplerCreateInfo sampler_info={
			magFilter: VK_FILTER_LINEAR,
			minFilter: VK_FILTER_LINEAR,
			mipmapMode: VK_SAMPLER_MIPMAP_MODE_NEAREST,
			addressModeU: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
			addressModeV: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
			addressModeW: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
			maxLod: 0f
		};
		VkCheck(vkCreateSampler(g_Device, &sampler_info, null, &sampler), "vkCreateSampler (post)");

		VkDescriptorSetLayoutBinding binding={
			binding: 0,
			descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
			descriptorCount: 1,
			stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT
		};
		VkDescriptorSetLayoutCreateInfo layout_info={ bindingCount: 1, pBindings: &binding };
		VkCheck(vkCreateDescriptorSetLayout(g_Device, &layout_info, null, &set_layout), "vkCreateDescriptorSetLayout (post)");

		VkDescriptorPoolSize pool_size={ type: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, descriptorCount: 1 };
		VkDescriptorPoolCreateInfo pool_info={ poolSizeCount: 1, pPoolSizes: &pool_size, maxSets: 1 };
		VkCheck(vkCreateDescriptorPool(g_Device, &pool_info, null, &pool), "vkCreateDescriptorPool (post)");

		VkDescriptorSetAllocateInfo alloc_info={ descriptorPool: pool, descriptorSetCount: 1, pSetLayouts: &set_layout };
		VkCheck(vkAllocateDescriptorSets(g_Device, &alloc_info, &set), "vkAllocateDescriptorSets (post)");

		// push constants: 1 / width, 1 / height, the anti-aliasing mode, where the effects start (x)
		VkPushConstantRange push_range={ stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT, offset: 0, size: float.sizeof*4 };
		VkPipelineLayoutCreateInfo pipeline_layout_info={
			setLayoutCount: 1,
			pSetLayouts: &set_layout,
			pushConstantRangeCount: 1,
			pPushConstantRanges: &push_range
		};
		VkCheck(vkCreatePipelineLayout(g_Device, &pipeline_layout_info, null, &layout), "vkCreatePipelineLayout (post)");

		vert_shader=Shader.CreateShaderModule(g_Device, Shader.ReadShader("overlay_vert.spv")); // fullscreen triangle
		frag_shader=Shader.CreateShaderModule(g_Device, Shader.ReadShader("post_frag.spv"));
		CreatePipeline();
	}

	void Destroy()
	{
		DestroyTargets();
		vkDestroyPipeline(g_Device, pipeline, null);
		vkDestroyPipelineLayout(g_Device, layout, null);
		vkDestroyShaderModule(g_Device, vert_shader, null);
		vkDestroyShaderModule(g_Device, frag_shader, null);
		vkDestroyDescriptorPool(g_Device, pool, null);
		vkDestroyDescriptorSetLayout(g_Device, set_layout, null);
		vkDestroySampler(g_Device, sampler, null);
		vkDestroyRenderPass(g_Device, scene_pass, null);
		vkDestroyRenderPass(g_Device, present_pass, null);
	}

	// the size-dependent parts, made again when the swapchain is
	void CreateTargets(VkExtent2D extent_, VkImageView depth_view, const VkImageView[] swapchain_views)
	{
		extent=extent_;

		VkImageCreateInfo image_info={
			imageType: VK_IMAGE_TYPE_2D,
			extent: { width: extent.width, height: extent.height, depth: 1 },
			mipLevels: 1,
			arrayLayers: 1,
			format: colour_format,
			tiling: VK_IMAGE_TILING_OPTIMAL,
			initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
			usage: VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
			samples: VK_SAMPLE_COUNT_1_BIT,
			sharingMode: VK_SHARING_MODE_EXCLUSIVE
		};
		CreateAllocImage(g_Allocator, image_info, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, scene_image, &scene_memory, null);

		VkImageViewCreateInfo view_info={
			image: scene_image,
			viewType: VK_IMAGE_VIEW_TYPE_2D,
			format: colour_format,
			subresourceRange: { aspectMask: VK_IMAGE_ASPECT_COLOR_BIT, levelCount: 1, layerCount: 1 }
		};
		VkCheck(vkCreateImageView(g_Device, &view_info, null, &scene_view), "vkCreateImageView (post scene)");

		VkImageView[2] scene_attachments=[scene_view, depth_view];
		VkFramebufferCreateInfo scene_info={
			renderPass: scene_pass,
			attachmentCount: scene_attachments.length,
			pAttachments: scene_attachments.ptr,
			width: extent.width,
			height: extent.height,
			layers: 1
		};
		VkCheck(vkCreateFramebuffer(g_Device, &scene_info, null, &scene_framebuffer), "vkCreateFramebuffer (post scene)");

		present_framebuffers.length=swapchain_views.length;
		foreach(i, view; swapchain_views)
		{
			VkFramebufferCreateInfo present_info={
				renderPass: present_pass,
				attachmentCount: 1,
				pAttachments: &view,
				width: extent.width,
				height: extent.height,
				layers: 1
			};
			VkCheck(vkCreateFramebuffer(g_Device, &present_info, null, &present_framebuffers[i]), "vkCreateFramebuffer (post present)");
		}

		VkDescriptorImageInfo image_descriptor={
			sampler: sampler,
			imageView: scene_view,
			imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
		};
		VkWriteDescriptorSet write={
			dstSet: set,
			dstBinding: 0,
			descriptorCount: 1,
			descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
			pImageInfo: &image_descriptor
		};
		vkUpdateDescriptorSets(g_Device, 1, &write, 0, null);
	}

	void DestroyTargets()
	{
		foreach(framebuffer; present_framebuffers)
			vkDestroyFramebuffer(g_Device, framebuffer, null);
		present_framebuffers.length=0;
		if (scene_framebuffer!=VK_NULL_ND_HANDLE)
			vkDestroyFramebuffer(g_Device, scene_framebuffer, null);
		if (scene_view!=VK_NULL_ND_HANDLE)
			vkDestroyImageView(g_Device, scene_view, null);
		if (scene_image!=VK_NULL_ND_HANDLE)
			DestroyAllocImage(g_Allocator, scene_image);
		scene_framebuffer=VK_NULL_ND_HANDLE;
		scene_view=VK_NULL_ND_HANDLE;
		scene_image=VK_NULL_ND_HANDLE;
	}

	// inside present_pass: post.frag over the whole swapchain image
	void Record(VkCommandBuffer buffer, AntiAliasing anti_aliasing, float from_x)
	{
		vkCmdBindPipeline(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
		VkViewport viewport=VkViewport(0f, 0f, extent.width, extent.height, 0f, 1f);
		vkCmdSetViewport(buffer, 0, 1, &viewport);
		VkRect2D scissor=VkRect2D(VkOffset2D(0, 0), extent);
		vkCmdSetScissor(buffer, 0, 1, &scissor);
		vkCmdBindDescriptorSets(buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &set, 0, null);
		const float[4] constants=[1f/extent.width, 1f/extent.height, cast(float)anti_aliasing, from_x];
		vkCmdPushConstants(buffer, layout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, constants.sizeof, constants.ptr);
		vkCmdDraw(buffer, 3, 1, 0, 0);
	}

private:
	void CreateRenderPasses(VkFormat depth_format)
	{
		scene_pass=MakeScenePass(colour_format, depth_format, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, false);
		present_pass=MakeColourPass(colour_format, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
	}

	void CreatePipeline()
	{
		VkPipelineShaderStageCreateInfo[2] stages=[
			{ stage: VK_SHADER_STAGE_VERTEX_BIT, module_: vert_shader, pName: "main" },
			{ stage: VK_SHADER_STAGE_FRAGMENT_BIT, module_: frag_shader, pName: "main" }
		];
		VkPipelineVertexInputStateCreateInfo vertex_input_info;
		VkPipelineInputAssemblyStateCreateInfo input_assembly_info={ topology: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
		VkPipelineViewportStateCreateInfo viewport_state_info={ viewportCount: 1, scissorCount: 1 };
		VkPipelineRasterizationStateCreateInfo rasterizer_info={
			polygonMode: VK_POLYGON_MODE_FILL,
			cullMode: VK_CULL_MODE_NONE,
			frontFace: VK_FRONT_FACE_CLOCKWISE,
			lineWidth: 1f
		};
		VkPipelineMultisampleStateCreateInfo multisampling_info={ rasterizationSamples: VK_SAMPLE_COUNT_1_BIT };
		VkPipelineDepthStencilStateCreateInfo depth_stencil_info;
		VkPipelineColorBlendAttachmentState blend_attachment={
			colorWriteMask: VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT
		};
		VkPipelineColorBlendStateCreateInfo blend_info={ attachmentCount: 1, pAttachments: &blend_attachment };
		VkDynamicState[2] dynamic_states=[ VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR ];
		VkPipelineDynamicStateCreateInfo dynamic_info={ dynamicStateCount: dynamic_states.length, pDynamicStates: dynamic_states.ptr };

		VkGraphicsPipelineCreateInfo pipeline_info={
			stageCount: stages.length,
			pStages: stages.ptr,
			pVertexInputState: &vertex_input_info,
			pInputAssemblyState: &input_assembly_info,
			pViewportState: &viewport_state_info,
			pRasterizationState: &rasterizer_info,
			pMultisampleState: &multisampling_info,
			pDepthStencilState: &depth_stencil_info,
			pColorBlendState: &blend_info,
			pDynamicState: &dynamic_info,
			layout: layout,
			renderPass: present_pass,
			basePipelineIndex: -1
		};
		VkCheck(vkCreateGraphicsPipelines(g_Device, VK_NULL_ND_HANDLE, 1, &pipeline_info, null, &pipeline), "vkCreateGraphicsPipelines (post)");
	}
}

// A render pass with the main pass' attachments (so the scene pipelines work in it): colour cleared, ending in
// colour_final; depth cleared, kept when store_depth.
VkRenderPass MakeScenePass(VkFormat colour_format, VkFormat depth_format, VkImageLayout colour_final, bool store_depth)
{
	VkAttachmentDescription[2] attachments=[
		{
			format: colour_format,
			samples: VK_SAMPLE_COUNT_1_BIT,
			loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
			storeOp: VK_ATTACHMENT_STORE_OP_STORE,
			stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
			stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
			initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
			finalLayout: colour_final
		},
		{
			format: depth_format,
			samples: VK_SAMPLE_COUNT_1_BIT,
			loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
			storeOp: store_depth ? VK_ATTACHMENT_STORE_OP_STORE : VK_ATTACHMENT_STORE_OP_DONT_CARE,
			stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
			stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
			initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
			finalLayout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
		}
	];
	VkAttachmentReference colour_ref={ attachment: 0, layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
	VkAttachmentReference depth_ref={ attachment: 1, layout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
	VkSubpassDescription subpass={
		pipelineBindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS,
		colorAttachmentCount: 1,
		pColorAttachments: &colour_ref,
		pDepthStencilAttachment: &depth_ref
	};
	VkSubpassDependency[2] dependencies=[
		{
			// earlier reads of the images (the previous frame's post pass, a capture's copy)
			srcSubpass: VK_SUBPASS_EXTERNAL,
			dstSubpass: 0,
			srcStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT,
			srcAccessMask: 0,
			dstStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
			dstAccessMask: VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT
		},
		{
			// later reads: the post pass samples the colour, a capture copies colour and depth
			srcSubpass: 0,
			dstSubpass: VK_SUBPASS_EXTERNAL,
			srcStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
			srcAccessMask: VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
			dstStageMask: VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT,
			dstAccessMask: VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_TRANSFER_READ_BIT
		}
	];
	VkRenderPassCreateInfo info={
		attachmentCount: attachments.length,
		pAttachments: attachments.ptr,
		subpassCount: 1,
		pSubpasses: &subpass,
		dependencyCount: dependencies.length,
		pDependencies: dependencies.ptr
	};
	VkRenderPass pass;
	VkCheck(vkCreateRenderPass(g_Device, &info, null, &pass), "vkCreateRenderPass (scene)");
	return pass;
}

// A colour-only render pass, contents not loaded (a fullscreen pass covers everything), ending in final_layout
VkRenderPass MakeColourPass(VkFormat format, VkImageLayout final_layout)
{
	VkAttachmentDescription attachment={
		format: format,
		samples: VK_SAMPLE_COUNT_1_BIT,
		loadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
		storeOp: VK_ATTACHMENT_STORE_OP_STORE,
		stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
		stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
		initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
		finalLayout: final_layout
	};
	VkAttachmentReference colour_ref={ attachment: 0, layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
	VkSubpassDescription subpass={
		pipelineBindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS,
		colorAttachmentCount: 1,
		pColorAttachments: &colour_ref
	};
	VkSubpassDependency[2] dependencies=[
		{
			srcSubpass: VK_SUBPASS_EXTERNAL,
			dstSubpass: 0,
			srcStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT,
			srcAccessMask: 0,
			dstStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
			dstAccessMask: VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
		},
		{
			srcSubpass: 0,
			dstSubpass: VK_SUBPASS_EXTERNAL,
			srcStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
			srcAccessMask: VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
			dstStageMask: VK_PIPELINE_STAGE_TRANSFER_BIT,
			dstAccessMask: VK_ACCESS_TRANSFER_READ_BIT
		}
	];
	VkRenderPassCreateInfo info={
		attachmentCount: 1,
		pAttachments: &attachment,
		subpassCount: 1,
		pSubpasses: &subpass,
		dependencyCount: dependencies.length,
		pDependencies: dependencies.ptr
	};
	VkRenderPass pass;
	VkCheck(vkCreateRenderPass(g_Device, &info, null, &pass), "vkCreateRenderPass (colour)");
	return pass;
}
