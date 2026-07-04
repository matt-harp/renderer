package gfx


Meshlet :: struct {
	bounding_sphere: [4]f32,
	cone_apex:       [3]f32,
	cone_cutoff:     f32,
	cone_axis:       [3]f32,
	vertices_offset: u32, // local meshlet list start
	triangle_offset: u32, // local meshlet index list start
	vertices_count:  u16, // max ~64
	triangle_count:  u16, // max ~128
}

