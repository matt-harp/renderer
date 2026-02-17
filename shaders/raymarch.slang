import shaders.core;

struct Voxel {
	uint PackedColor;

	property float4 Color {
		[ForceInline]
		get {
			return PackedColor.asRGBA();
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

struct DispatchParams {
    float4x4 InvProjMat;
    float3 CameraOrigin;
    ImageHandle2D OutputAlbedoTex;
    ROBufferHandle<Voxel> VolumeData;
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
	// nit: UV re-scaling and anti-alias jitter can be pre-baked in the matrix.
    float2 uv = (screenPos + 0.5) / float2(pc.OutputAlbedoTex.Instance.Size);
    uv = uv * 2 - 1;
    float4 far = mul(pc.InvProjMat, float4(uv, 1, 1));
    rayDir = normalize(far.xyz / far.w);
    rayPos = pc.CameraOrigin;
}

[shader("compute")]
[numthreads(16, 16, 1)]
void main(uint2 screenPos : SV_DispatchThreadID) {
    if (any(screenPos >= pc.OutputAlbedoTex.Instance.Size)) return;

    float3 rayPos, rayDir;
    GetPrimaryRay(screenPos, rayPos, rayDir);

    float2 tRange = intersectAABB(rayPos, rayDir, float3(0), float3(64));
    if (tRange.x > tRange.y || tRange.y < 0) {
        pc.OutputAlbedoTex.Store(screenPos, float4(0.0, 0.0, 0.0, 1.0));
        return;
    }

    float tStart = max(tRange.x, 0.0);
    float3 ro = rayPos + rayDir * (tStart + 1e-4); // add small epsilon

    float3 rayStep = sign(rayDir);
    float3 deltaDist = 1.0 / abs(rayDir);
    float3 sideDist = (sign(rayDir) * (floor(ro) - ro) + (sign(rayDir) * 0.5) + 0.5) * deltaDist;
    int3 voxelPos = int3(floor(ro));
    float3 normal;

    const int MAX_STEPS = 192;

    for (int i = 0; i < MAX_STEPS; i++) {
        if (any(voxelPos < 0) || any(voxelPos >= 64)) break;

        uint index = uint(voxelPos.x + voxelPos.y * 64 + voxelPos.z * 64 * 64);
        float4 color = pc.VolumeData.Instance.Load(index).Color;

        if (color.w > 0.0) {
        	float3 normalColor = normal * 0.5 + 0.5;
         	float light = clamp(dot(normal, normalize(float3(0.3, 1.0, 0.2))), 0.4, 1.0);

            pc.OutputAlbedoTex.Store(screenPos, color * light);
            return;
        }

        // Improved tie-breaking mask to ensure only one step at a time
        float3 mask;
        mask.x = float(sideDist.x <= sideDist.y && sideDist.x <= sideDist.z);
        mask.y = float(sideDist.y <  sideDist.x && sideDist.y <= sideDist.z);
        mask.z = float(sideDist.z <  sideDist.x && sideDist.z <  sideDist.y);

        sideDist += mask * deltaDist;
        voxelPos += int3(mask * rayStep);
        normal = -mask * rayStep;
    }

    pc.OutputAlbedoTex.Store(screenPos, float4(0.05, 0.05, 0.05, 1.0));
}
