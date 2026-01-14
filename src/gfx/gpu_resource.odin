package gfx

import hm "handle_map"
import vma "thirdparty:odin-vma"
import vk "vendor:vulkan"


Buffer_Id :: distinct hm.Handle

GPUBuffer :: struct {
	handle:     Buffer_Id,
	buffer:     vk.Buffer,
	allocation: vma.Allocation,
	info:       vma.Allocation_Info,
	address:    Maybe(vk.DeviceAddress),
}

GPU_Shader_Resource_Table :: struct {
	buffer_slots: hm.Handle_Map(GPUBuffer, Buffer_Id, 1024),
}
