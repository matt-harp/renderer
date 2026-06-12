package gfx

import "core:strings"
import vma "thirdparty:odin-vma"
import vk "vendor:vulkan"

import hm "core:container/handle_map"
import vkb "vkbootstrap"

create_image :: proc(
	r: Renderer,
	name: string,
	format: vk.Format,
	extent: vk.Extent3D,
	image_usage_flags: vk.ImageUsageFlags,
	mip_levels: u32 = 1,
	array_layers: u32 = 1,
	image_type: vk.ImageType = .D2,
	msaa_samples: vk.SampleCountFlags = {._1},
	tiling: vk.ImageTiling = .OPTIMAL,
	flags: vk.ImageCreateFlags = {},
	sharing_mode: vk.SharingMode = .EXCLUSIVE,
	alloc_flags: vma.Allocation_Create_Flags = {},
	alloc_usage: vma.Memory_Usage = .Gpu_Only,
	debug_name: cstring = nil,
	loc := #caller_location,
) -> (
	handle: Image_Id,
	err: Error,
) {
	assert(r.allocator != nil, "VMA needs to be initialized first")
	image := GPUImage {
		format         = format,
		extent         = extent,
		usage          = image_usage_flags,
		mip_levels     = mip_levels,
		array_layers   = array_layers,
		current_layout = .UNDEFINED,
		name           = name,
	}

	img_create_info := vk.ImageCreateInfo {
		sType       = .IMAGE_CREATE_INFO,
		format      = format,
		extent      = extent,
		usage       = image_usage_flags,
		mipLevels   = mip_levels,
		arrayLayers = array_layers,
		imageType   = image_type,
		samples     = msaa_samples,
		tiling      = tiling,
		flags       = flags,
		sharingMode = sharing_mode,
	}

	alloc_create_info := vma.Allocation_Create_Info {
		usage = alloc_usage,
		flags = alloc_flags,
	}

	vkb.vk_check(
		vma.create_image(
			r.allocator,
			img_create_info,
			alloc_create_info,
			&image.image,
			&image.allocation,
			nil,
		),
	) or_return
	
	when ODIN_DEBUG {
		c_str := strings.clone_to_cstring(name)
		vma.set_allocation_name(r.allocator, image.allocation, c_str)
		delete(c_str)
	}

	view_type: vk.ImageViewType = .D1
	if .CUBE_COMPATIBLE in flags {
		view_type = .CUBE
	} else {
		switch image_type {
		case .D1:
			view_type = .D1
		case .D2:
			view_type = .D2
		case .D3:
			view_type = .D3
		}
	}

	image.image_view = create_image_view(
		r,
		image.image,
		image.format,
		view_type,
		base_mip_level = 0,
		mip_count = mip_levels,
		base_array_layer = 0,
		layer_count = array_layers,
	) or_return

	handle = hm.add(&r.shader_resources.images, image)

	return
}

create_image_view :: proc(
	r: Renderer,
	image: vk.Image,
	format: vk.Format,
	view_type: vk.ImageViewType = .D2,
	base_mip_level: u32 = 0,
	mip_count: u32 = vk.REMAINING_MIP_LEVELS,
	base_array_layer: u32 = 0,
	layer_count: u32 = vk.REMAINING_ARRAY_LAYERS,
) -> (
	view: vk.ImageView,
	err: Error,
) {
	sub_range := vk.ImageSubresourceRange {
		aspectMask     = get_aspect_mask_from_format(format),
		baseMipLevel   = base_mip_level,
		levelCount     = mip_count,
		baseArrayLayer = base_array_layer,
		layerCount     = layer_count,
	}
	view_create_info := vk.ImageViewCreateInfo {
		sType            = .IMAGE_VIEW_CREATE_INFO,
		image            = image,
		viewType         = view_type,
		format           = format,
		subresourceRange = sub_range,
	}

	vkb.vk_check(vk.CreateImageView(r.device.device, &view_create_info, nil, &view)) or_return

	return
}

create_sampler :: proc(
	r: Renderer,
	min_filter: vk.Filter = .LINEAR,
	mag_filter: vk.Filter = .LINEAR,
	mip_mode: vk.SamplerMipmapMode = .LINEAR,
	addr_mode_u: vk.SamplerAddressMode = .REPEAT,
	addr_mode_v: vk.SamplerAddressMode = .REPEAT,
	addr_mode_w: vk.SamplerAddressMode = .REPEAT,
	max_anisotropy: f32 = 1.0,
) -> (
	sampler: vk.Sampler,
	err: Error,
) {
	sampler_create_info := vk.SamplerCreateInfo {
		sType                   = .SAMPLER_CREATE_INFO,
		minFilter               = min_filter,
		magFilter               = mag_filter,
		mipmapMode              = mip_mode,
		addressModeU            = addr_mode_u,
		addressModeV            = addr_mode_v,
		addressModeW            = addr_mode_w,
		anisotropyEnable        = max_anisotropy > 1.0,
		maxAnisotropy           = max_anisotropy,
		borderColor             = .INT_OPAQUE_BLACK,
		unnormalizedCoordinates = false,
		compareEnable           = false,
		compareOp               = .ALWAYS,
		mipLodBias              = 0,
		minLod                  = 0,
		maxLod                  = 0,
	}

	vkb.vk_check(vk.CreateSampler(r.device.device, &sampler_create_info, nil, &sampler)) or_return

	return
}

get_aspect_mask_from_format :: proc(format: vk.Format) -> vk.ImageAspectFlags {
	#partial switch format {
	// Depth formats
	case .D16_UNORM, .D32_SFLOAT, .X8_D24_UNORM_PACK32:
		return {.DEPTH}

	// Depth/Stencil combined formats
	case .D16_UNORM_S8_UINT, .D24_UNORM_S8_UINT, .D32_SFLOAT_S8_UINT:
		return {.DEPTH, .STENCIL}
	}

	return {.COLOR}
}

transition_vk_image :: proc(
	buffer: vk.CommandBuffer,
	image: vk.Image,
	src_stage_mask, dst_stage_mask: vk.PipelineStageFlags2,
	src_access_mask, dst_access_mask: vk.AccessFlags2,
	old_layout: vk.ImageLayout,
	new_layout: vk.ImageLayout,
	aspect_mask: vk.ImageAspectFlags = {.COLOR},
) {
	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = src_stage_mask,
		srcAccessMask = src_access_mask,
		dstStageMask = dst_stage_mask,
		dstAccessMask = dst_access_mask,
		oldLayout = old_layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = {
			aspectMask = aspect_mask,
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = vk.REMAINING_ARRAY_LAYERS,
		},
	}
	dependency_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		pImageMemoryBarriers    = &barrier,
		imageMemoryBarrierCount = 1,
	}
	vk.CmdPipelineBarrier2(buffer, &dependency_info)
}

destroy_image :: proc(r: ^Renderer, handle: Image_Id) {
	image := hm.get(&r.shader_resources.images, handle)
	destroy_image_unsafe(r, image)
	hm.remove(&r.shader_resources.images, handle)
}

destroy_image_unsafe :: proc(r: ^Renderer, image: ^GPUImage) {
	// log.debugf("destroying image %#v", image)
	vma.destroy_image(r.allocator, image.image, image.allocation)
	vk.DestroyImageView(r.device.device, image.image_view, nil)
}
