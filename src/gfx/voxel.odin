package gfx

import "core:math/linalg"

Voxel :: struct {
	color: [4]u8,
}

// side length of a brick
BRICK_DIM :: 8
BRICK_VOXEL_COUNT :: BRICK_DIM * BRICK_DIM * BRICK_DIM

Brick :: struct {
	voxels: [BRICK_VOXEL_COUNT]Voxel,
}

NodeIndex :: u32
BrickIndex :: u32

// Nodes in the 64-tree have children that point to more nodes or to brick leaf nodes
TreeNode :: struct {
	// Mask to track active children
	valid_mask: u64,
	// Indices into node_pool (if internal) or brick_pool (if leaf parent)
	// 0 indicates empty/null
	children:   [64]u32,
}

VoxelStorage :: struct {
	node_pool:   [dynamic]TreeNode,
	brick_pool:  [dynamic]Brick,
	free_nodes:  [dynamic]NodeIndex,
	free_bricks: [dynamic]BrickIndex,
}

VoxelVolume :: struct {
	root_node:   NodeIndex,
	root_height: u32, // 0 = leaves are bricks. 1+ = leaves are nodes pointing to bricks.
	root_pos:    [3]i32, // tracks minimum local (voxel-space) coordinate of the volume
	transform:   matrix[4, 4]f32,
}

init_storage :: proc(s: ^VoxelStorage) {
	s.node_pool = make([dynamic]TreeNode)
	s.brick_pool = make([dynamic]Brick)
	s.free_nodes = make([dynamic]NodeIndex)
	s.free_bricks = make([dynamic]BrickIndex)

	// Reserve index 0 as null
	append(&s.node_pool, TreeNode{})
	append(&s.brick_pool, Brick{})
}

destroy_storage :: proc(s: ^VoxelStorage) {
	delete(s.node_pool)
	delete(s.brick_pool)
	delete(s.free_nodes)
	delete(s.free_bricks)
}

init_volume :: proc(s: ^VoxelStorage, v: ^VoxelVolume) {
	v.root_height = 0
	v.root_pos = {0, 0, 0}
	v.root_node = alloc_node(s)
	v.transform = linalg.MATRIX4F32_IDENTITY
}

destroy_volume :: proc(s: ^VoxelStorage, v: ^VoxelVolume) {
	recursive_free_node(s, v.root_node, v.root_height)
	free_node(s, v.root_node)
	v.root_node = 0
}

alloc_node :: proc(s: ^VoxelStorage) -> NodeIndex {
	if len(s.free_nodes) > 0 {
		idx := pop(&s.free_nodes)
		s.node_pool[idx] = TreeNode{}
		return idx
	}
	append(&s.node_pool, TreeNode{})
	return NodeIndex(len(s.node_pool) - 1)
}

free_node :: proc(s: ^VoxelStorage, idx: NodeIndex) {
	if idx == 0 {
		return
	}
	append(&s.free_nodes, idx)
}

alloc_brick :: proc(s: ^VoxelStorage) -> BrickIndex {
	if len(s.free_bricks) > 0 {
		idx := pop(&s.free_bricks)
		return idx
	}
	append(&s.brick_pool, Brick{})
	return BrickIndex(len(s.brick_pool) - 1)
}

free_brick :: proc(s: ^VoxelStorage, idx: BrickIndex) {
	if idx == 0 {
		return
	}
	append(&s.free_bricks, idx)
}

// Returns the side length of the volume covered by a node at given height in voxel units
// Height 0 node covers 4x4x4 Bricks. Brick is 8. So 4*8 = 32.
// Height 1 node covers 4x4x4 H0 nodes. So 4*32 = 128.
node_size_at_height :: proc(h: u32) -> i32 {
	return (i32(BRICK_DIM) * 4) << (2 * h)
}

get_child_index :: proc(x, y, z: i32) -> u64 {
	return u64(x + y * 4 + z * 4 * 4)
}

