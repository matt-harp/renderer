import common;

struct Voxel {
	uint PackedColor;

	property float4 Color {
		[ForceInline]
		get {
			return this.PackedColor.asRGBA();
		}
	}
};

extension uint {
	float4 asRGBA() {
		return float4(
	        float(this & 0xFF),
	        float((this >> 8) & 0xFF),
	        float((this >> 16) & 0xFF),
	        float(this >> 24)
	    ) / 255.0;
	}
}

struct Brick {
    Voxel Voxels[512]; // 8*8*8
};

struct TreeNode {
	uint64_t ValidMask;
	uint Children[64];
}

struct DispatchParams {
    float4x4 InvProjMat;
    float3 CameraOrigin;
    ImageHandle2D OutputAlbedoTex;
    ROBufferHandle<Brick> BrickBuffer;
    ROBufferHandle<TreeNode> NodeBuffer;
};
[[vk::push_constant]] DispatchParams pc;

// Helper: Ray-AABB Intersection
float2 intersectAABB(float3 ro, float3 rd, float3 boxMin, float3 boxMax) {
    float3 tMin = (boxMin - ro) / rd;
    float3 tMax = (boxMax - ro) / rd;
    float3 t1 = min(tMin, tMax);
    float3 t2 = max(tMin, tMax);
    float tNear = max(max(t1.x, t1.y), t1.z);
    float tFar = min(min(t2.x, t2.y), t2.z);
    return float2(tNear, tFar);
}

void GetPrimaryRay(int2 screenPos, out float3 rayPos, out float3 rayDir) {
    float2 uv = (screenPos + 0.5) / float2(pc.OutputAlbedoTex.Instance.Size);
    uv = uv * 2 - 1;
    float4 far = mul(pc.InvProjMat, float4(uv, 1, 1));
    rayDir = normalize(far.xyz / far.w);
    rayPos = pc.CameraOrigin;
}

float3 StepMask(float3 sideDist) {
	bool3 move;
	bool3 pon = sideDist.xyz < sideDist.yzx; // priority over next component -- 3 adjacent comparisons

	move.x = pon.x && !pon.z; // x < y and x <= z
	move.y = pon.y && !pon.x; // y < z and y <= x
	move.z = !(move.x || move.y);

	return float3(move);
}

// 1. be able to trace the world alone by descending the tree
// 2. test if the ray intersects with bounding boxes of other models
// 3. trace within intersecting models
float4 TraceWorld(float3 rayPos, float3 rayDir) {
	float3 mapPos = floor(rayPos); // voxel position
	float3 raySign = sign(rayDir);
	float3 deltaDist = 1 / rayDir; // ray length per 1 unit along axis
	// draw it out if it doesn't make sense
	float3 sideDist = (
		(mapPos - rayPos) // negative offset within voxel
		// if we are moving in positive direction, then add 1 to get remaining distance.
		// if moving negative, this distance is already how far the next floor position is
		+ 0.5 + raySign * 0.5
	) * deltaDist; // translate to ray length
	float3 mask = StepMask(sideDist);

	for (int i = 0; i < 64; i++) {
		if (GetVoxel(mapPos)) {
			return;
		}

		mask      = StepMask(sideDist);
		mapPos   += mask * raySign;
		sideDist += mask * raySign * deltaDist;
	}

	return float4(0.0);
}

[shader("compute")]
[numthreads(16, 16, 1)]
void main(uint2 screenPos : SV_DispatchThreadID) {
    if (any(screenPos >= pc.OutputAlbedoTex.Instance.Size)) return;

    float4 finalColor = float4(0.05, 0.05, 0.05, 1.0); // Background

    float3 rayOrigin, rayDir;
    GetPrimaryRay(screenPos, rayOrigin, rayDir);

    if (any(rayDir == 0.0)) {
   		rayDir += float3(rayDir == 0.0) * 1e-4; // avoid divide by 0
    }
    finalColor = TraceWorld(rayOrigin, rayDir);

    pc.OutputAlbedoTex.Store(screenPos, finalColor);
}
