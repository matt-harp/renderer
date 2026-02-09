package gfx

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"

SVONode :: struct #packed {
	data:  u32, // child_ptr (if internal) or color (if leaf)
	masks: u32, // valid_mask (8 bits) | leaf_mask (8 bits) << 8
}

TempNode :: struct {
	children:   [8]^TempNode,
	is_leaf:    bool,
	color:      u32,
	valid_mask: u8,
	leaf_mask:  u8,
}

build_test_svo :: proc(allocator: mem.Allocator) -> (nodes: [dynamic]SVONode) {
	// Use temp allocator for the tree construction
	temp_arena: mem.Arena
	mem.arena_init(&temp_arena, make([]byte, 512 * mem.Megabyte))
	defer delete(temp_arena.data)
	temp_alloc := mem.arena_allocator(&temp_arena)

	// Sphere radius 0.9, depth 8 gives reasonable resolution for testing
	root := build_octree_recursive([3]f32{0, 0, 0}, 2.0, 0, 4, temp_alloc)
	if root == nil {
		return nil
	}

	nodes = make([dynamic]SVONode, allocator)

	// Reserve root at index 0
	append(&nodes, SVONode{})

	flatten_internal(root, 0, &nodes)

	return nodes
}

build_octree_recursive :: proc(
	center: [3]f32,
	size: f32,
	depth: int,
	max_depth: int,
	allocator: mem.Allocator,
) -> ^TempNode {
	node, err := new(TempNode, allocator)
	if err != nil {
		log.infof("%v", err)
	}

	if depth == max_depth {
		if linalg.length2(center) <= 0.81 { 	// 0.9^2
			node.is_leaf = true
			r := u8((center.x + 1.0) * 0.5 * 255)
			g := u8((center.y + 1.0) * 0.5 * 255)
			b := u8((center.z + 1.0) * 0.5 * 255)
			node.color = u32(r) | (u32(g) << 8) | (u32(b) << 16) | (255 << 24)
			return node
		}
		return nil
	}

	half_size := size * 0.5
	quarter_size := size * 0.25

	child_offsets := [8][3]f32 {
		{-1, -1, -1},
		{1, -1, -1},
		{-1, 1, -1},
		{1, 1, -1},
		{-1, -1, 1},
		{1, -1, 1},
		{-1, 1, 1},
		{1, 1, 1},
	}

	has_children := false

	// Conservative check: closest point on AABB to sphere center (0,0,0)
	closest := [3]f32 {
		math.clamp(0.0, center.x - half_size, center.x + half_size),
		math.clamp(0.0, center.y - half_size, center.y + half_size),
		math.clamp(0.0, center.z - half_size, center.z + half_size),
	}
	if linalg.length2(closest) > 0.81 {
		return nil
	}

	for i in 0 ..< 8 {
		offset := child_offsets[i]
		child_center := center + offset * quarter_size

		child := build_octree_recursive(child_center, half_size, depth + 1, max_depth, allocator)
		if child != nil {
			node.children[i] = child
			node.valid_mask |= (1 << u8(i))
			if child.is_leaf {
				node.leaf_mask |= (1 << u8(i))
			}
			has_children = true
		}
	}

	if !has_children {
		return nil
	}

	return node
}

flatten_internal :: proc(node: ^TempNode, my_index: u32, nodes: ^[dynamic]SVONode) {
	child_count := 0
	for i in 0 ..< 8 {
		if node.children[i] != nil {
			child_count += 1
		}
	}

	if child_count == 0 {
		return
	}

	first_child_idx := u32(len(nodes))
	resize(nodes, len(nodes) + child_count)

	nodes[my_index].data = first_child_idx
	nodes[my_index].masks = u32(node.valid_mask) | (u32(node.leaf_mask) << 8)

	current_child_offset := 0

	// First pass: fill immediate children slots
	for i in 0 ..< 8 {
		if node.children[i] != nil {
			child := node.children[i]
			child_idx := first_child_idx + u32(current_child_offset)

			if child.is_leaf {
				nodes[child_idx].data = child.color
				nodes[child_idx].masks = 0
			}
			current_child_offset += 1
		}
	}

	// Second pass: recurse for internal children to populate their sub-trees
	current_child_offset = 0
	for i in 0 ..< 8 {
		if node.children[i] != nil {
			child := node.children[i]
			if !child.is_leaf {
				child_idx := first_child_idx + u32(current_child_offset)
				flatten_internal(child, child_idx, nodes)
			}
			current_child_offset += 1
		}
	}
}