// Ensure the tree covers the target position.
// If not, grow the tree and set a new root such that the position is covered
ensure_coverage :: proc(s: ^VoxelStorage, v: ^VoxelVolume, pos: [3]i32) {
	for {
		size := node_size_at_height(v.root_height)

		// Check if pos is within current root bounds
		in_bounds :=
			pos.x >= v.root_pos.x &&
			pos.x < v.root_pos.x + size &&
			pos.y >= v.root_pos.y &&
			pos.y < v.root_pos.y + size &&
			pos.z >= v.root_pos.z &&
			pos.z < v.root_pos.z + size

		if in_bounds {
			break
		}

		// Expand Root
		new_root := alloc_node(s)
		old_root := v.root_node

		// if the pos is behind the root, we want the new root to have the old at its maximum extent
		offset_x: i32 = pos.x < v.root_pos.x ? 3 : 0
		offset_y: i32 = pos.y < v.root_pos.y ? 3 : 0
		offset_z: i32 = pos.z < v.root_pos.z ? 3 : 0

		child_idx := get_child_index(offset_x, offset_y, offset_z)

		s.node_pool[new_root].children[child_idx] = old_root
		s.node_pool[new_root].valid_mask = 1 << child_idx

		v.root_node = new_root
		v.root_height += 1
		v.root_pos.x -= offset_x * size
		v.root_pos.y -= offset_y * size
		v.root_pos.z -= offset_z * size
	}
}

traverse_tree :: proc(s: ^VoxelStorage, v: ^VoxelVolume, voxel_pos: [3]i32, target_height: u32, allocate: bool) -> NodeIndex {
	if allocate {
		ensure_coverage(s, v, voxel_pos)
	}

	curr_idx := v.root_node
	curr_pos := v.root_pos
	curr_h := v.root_height

	// position needs to be within bounds to exist in the tree
	if !allocate {
		size := node_size_at_height(curr_h)
		if voxel_pos.x < curr_pos.x || voxel_pos.x >= curr_pos.x + size ||
		   voxel_pos.y < curr_pos.y || voxel_pos.y >= curr_pos.y + size ||
		   voxel_pos.z < curr_pos.z || voxel_pos.z >= curr_pos.z + size {
			return 0
		}
	}

	// at each height, find the correct child node to descend to
	for curr_h > target_height {
		child_size := node_size_at_height(curr_h - 1)
		rel := voxel_pos - curr_pos

		cx := rel.x / child_size
		cy := rel.y / child_size
		cz := rel.z / child_size

		child_idx_in_node := get_child_index(cx, cy, cz)
		node := &s.node_pool[curr_idx]
		next_idx := node.children[child_idx_in_node]

		// child doesn't exist, so either allocate it or return
		if next_idx == 0 {
			if !allocate {
				return 0
			}
			next_idx = alloc_node(s)
			node = &s.node_pool[curr_idx]
			node.children[child_idx_in_node] = next_idx
			node.valid_mask |= (1 << child_idx_in_node)
		}

		curr_idx = next_idx
		curr_pos.x += cx * child_size
		curr_pos.y += cy * child_size
		curr_pos.z += cz * child_size
		curr_h -= 1
	}

	return curr_idx
}

get_voxel :: proc(s: ^VoxelStorage, v: ^VoxelVolume, voxel_pos: [3]i32) -> Voxel {
	h0_node_idx := traverse_tree(s, v, voxel_pos, 0, false)
	if h0_node_idx == 0 {
		return Voxel{}
	}

	h0_node := &s.node_pool[h0_node_idx]
	rel := voxel_pos - v.root_pos
	bx := (rel.x % 32) / BRICK_DIM
	by := (rel.y % 32) / BRICK_DIM
	bz := (rel.z % 32) / BRICK_DIM
	brick_child_idx := get_child_index(bx, by, bz)

	b_idx := h0_node.children[brick_child_idx]
	if b_idx == 0 {
		return Voxel{}
	}

	vx := rel.x % BRICK_DIM
	vy := rel.y % BRICK_DIM
	vz := rel.z % BRICK_DIM
	v_idx := vx + vy * BRICK_DIM + vz * BRICK_DIM * BRICK_DIM
	return s.brick_pool[b_idx].voxels[v_idx]
}

