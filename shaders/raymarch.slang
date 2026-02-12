import shaders.core;

struct DispatchParams {
    float4x4 InvProjMat;
    float3 CameraOrigin;
    ImageHandle2D OutputAlbedoTex;
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

// Unpacks 8-bit color to float4
float4 unpackColor(uint c) {
    return float4(
        float(c & 0xFF),
        float((c >> 8) & 0xFF),
        float((c >> 16) & 0xFF),
        float(c >> 24)
    ) / 255.0;
}

void GetPrimaryRay(int2 screenPos, out float3 rayPos, out float3 rayDir) {
	// nit: UV re-scaling and anti-alias jitter can be pre-baked in the matrix.
    float2 uv = (screenPos + 0.5) / float2(pc.OutputAlbedoTex.Instance.Size);
    uv = uv * 2 - 1;
    float4 far = mul(pc.InvProjMat, float4(uv, 1, 1));
    rayDir = normalize(far.xyz / far.w);
    rayPos = pc.CameraOrigin;
}

struct HitInfo {
	bool Hit;
}

[shader("compute")]
[numthreads(16, 16, 1)]
void main(uint2 screenPos : SV_DispatchThreadID) {
    if (any(screenPos >= pc.OutputAlbedoTex.Instance.Size)) return;

    float3 rayPos, rayDir;
    GetPrimaryRay(screenPos, rayPos, rayDir);
    pc.OutputAlbedoTex.Store(screenPos, float4(rayDir, 1.0));
}
