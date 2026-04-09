package gfx

import "core:strings"
import vma "thirdparty:odin-vma"
import vk "vendor:vulkan"

import hm "handle_map"
import vkb "vkbootstrap"

create_buffer :: proc(
	r: Renderer,
	$T: typeid,
	name: string,
	#any_int size: vk.DeviceSize = 1,
	vk_usage: vk.BufferUsageFlags,
	vma_flags: vma.Allocation_Create_Flags,
	loc := #caller_location,
) -> (
	handle: Buffer_Id,
	err: Error,
) {
	assert(r.allocator != nil, "VMA needs to be initialized first")
	buffer := GPUBuffer {
		name = name,
	}

	alloc_size := cast(vk.DeviceSize)(size_of(T) * size)
	buffer_create_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = alloc_size,
		usage = vk_usage,
	}

	alloc_create_info := vma.Allocation_Create_Info {
		usage = .Auto,
		flags = vma_flags,
	}

	vkb.vk_check(
		vma.create_buffer(
			r.allocator,
			buffer_create_info,
			alloc_create_info,
			&buffer.buffer,
			&buffer.allocation,
			&buffer.info,
		),
	) or_return
	
	when ODIN_DEBUG {
		c_str := strings.clone_to_cstring(name)
		vma.set_allocation_name(r.allocator, buffer.allocation, c_str)
		delete(c_str)
	}

	if .SHADER_DEVICE_ADDRESS in vk_usage {
		device_address_info := vk.BufferDeviceAddressInfo {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = buffer.buffer,
		}
		buffer.address = vk.GetBufferDeviceAddress(r.device.device, &device_address_info)
	}

	handle = hm.add(&r.shader_resources.buffers, buffer)

	return
}

destroy_buffer :: proc(r: ^Renderer, handle: Buffer_Id) {
	buffer := hm.get(r.shader_resources.buffers, handle)
	destroy_buffer_unsafe(r, buffer)
	hm.remove(&r.shader_resources.buffers, handle)
}

destroy_buffer_unsafe :: proc(r: ^Renderer, buffer: ^GPUBuffer) {
	// log.debugf("destroying buffer %#v", buffer)
	vma.destroy_buffer(r.allocator, buffer.buffer, buffer.allocation)
}
