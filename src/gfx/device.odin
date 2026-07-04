package gfx

import "core:log"
import glfw "vendor:glfw"
import vk "vendor:vulkan"

import vkb "vkbootstrap"

init_device :: proc(r: ^Renderer) -> (err: Error) {
	// Window
	window := create_glfw_window("Vulkan Triangle", true) or_return
	defer if err != nil {
		destroy_glfw_window(r.window)
	}

	// Instance
	instance_builder: vkb.Instance_Builder
	vkb.instance_builder_init(&instance_builder)
	vkb.instance_builder_require_api_version(&instance_builder, MINIMUM_API_VERSION)

	when ODIN_DEBUG {
		vkb.instance_builder_enable_validation_layers(&instance_builder)
		vkb.instance_builder_use_default_debug_messenger(&instance_builder)

		vkb.instance_builder_add_debug_messenger_severity(&instance_builder, {.INFO}) // for printf debugging
		vkb.instance_builder_add_validation_feature_enable(&instance_builder, .DEBUG_PRINTF)
		vkb.instance_builder_set_debug_messenger_type(
			&instance_builder,
			{.VALIDATION, .PERFORMANCE},
		)

		VK_LAYER_LUNARG_MONITOR :: "VK_LAYER_LUNARG_monitor"

		info: vkb.System_Info
		vkb.system_info_init(&info) or_return
		defer vkb.system_info_uninit(&info)
		if vkb.system_info_is_layer_available(info, VK_LAYER_LUNARG_MONITOR) {
			// Displays FPS in the application's title bar. It is only compatible with the
			// Win32 and XCB windowing systems. Mark as not required layer.
			// https://vulkan.lunarg.com/doc/sdk/latest/windows/monitor_layer.html
			when ODIN_OS == .Windows || ODIN_OS == .Linux {
				vkb.instance_builder_enable_layer(&instance_builder, VK_LAYER_LUNARG_MONITOR)
			}
		}
	}

	vkb_instance: vkb.Instance
	vkb.instance_builder_build(&instance_builder, &vkb_instance) or_return
	defer if err != nil {
		vkb.destroy_instance(&vkb_instance)
	}

	// Surface
	surface: vk.SurfaceKHR
	vkb.vk_check(
		glfw.CreateWindowSurface(vkb_instance.vk_instance, window, nil, &surface),
	) or_return
	defer if err != nil {
		vkb.destroy_surface(&vkb_instance, surface)
	}

	// Physical device
	selector: vkb.Physical_Device_Selector
	vkb.physical_device_selector_init(&selector, vkb_instance)
	defer vkb.physical_device_selector_uninit(&selector)

	vkb.physical_device_selector_set_minimum_version(&selector, MINIMUM_API_VERSION)
	vkb.physical_device_selector_set_surface(&selector, surface)

	vk10 := vk.PhysicalDeviceFeatures {
		fragmentStoresAndAtomics       = true,
		vertexPipelineStoresAndAtomics = true,
		shaderInt64                    = true,
		samplerAnisotropy              = true,
		shaderInt16                    = true,
	}
	vkb.physical_device_selector_set_required_features(&selector, vk10)

	vkb_physical_device: vkb.Physical_Device
	vkb.physical_device_selector_select(&selector, &vkb_physical_device) or_return
	defer if err != nil {
		vkb.destroy_physical_device(&vkb_physical_device)
	}

	when ODIN_DEBUG {
		vkb.physical_device_enable_extension_if_present(
			&vkb_physical_device,
			"VK_KHR_shader_non_semantic_info",
		)
	}

	mesh_features := vk.PhysicalDeviceMeshShaderFeaturesEXT {
		sType      = .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT,
		taskShader = true,
		meshShader = true,
	}
	vkb.physical_device_enable_extensions_features_if_present(
		&vkb_physical_device,
		{vk.EXT_MESH_SHADER_EXTENSION_NAME},
		mesh_features,
	)

	if vkb.physical_device_enable_extension_if_present(
		&vkb_physical_device,
		vk.EXT_DEVICE_FAULT_EXTENSION_NAME,
	) {
		log.infof("Enabled VK_EXT_device_fault")
	}

	// Device
	device_builder: vkb.Device_Builder
	vkb.device_builder_init(&device_builder)
	defer vkb.device_builder_uninit(&device_builder)

	// vulkan 1.1 features
	vk11 := vk.PhysicalDeviceVulkan11Features {
		sType                    = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		shaderDrawParameters     = true,
		storageBuffer16BitAccess = true,
		storagePushConstant16    = true,
	}
	vkb.device_builder_add_pnext(&device_builder, &vk11)

	// vulkan 1.2 features
	vk12 := vk.PhysicalDeviceVulkan12Features {
		sType                                         = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		bufferDeviceAddress                           = true,
		scalarBlockLayout                             = true,
		descriptorIndexing                            = true,
		runtimeDescriptorArray                        = true,
		descriptorBindingPartiallyBound               = true,
		descriptorBindingStorageBufferUpdateAfterBind = true,
		descriptorBindingStorageImageUpdateAfterBind  = true,
		descriptorBindingSampledImageUpdateAfterBind  = true,
		timelineSemaphore                             = true,
		vulkanMemoryModel                             = true,
		vulkanMemoryModelDeviceScope                  = true,
		storageBuffer8BitAccess                       = true,
		shaderInt8                                    = true,
		storagePushConstant8                          = true,
	}
	vkb.device_builder_add_pnext(&device_builder, &vk12)

	// vulkan 1.3 features
	vk13 := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		dynamicRendering = true,
		synchronization2 = true,
	}
	vkb.device_builder_add_pnext(&device_builder, &vk13)

	device: vkb.Device
	vkb.device_builder_build(&device_builder, &vkb_physical_device, &device) or_return

	r.window = window
	r.instance = vkb_instance
	r.surface = surface
	r.physical_device = vkb_physical_device
	r.device = device

	return
}