set_voxel :: proc(s: ^VoxelStorage, v: ^VoxelVolume, voxel_pos: [3]i32, voxel: Voxel) {
	is_empty := voxel.color.a == 0
	h0_node_idx := traverse_tree(s, v, voxel_pos, 0, !is_empty)

	if h0_node_idx == 0 {
		return
	}

	h0_node := &s.node_pool[h0_node_idx]
	rel := voxel_pos - v.root_pos

	bx := (rel.x % 32) / BRICK_DIM
	by := (rel.y % 32) / BRICK_DIM
	bz := (rel.z % 32) / BRICK_DIM
	brick_child_idx := get_child_index(bx, by, bz)

	b_idx := h0_node.children[brick_child_idx]

	if is_empty {
		if b_idx != 0 {
			vx := rel.x % BRICK_DIM
			vy := rel.y % BRICK_DIM
			vz := rel.z % BRICK_DIM
			v_idx := vx + vy * BRICK_DIM + vz * BRICK_DIM * BRICK_DIM
			s.brick_pool[b_idx].voxels[v_idx] = voxel

			brick_empty := true
			for v_data in s.brick_pool[b_idx].voxels {
				if v_data.color.a != 0 {
					brick_empty = false
					break
				}
			}
			if brick_empty {
				free_brick(s, b_idx)
				h0_node.children[brick_child_idx] = 0
				h0_node.valid_mask &= ~(1 << brick_child_idx)
			}
		}
	} else {
		if b_idx == 0 {
			b_idx = alloc_brick(s)
			h0_node.children[brick_child_idx] = b_idx
			h0_node.valid_mask |= (1 << brick_child_idx)
		}

		vx := rel.x % BRICK_DIM
		vy := rel.y % BRICK_DIM
		vz := rel.z % BRICK_DIM
		v_idx := vx + vy * BRICK_DIM + vz * BRICK_DIM * BRICK_DIM
		s.brick_pool[b_idx].voxels[v_idx] = voxel
	}
}

set_brick :: proc(s: ^VoxelStorage, v: ^VoxelVolume, brick_voxel_pos: [3]i32, src_brick: ^Brick) {
	is_empty := true
	if src_brick != nil {
		for v_data in src_brick.voxels {
			if v_data.color.a != 0 {
				is_empty = false
				break
			}
		}
	}

	h0_node_idx := traverse_tree(s, v, brick_voxel_pos, 0, !is_empty)
	if h0_node_idx == 0 {
		return
	}

	h0_node := &s.node_pool[h0_node_idx]
	rel := brick_voxel_pos - v.root_pos
	bx := (rel.x % 32) / BRICK_DIM
	by := (rel.y % 32) / BRICK_DIM
	bz := (rel.z % 32) / BRICK_DIM
	brick_child_idx := get_child_index(bx, by, bz)

	old_brick_idx := h0_node.children[brick_child_idx]

	if !is_empty {
		b_idx := old_brick_idx
		if b_idx == 0 {
			b_idx = alloc_brick(s)
			h0_node = &s.node_pool[h0_node_idx]
			h0_node.children[brick_child_idx] = b_idx
			h0_node.valid_mask |= (1 << brick_child_idx)
		}
		s.brick_pool[b_idx] = src_brick^
	} else if old_brick_idx != 0 {
		free_brick(s, old_brick_idx)
		h0_node.children[brick_child_idx] = 0
		h0_node.valid_mask &= ~(1 << brick_child_idx)
	}
}

recursive_free_node :: proc(s: ^VoxelStorage, idx: NodeIndex, height: u32) {
	node := &s.node_pool[idx]
	for i in 0 ..< 64 {
		child := node.children[i]
		if child != 0 {
			if height == 0 {
				// Children are bricks
				free_brick(s, child)
			} else {
				recursive_free_node(s, child, height - 1)
				free_node(s, child)
			}
			node.children[i] = 0
		}
	}
	node.valid_mask = 0
}

init_voxel_volume :: proc() {
	
}