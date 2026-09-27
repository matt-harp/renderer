package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "thirdparty:no_gfx_api/gpu"

import sdl "vendor:sdl3"

GROUP_SIZE :: 32

Instance :: struct {
	model_matrix:    matrix[4, 4]f32,
	meshlet_offset:  u32,
	meshlet_count:   u32,
	bounding_sphere: [4]f32, // Not used yet
	_pad:            [8]u8,
}

Frustum_Plane :: struct {
	normal: [3]f32,
	d:      f32,
}

Start_Window_Size_X :: 1000
Start_Window_Size_Y :: 1000
Frames_In_Flight :: 3

camera: Camera

Meshlet :: struct {
	bounding_sphere: [4]f32,
	cone_apex:       [3]f32,
	cone_cutoff:     f32,
	cone_axis:       [3]f32,
	vertices_offset: u32, // local meshlet list start
	triangle_offset: u32, // local meshlet index list start
	vertices_count:  u32, // max ~64
	triangle_count:  u32, // max ~128
}

extract_frustum_planes :: proc(vp: linalg.Matrix4f32) -> [6]Frustum_Plane {
	planes: [6]Frustum_Plane

	planes[0].normal = {vp[0, 0] + vp[3, 0], vp[0, 1] + vp[3, 1], vp[0, 2] + vp[3, 2]}
	planes[0].d = vp[0, 3] + vp[3, 3]

	planes[1].normal = {vp[3, 0] - vp[0, 0], vp[3, 1] - vp[0, 1], vp[3, 2] - vp[0, 2]}
	planes[1].d = vp[3, 3] - vp[0, 3]

	planes[2].normal = {vp[1, 0] + vp[3, 0], vp[1, 1] + vp[3, 1], vp[1, 2] + vp[3, 2]}
	planes[2].d = vp[1, 3] + vp[3, 3]

	planes[3].normal = {vp[3, 0] - vp[1, 0], vp[3, 1] - vp[1, 1], vp[3, 2] - vp[1, 2]}
	planes[3].d = vp[3, 3] - vp[1, 3]

	planes[4].normal = {vp[2, 0], vp[2, 1], vp[2, 2]}
	planes[4].d = vp[2, 3]

	planes[5].normal = {vp[3, 0] - vp[2, 0], vp[3, 1] - vp[2, 1], vp[3, 2] - vp[2, 2]}
	planes[5].d = vp[3, 3] - vp[2, 3]

	for i in 0 ..< 6 {
		inv_len := 1.0 / linalg.length(planes[i].normal)
		planes[i].normal *= inv_len
		planes[i].d *= inv_len
	}

	return planes
}

matrix4_perspective_f32 :: proc "contextless" (
	fovy, aspect, near, far: f32,
) -> (
	m: linalg.Matrix4f32,
) #no_bounds_check {
	tan_half_fovy := math.tan(0.5 * fovy)
	m[0, 0] = 1 / (aspect * tan_half_fovy)
	m[1, 1] = -1 / (tan_half_fovy) // negated
	m[2, 2] = (far) / (far - near)
	m[3, 2] = 1
	m[2, 3] = -far * near / (far - near)

	m[2] = -m[2]

	return
}

