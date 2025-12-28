package gfx

import "core:math"
import "core:math/linalg"

matrix4_perspective_f32 :: proc "contextless" (
	fovy, aspect, near, far: f32,
) -> (
	m: linalg.Matrix4f32,
) #no_bounds_check {
	tan_half_fovy := math.tan(0.5 * fovy)
	m[0, 0] = 1 / (aspect * tan_half_fovy)
	m[1, 1] = -1 / (tan_half_fovy) // negate
	m[2, 2] = (far) / (far - near)
	m[3, 2] = 1
	m[2, 3] = -far * near / (far - near)

	m[2] = -m[2]

	return
}
