[[vk::binding(2, 0)]] RWTexture2D<float4> drawImage;
[[vk::binding(3, 0)]] Texture3D<float4> volumeImage;

struct PushConstants {
    float4x4 invView;
    float4x4 invProj;
    float4x4 invModel;
};
[[vk::push_constant]] PushConstants pc;

// Helper: Standard Ray-Box Intersection
// Returns (tNear, tFar). If tNear > tFar, we missed.
float2 intersectAABB(float3 ro, float3 rd, float3 boxMin, float3 boxMax) {
    float3 tMin = (boxMin - ro) / rd;
    float3 tMax = (boxMax - ro) / rd;
    float3 t1 = min(tMin, tMax);
    float3 t2 = max(tMin, tMax);
    float tNear = max(max(t1.x, t1.y), t1.z);
    float tFar = min(min(t2.x, t2.y), t2.z);
    return float2(tNear, tFar);
}

[shader("compute")]
[numthreads(16, 16, 1)]
void main(uint3 dispatchID : SV_DispatchThreadID) {
    int2 texCoord = int2(dispatchID.xy);
    int2 size;
    drawImage.GetDimensions(size.x, size.y);

    if (texCoord.x >= size.x || texCoord.y >= size.y) return;

    // --- 1. RAY SETUP ---
    float2 uv = (float2(texCoord) / float2(size)) * 2.0 - 1.0; // NDC

    // Unproject: Screen Space -> View Space -> World Space -> Local Space
    float4 target = mul(pc.invProj, float4(uv.x, uv.y, 0.0, 1.0));
    float3 viewDir = target.xyz / target.w;
    
    float3 rayDirWorld = normalize(mul((float3x3)pc.invView, viewDir));
    float3 rayPosWorld = mul(pc.invView, float4(0, 0, 0, 1)).xyz;

    float3 rayDir = normalize(mul((float3x3)pc.invModel, rayDirWorld));
    float3 rayPos = mul(pc.invModel, float4(rayPosWorld, 1.0)).xyz;

    // Define the Volume Bounds in Local Space
    uint3 dim;
    volumeImage.GetDimensions(dim.x, dim.y, dim.z);
    float3 boxMin = float3(0, 0, 0);
    float3 boxMax = float3(dim.x, dim.y, dim.z);

    // --- 2. INTERSECTION CHECK ---
    float2 tBox = intersectAABB(rayPos, rayDir, boxMin, boxMax);
    float tNear = max(0.0, tBox.x);
    float tFar = tBox.y;

    float3 finalColor = float3(0.05, 0.05, 0.1); // Sky color

    // Only run DDA if we hit the box
    if (tNear < tFar) {
        // --- 3. DDA SETUP ---
        // Move ray start to the entry point of the volume (in local space)
        float3 volPos = rayPos + rayDir * tNear;

        // Current Voxel Coordinate
        int3 mapPos = int3(floor(volPos));

        // Ray Direction sign (+1 or -1)
        int3 step = int3(sign(rayDir));

        // Distance ray must travel to cross 1 unit in X/Y/Z
        float3 deltaDist = abs(1.0 / rayDir);

        // Distance to the NEXT boundary for X/Y/Z
        float3 sideDist;
        sideDist.x = (rayDir.x < 0) ? (volPos.x - mapPos.x) * deltaDist.x : (mapPos.x + 1.0 - volPos.x) * deltaDist.x;
        sideDist.y = (rayDir.y < 0) ? (volPos.y - mapPos.y) * deltaDist.y : (mapPos.y + 1.0 - volPos.y) * deltaDist.y;
        sideDist.z = (rayDir.z < 0) ? (volPos.z - mapPos.z) * deltaDist.z : (mapPos.z + 1.0 - volPos.z) * deltaDist.z;

        // Clamp mapPos to be inside just in case float precision put us slightly off
        mapPos = clamp(mapPos, int3(0), int3(dim) - 1);

        // --- 4. DDA LOOP ---
        // Max steps roughly equal to diagonal of volume
        for (int i = 0; i < 512; i++) {
            // Check if we are still inside the volume
            if (any(mapPos < 0) || any(mapPos >= int3(dim))) break;

            // Fetch Voxel Data (Integer Load)
            float4 voxel = volumeImage.Load(int4(mapPos, 0));

            // If opaque enough, we hit!
            if (voxel.a > 0.1) {
                // Calculate Normal based on which face we hit
                // (We know this from the last step taken, or by re-deriving sideDist)
                // Simple trick: The normal is -rayDir projected onto the dominant axis
                // But typically you track which axis 'step' happened last.
                // For visualization, let's just use the voxel color directly.

                // Add simple lighting (dot product with "up")
                float light = 0.5 + 0.5 * voxel.g; // Fake lighting
                finalColor = voxel.rgb;
                break;
            }

            // --- 5. STEP FORWARD ---
            // "Which axis is closest to a boundary?"
            if (sideDist.x < sideDist.y && sideDist.x < sideDist.z) {
                sideDist.x += deltaDist.x;
                mapPos.x += step.x;
            } else if (sideDist.y < sideDist.z) {
                sideDist.y += deltaDist.y;
                mapPos.y += step.y;
            } else {
                sideDist.z += deltaDist.z;
                mapPos.z += step.z;
            }
        }
    }

    drawImage[texCoord] = float4(finalColor, 1.0);
}