main :: proc() {
	when ODIN_DEBUG {
		logger := log.create_console_logger(opt = {.Level, .Terminal_Color})
		defer log.destroy_console_logger(logger)

		context.logger = logger

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer mem.tracking_allocator_destroy(&track)

		defer {
			for _, leak in track.allocation_map {
				fmt.printf("%v leaked %v bytes\n", leak.location, leak.size)
			}
			for bad_free in track.bad_free_array {
				fmt.printf(
					"%v allocation %p was freed badly\n",
					bad_free.location,
					bad_free.memory,
				)
			}
		}
	}

	window_flags :: sdl.WindowFlags{.HIGH_PIXEL_DENSITY, .VULKAN, .RESIZABLE}
	window := sdl.CreateWindow(
		"sdl window",
		Start_Window_Size_X,
		Start_Window_Size_Y,
		window_flags,
	)
	ensure(window != nil)

	display_scale: f32 = sdl.GetWindowDisplayScale(window)

	window_size_x := i32(Start_Window_Size_X * display_scale)
	window_size_y := i32(Start_Window_Size_Y * display_scale)

	ok := gpu.init()
	ensure(ok)
	defer gpu.cleanup()

	task_shader := gpu.shader_create_mesh(
		#load("../shaders/shader.task.spv", []u32),
		.Task,
		entry_point_name = "taskMain",
	)
	mesh_shader := gpu.shader_create_mesh(
		#load("../shaders/shader.mesh.spv", []u32),
		.Mesh,
		entry_point_name = "meshMain",
	)
	frag_shader := gpu.shader_create_mesh(
		#load("../shaders/shader.frag.spv", []u32),
		.Fragment,
		entry_point_name = "fragmentMain",
	)
	defer {
		gpu.shader_destroy(task_shader)
		gpu.shader_destroy(mesh_shader)
		gpu.shader_destroy(frag_shader)
	}

	gpu.swapchain_init_from_sdl(window, Frames_In_Flight)

	depth_desc := gpu.Texture_Desc {
		type       = .D2,
		dimensions = {u32(window_size_x), u32(window_size_y), 1},
		mip_count  = 1,
		format     = .D32_Float,
		usage      = {.Depth_Stencil_Attachment},
	}
	depth_tex := gpu.texture_alloc_and_create(depth_desc)

	camera_init(&camera)

	model, model_load_err := load_model_from_file("boulder_01.glb")
	if !model_load_err {
		log.errorf("couldn't load model")
		return
	}
	prim := model.meshes[0].primitives[0]

	upload_arena := gpu.arena_create()
	defer gpu.arena_destroy(&upload_arena)

	upload_sem := gpu.semaphore_create()
	defer gpu.semaphore_destroy(upload_sem)

	total_meshlets := 0
	instances := gpu.arena_alloc(&upload_arena, Instance, 16)
	for i := 0; i < 16; i += 1 {
		x := f32(i % 4) * 2.0 - 3.0
		y := f32(i / 4) * 2.0 - 3.0

		instances.cpu[i] = Instance {
			model_matrix   = linalg.matrix4_translate_f32(
				{x, y, 0},
			) * linalg.matrix4_scale_f32({1.0, 1.0, 1.0}),
			meshlet_offset = 0,
			meshlet_count  = u32(len(prim.meshlets)),
		}

		total_meshlets += len(prim.meshlets)
	}

	instance_map := gpu.arena_alloc(&upload_arena, u32, total_meshlets)
	meshlet_map := gpu.arena_alloc(&upload_arena, u32, total_meshlets)
	count := u32(0)
	for i := 0; i < 16; i += 1 {
		for j := 0; j < int(instances.cpu[i].meshlet_count); j += 1 {
			instance_map.cpu[count] = u32(i) // which instance?
			meshlet_map.cpu[count] = u32(j) // which meshlet in this instance?
			count += 1
		}
	}

	mesh_vertex := gpu.arena_alloc(&upload_arena, Vertex, len(prim.vertices))
	mem.copy(
		raw_data(mesh_vertex.cpu),
		raw_data(prim.vertices),
		len(prim.vertices) * size_of(Vertex),
	)
	meshlet_metadata := gpu.arena_alloc(&upload_arena, Meshlet, len(prim.meshlets))
	mem.copy(
		raw_data(meshlet_metadata.cpu),
		raw_data(prim.meshlets),
		len(prim.meshlets) * size_of(Meshlet),
	)
	meshlet_vertex := gpu.arena_alloc(&upload_arena, u32, len(prim.local_vertices))
	mem.copy(
		raw_data(meshlet_vertex.cpu),
		raw_data(prim.local_vertices),
		len(prim.local_vertices) * size_of(u32),
	)
	meshlet_triangle := gpu.arena_alloc(&upload_arena, u8, len(prim.local_triangles))
	mem.copy(
		raw_data(meshlet_triangle.cpu),
		raw_data(prim.local_triangles),
		len(prim.local_triangles) * size_of(u8),
	)

	instances_local := gpu.mem_alloc_slice(Instance, 16, .GPU)
	instance_map_local := gpu.mem_alloc_slice(u32, total_meshlets, .GPU)
	meshlet_map_local := gpu.mem_alloc_slice(u32, total_meshlets, .GPU)
	mesh_vertex_local := gpu.mem_alloc_slice(Vertex, len(prim.vertices), .GPU)
	meshlet_metadata_local := gpu.mem_alloc_slice(Meshlet, len(prim.meshlets), .GPU)
	meshlet_vertex_local := gpu.mem_alloc_slice(u32, len(prim.local_vertices), .GPU)
	meshlet_triangle_local := gpu.mem_alloc_slice(u8, len(prim.local_triangles), .GPU)

	upload_cmd_buf := gpu.commands_begin(.Transfer)
	gpu.cmd_mem_copy(upload_cmd_buf, instances_local, instances)
	gpu.cmd_mem_copy(upload_cmd_buf, instance_map_local, instance_map)
	gpu.cmd_mem_copy(upload_cmd_buf, meshlet_map_local, meshlet_map)
	gpu.cmd_mem_copy(upload_cmd_buf, mesh_vertex_local, mesh_vertex)
	gpu.cmd_mem_copy(upload_cmd_buf, meshlet_metadata_local, meshlet_metadata)
	gpu.cmd_mem_copy(upload_cmd_buf, meshlet_vertex_local, meshlet_vertex)
	gpu.cmd_mem_copy(upload_cmd_buf, meshlet_triangle_local, meshlet_triangle)
	gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
	gpu.cmd_add_signal_semaphore(upload_cmd_buf, upload_sem, 1)
	gpu.queue_submit(.Transfer, {upload_cmd_buf})

	gpu.semaphore_wait(upload_sem, 1)

	last_time := f64(sdl.GetTicks()) / 1000.0

	fps_frame_count := 0
	fps_elapsed := 0.0


	frame_arenas: [Frames_In_Flight]gpu.Arena
	for &frame_arena in frame_arenas {
		frame_arena = gpu.arena_create()
	}
	defer for &frame_arena in frame_arenas {
		gpu.arena_destroy(&frame_arena)
	}

	next_frame := u64(1)
	frame_sem := gpu.semaphore_create(0)
	defer gpu.semaphore_destroy(frame_sem)

	input: Input
	running := true
	for running {
		// Reset per-frame transient input state
		input.mouse_dx = 0
		input.mouse_dy = 0
		input.f5_pressed = false

		// Poll SDL events
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false
			case .KEY_DOWN:
				#partial switch event.key.scancode {
				case .W:
					input.w_down = true
				case .A:
					input.a_down = true
				case .S:
					input.s_down = true
				case .D:
					input.d_down = true
				case .SPACE:
					input.space_down = true
				case .LCTRL, .RCTRL:
					input.ctrl_down = true
				case .F5:
					input.f5_pressed = true
				}
			case .KEY_UP:
				#partial switch event.key.scancode {
				case .W:
					input.w_down = false
				case .A:
					input.a_down = false
				case .S:
					input.s_down = false
				case .D:
					input.d_down = false
				case .SPACE:
					input.space_down = false
				case .LCTRL, .RCTRL:
					input.ctrl_down = false
				}
			case .MOUSE_MOTION:
				input.mouse_dx += event.motion.xrel
				input.mouse_dy += event.motion.yrel
			case .MOUSE_BUTTON_DOWN:
				if event.button.button == sdl.BUTTON_LEFT {
					input.mouse_held = true
				}
			case .MOUSE_BUTTON_UP:
				if event.button.button == sdl.BUTTON_LEFT {
					input.mouse_held = false
				}
			}
		}

		old_window_size_x := window_size_x
		old_window_size_y := window_size_y
		sdl.GetWindowSizeInPixels(window, &window_size_x, &window_size_y)
		if .MINIMIZED in sdl.GetWindowFlags(window) || window_size_x <= 0 || window_size_y <= 0 {
			sdl.Delay(16)
			continue
		}

		time := f64(sdl.GetTicks()) / 1000.0
		delta_time := f32(time - last_time)
		last_time = time

		fps_frame_count += 1
		fps_elapsed += f64(delta_time)
		if fps_elapsed >= 1.0 {
			log.infof("FPS: %.1f", f64(fps_frame_count) / fps_elapsed)
			fps_frame_count = 0
			fps_elapsed = 0.0
		}

		// Handle mouse look (only when mouse is held)
		if input.mouse_held {
			camera_handle_mouse(&camera, input.mouse_dx, input.mouse_dy)
		}

		camera_update(&camera, &input, delta_time)

		// F5 frustum freeze toggle
		if input.f5_pressed {
			input.frustum_frozen = !input.frustum_frozen
			if input.frustum_frozen {
				view_tmp := camera_get_view_matrix(&camera)
				aspect := f32(window_size_x) / f32(window_size_y)
				proj_tmp := matrix4_perspective_f32(
					camera.fov * (math.PI / 180.0),
					aspect,
					camera.near,
					camera.far,
				)
				input.saved_frustum = extract_frustum_planes(proj_tmp * view_tmp)
				log.infof("Frustum planes frozen")
			} else {
				log.infof("Frustum planes unfrozen")
			}
		}

		if next_frame > Frames_In_Flight {
			gpu.semaphore_wait(frame_sem, next_frame - Frames_In_Flight)
		}
		if old_window_size_x != window_size_x || old_window_size_y != window_size_y {
			gpu.queue_wait_idle(.Main)
			gpu.swapchain_resize({u32(max(0, window_size_x)), u32(max(0, window_size_y))})
			gpu.texture_free_and_destroy(&depth_tex)
			depth_tex = gpu.texture_alloc_and_create({
				type = .D2,
				dimensions = {u32(window_size_x), u32(window_size_y), 1},
				mip_count = 1,
				format = .D32_Float,
				usage = {.Depth_Stencil_Attachment}
			})
		}

		view := camera_get_view_matrix(&camera)
		aspect := f32(window_size_x) / f32(window_size_y)
		proj := matrix4_perspective_f32(
			camera.fov * (math.PI / 180.0),
			aspect,
			camera.near,
			camera.far,
		)

		swapchain := gpu.swapchain_acquire_next()

		frame_arena := &frame_arenas[next_frame % Frames_In_Flight]
		gpu.arena_free_all(frame_arena)

		cmd_buf := gpu.commands_begin(.Main)

		gpu.cmd_begin_render_pass(
			cmd_buf,
			{
				color_attachments = {{texture = swapchain, clear_color = {1.0, 1.0, 1.0, 1.0}}},
				depth_attachment = gpu.Render_Attachment {
					texture = depth_tex.tex,
					load_op = .Clear,
					store_op = .Store,
					clear_color = {1.0, 0, 0, 0},
				},
			},
		)

		gpu.cmd_set_task_shader(cmd_buf, task_shader)
		gpu.cmd_set_mesh_shaders(cmd_buf, mesh_shader, frag_shader)

		Task_Data :: struct {
			meshlets:       rawptr,
			meshlet_count:  u32,
			instances:      rawptr,
			instance_map:   rawptr,
			meshlet_map:    rawptr,
			instance_count: u32,
			camera_pos:     [3]f32,
			frustum_planes: [6]Frustum_Plane,
		}
		task_data := gpu.arena_alloc(frame_arena, Task_Data)
		planes := extract_frustum_planes(proj * view)
		if input.frustum_frozen {
			planes = input.saved_frustum
		}
		task_data.cpu^ = {
			meshlets       = meshlet_metadata_local.gpu.ptr,
			meshlet_count  = u32(total_meshlets),
			instances      = instances_local.gpu.ptr,
			instance_map   = instance_map_local.gpu.ptr,
			meshlet_map    = meshlet_map_local.gpu.ptr,
			instance_count = u32(len(instances.cpu)),
			camera_pos     = camera.pos,
			frustum_planes = planes,
		}

		Mesh_Data :: struct {
			view_proj:     matrix[4, 4]f32,
			instances:     rawptr,
			meshlets:      rawptr,
			indices:       rawptr,
			vertices:      rawptr,
			mesh_vertices: rawptr,
		}
		mesh_data := gpu.arena_alloc(frame_arena, Mesh_Data)
		mesh_data.cpu^ = {
			instances     = instances_local.gpu.ptr,
			meshlets      = meshlet_metadata_local.gpu.ptr,
			indices       = meshlet_triangle_local.gpu.ptr,
			vertices      = meshlet_vertex_local.gpu.ptr,
			mesh_vertices = mesh_vertex_local.gpu.ptr,
			view_proj     = proj * view,
		}

		num_groups := (total_meshlets + GROUP_SIZE - 1) / GROUP_SIZE
		gpu.cmd_set_depth_state(cmd_buf, {mode = {.Read, .Write}, compare = .Less})
		gpu.cmd_draw_meshlets(
			cmd_buf,
			task_data.gpu,
			mesh_data.gpu,
			gpu.null,
			u32(num_groups),
			1,
			1,
		)

		gpu.cmd_end_render_pass(cmd_buf)

		gpu.cmd_add_signal_semaphore(cmd_buf, frame_sem, next_frame)
		gpu.queue_submit(.Main, {cmd_buf})

		gpu.swapchain_present(.Main, frame_sem, next_frame)
		next_frame += 1
	}

	unload_model(model)
	gpu.wait_idle()
}
