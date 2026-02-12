package main

import "core:math"
import "core:math/linalg"
import glfw "vendor:glfw"

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

camera_init :: proc(
	cam: ^Camera,
	pos: linalg.Vector3f32 = {0, 0, 5},
	fov: f32 = 45.0,
	near: f32 = 0.1,
	far: f32 = 500.0,
) {
	cam.pos = pos
	cam.fov = fov
	cam.near = near
	cam.far = far
	cam.move_speed = 100.0
	cam.sensitivity = 0.2
}

camera_get_view_matrix :: proc(cam: ^Camera, translate_to_view := true) -> linalg.Matrix4f32 {
	yaw_rad := cam.yaw * (math.PI / 180.0)
	pitch_rad := cam.pitch * (math.PI / 180.0)

	// The view matrix is the inverse of the camera's transformation matrix
	// camera_transform = translation * rotation_yaw * rotation_pitch
	// view = inverse(camera_transform) = inverse(rotation_pitch) * inverse(rotation_yaw) * inverse(translation)
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

camera_update :: proc(cam: ^Camera, window: glfw.WindowHandle, dt: f32) {
	speed := cam.move_speed * dt

	forward := camera_get_forward(cam)
	right := camera_get_right(cam)
	up := linalg.Vector3f32{0, 1, 0}

	if glfw.GetKey(window, glfw.KEY_W) == glfw.PRESS {
		cam.pos += forward * speed
	}
	if glfw.GetKey(window, glfw.KEY_S) == glfw.PRESS {
		cam.pos -= forward * speed
	}
	if glfw.GetKey(window, glfw.KEY_D) == glfw.PRESS {
		cam.pos += right * speed
	}
	if glfw.GetKey(window, glfw.KEY_A) == glfw.PRESS {
		cam.pos -= right * speed
	}
	if glfw.GetKey(window, glfw.KEY_SPACE) == glfw.PRESS {
		cam.pos += up * speed
	}
	if glfw.GetKey(window, glfw.KEY_LEFT_CONTROL) == glfw.PRESS {
		cam.pos -= up * speed
	}
}

camera_handle_mouse :: proc(cam: ^Camera, dx, dy: f32) {
	cam.yaw += dx * cam.sensitivity
	cam.pitch += dy * cam.sensitivity

	// Constrain pitch to avoid flipping over the poles
	cam.pitch = linalg.clamp(cam.pitch, -89.0, 89.0)
}
