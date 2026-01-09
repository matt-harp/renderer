package main

import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"

import "gfx"

import glfw "vendor:glfw"

camera_yaw: f32 = 0.0
camera_pitch: f32 = 0.0
last_mouse_x: f64 = 0.0
last_mouse_y: f64 = 0.0
mouse_held: bool = false
stick_length: f32 = 4.0

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

	renderer: gfx.Renderer
	gfx.init_renderer(&renderer)
	defer gfx.destroy_renderer(&renderer)

	// glfw.SetKeyCallback(renderer.window, proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: c.int) {

	// })
	glfw.SetMouseButtonCallback(
		renderer.window,
		proc "c" (window: glfw.WindowHandle, button, action, mods: c.int) {
			if button == glfw.MOUSE_BUTTON_LEFT {
				mouse_held = (action == glfw.PRESS)
				// Reset last pos on press to prevent "jumping" when clicking
				if mouse_held {
					last_mouse_x, last_mouse_y = glfw.GetCursorPos(window)
				}
			}
		},
	)
	glfw.SetCursorPosCallback(
		renderer.window,
		proc "c" (window: glfw.WindowHandle, xpos, ypos: f64) {
			if mouse_held {
				sensitivity: f32 = 0.2
				dx := f32(xpos - last_mouse_x)
				dy := f32(ypos - last_mouse_y)

				camera_yaw += dx * sensitivity
				camera_pitch += dy * sensitivity

				// Constrain pitch to avoid flipping over the poles
				camera_pitch = linalg.clamp(camera_pitch, -89.0, 89.0)
			}
			last_mouse_x = xpos
			last_mouse_y = ypos
		},
	)

	width, height := glfw.GetWindowSize(renderer.window)
	for !glfw.WindowShouldClose(renderer.window) {
		glfw.PollEvents()
		// time := glfw.GetTime()

		yaw_rad := camera_yaw * (math.PI / 180.0)
		pitch_rad := camera_pitch * (math.PI / 180.0)

		model :=
			// linalg.matrix4_rotate_f32(5 * rotate * (math.PI / 180.0), {0, 1, 0}) *
			linalg.matrix4_scale_f32({1, 1, 1})

		view := linalg.matrix4_translate_f32({0, 0, -stick_length}) * linalg.matrix4_rotate_f32(pitch_rad, {1, 0, 0}) * linalg.matrix4_rotate_f32(yaw_rad, {0, 1, 0})

		aspect := f32(width) / f32(height)

		proj := gfx.matrix4_perspective_f32(45.0 * (math.PI / 180.0), aspect, 0.1, 5.0)

		gfx.mvp = proj * view * model

		if ok := gfx.draw_frame(&renderer); !ok {
			log.errorf("Failed to draw frame.")
			break
		}
	}
}
