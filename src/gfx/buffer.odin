package gfx

import "core:strings"
import vma "thirdparty:vma"
import vk "vendor:vulkan"

import hm "core:container/handle_map"
import vkb "vkbootstrap"

create_buffer :: proc(
	r: Renderer,
	$T: typeid,
	name: string,
	#any_int size: vk.DeviceSize = 1,
	vk_usage: vk.BufferUsageFlags,
	vma_flags: vma.AllocationCreateFlags,
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

	alloc_create_info := vma.AllocationCreateInfo {
		usage = .AUTO,
		flags = vma_flags,
	}

	vkb.vk_check(
		vma.CreateBuffer(
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
		vma.SetAllocationName(r.allocator, buffer.allocation, c_str)
		delete(c_str)
	}

	if .SHADER_DEVICE_ADDRESS in vk_usage {
		device_address_info := vk.BufferDeviceAddressInfo {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = buffer.buffer,
		}
		buffer.address = vk.GetBufferDeviceAddress(r.device.vk_device, &device_address_info)
	}

	handle = hm.add(&r.shader_resources.buffers, buffer)

	return
}

write_to_buffer :: proc(
	r: Renderer,
	handle: Buffer_Id,
	src: rawptr,
	#any_int offset: vk.DeviceSize,
	#any_int size: vk.DeviceSize,
) {
	buf := hm.get(&r.shader_resources.buffers, handle)
	vma.CopyMemoryToAllocation(r.allocator, src, buf.allocation, offset, size)
}

destroy_buffer :: proc(r: ^Renderer, handle: Buffer_Id) {
	buffer := hm.get(&r.shader_resources.buffers, handle)
	destroy_buffer_unsafe(r, buffer)
	hm.remove(&r.shader_resources.buffers, handle)
}

destroy_buffer_unsafe :: proc(r: ^Renderer, buffer: ^GPUBuffer) {
	// log.debugf("destroying buffer %#v", buffer)
	vma.DestroyBuffer(r.allocator, buffer.buffer, buffer.allocation)
}
