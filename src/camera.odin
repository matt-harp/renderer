package main

import "core:math"
import "core:math/linalg"

Camera :: struct {
	pos:         linalg.Vector3f32,
	yaw:         f32,
	pitch:       f32,
	fov:         f32,
	near:        f32,
	far:         f32,
	move_speed:  f32,
	sensitivity: f32,
}

// Input holds per-frame input state, populated from SDL events in the main loop.
Input :: struct {
	mouse_held:     bool,
	mouse_dx:       f32,
	mouse_dy:       f32,
	f5_pressed:     bool,
	frustum_frozen: bool,
	saved_frustum:  [6]Frustum_Plane,
	// WASD / Space / Ctrl movement state (true = key held)
	w_down:         bool,
	a_down:         bool,
	s_down:         bool,
	d_down:         bool,
	space_down:     bool,
	ctrl_down:      bool,
}

camera_init :: proc(
	cam: ^Camera,
	pos: linalg.Vector3f32 = {0, 0, 4},
	fov: f32 = 45.0,
	near: f32 = 0.1,
	far: f32 = 500.0,
) {
	cam.pos = pos
	cam.fov = fov
	cam.near = near
	cam.far = far
	cam.move_speed = 10.0
	cam.sensitivity = 0.2
}

camera_get_view_matrix :: proc(cam: ^Camera, translate_to_view := true) -> linalg.Matrix4f32 {
	yaw_rad := cam.yaw * (math.PI / 180.0)
	pitch_rad := cam.pitch * (math.PI / 180.0)

	rotation :=
		linalg.matrix4_rotate_f32(pitch_rad, {1, 0, 0}) *
		linalg.matrix4_rotate_f32(yaw_rad, {0, 1, 0})
	translation := linalg.matrix4_translate_f32({-cam.pos.x, -cam.pos.y, -cam.pos.z})

	if translate_to_view {
		return rotation * translation
	} else {
		return rotation
	}
}

camera_get_forward :: proc(cam: ^Camera) -> linalg.Vector3f32 {
	yaw_rad := cam.yaw * (math.PI / 180.0)
	pitch_rad := cam.pitch * (math.PI / 180.0)

	return linalg.Vector3f32 {
		math.sin(yaw_rad) * math.cos(pitch_rad),
		-math.sin(pitch_rad),
		-math.cos(yaw_rad) * math.cos(pitch_rad),
	}
}

camera_get_right :: proc(cam: ^Camera) -> linalg.Vector3f32 {
	yaw_rad := cam.yaw * (math.PI / 180.0)
	return linalg.Vector3f32{math.cos(yaw_rad), 0, math.sin(yaw_rad)}
}

// camera_update applies keyboard movement from the input state.
camera_update :: proc(cam: ^Camera, input: ^Input, dt: f32) {
	speed := cam.move_speed * dt
	forward := camera_get_forward(cam)
	right := camera_get_right(cam)
	up := linalg.Vector3f32{0, 1, 0}

	if input.w_down     { cam.pos += forward * speed }
	if input.s_down     { cam.pos -= forward * speed }
	if input.d_down     { cam.pos += right * speed }
	if input.a_down     { cam.pos -= right * speed }
	if input.space_down { cam.pos += up * speed }
	if input.ctrl_down  { cam.pos -= up * speed }
}

// camera_handle_mouse rotates the camera based on mouse delta.
camera_handle_mouse :: proc(cam: ^Camera, dx, dy: f32) {
	cam.yaw += dx * cam.sensitivity
	cam.pitch += dy * cam.sensitivity
	cam.pitch = clamp(cam.pitch, -89.0, 89.0)
}
