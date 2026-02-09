import shaders.core;

[[vk::binding(2, 0)]] RWTexture2D<float4> drawImage;

struct SVONode {
    uint data;  // child_ptr or color
    uint masks; // valid_mask | leaf_mask << 8
};
[[vk::binding(3, 0)]] StructuredBuffer<SVONode> svoBuffer;

struct DispatchParams {
    float4x4 invView;
    float4x4 InvProjMat;
    float4x4 invModel;
    float3 CameraOrigin;
    TextureHandle2D OutputAlbedoTex;
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
    float2 uv = (screenPos + 0.5) / float2(drawImage.Size);
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
    int2 outputSize;
    drawImage.GetDimensions(outputSize.x, outputSize.y);
    if (any(screenPos >= outputSize)) return;

    float3 rayPosWorld, rayDirWorld;
    GetPrimaryRay(screenPos, rayPosWorld, rayDirWorld);


    // Transform to Model Space (where SVO is defined in [-1, 1])
    float3 rayDir = normalize(mul((float3x3)pc.invModel, rayDirWorld));
    float3 rayPos = mul(pc.invModel, float4(rayPosWorld, 1.0)).xyz;

    float3 finalColor = float3(0.05, 0.05, 0.1); // Background

    // --- SVO Traversal ---
    struct StackEntry {
        uint nodeIndex;
        float3 pos;
        float size;
    };

    // Intersect Root Box [-1, 1]
    float2 tBox = intersectAABB(rayPos, rayDir, float3(-1, -1, -1), float3(1, 1, 1));
    float tMin = max(0.0, tBox.x);
    float tMax = tBox.y;

    if (tMin < tMax) {
        // Fixed stack for SVO traversal
        // Depth 8-10 is sufficient for testing
        StackEntry stack[12];
        int stackPtr = 0;

        // Push Root
        stack[0].nodeIndex = 0;
        stack[0].pos = float3(0, 0, 0);
        stack[0].size = 2.0;
        stackPtr++;

        bool hit = false;
        while (stackPtr > 0 && !hit) {
            stackPtr--;
            StackEntry current = stack[stackPtr];

            // Check intersection with current node to be safe,
            // though logic guarantees we only push intersected nodes.
            // This re-check can handle near-plane clipping or precision issues if needed.

            SVONode node = svoBuffer[current.nodeIndex];
            uint masks = node.masks;
            uint validMask = masks & 0xFF;
            uint leafMask = (masks >> 8) & 0xFF;

            if (validMask == 0) continue;

            uint firstChild = node.data;
            float quarterSize = current.size * 0.25;

            float3 offsets[8] = {
                float3(-1, -1, -1), float3(1, -1, -1), float3(-1, 1, -1), float3(1, 1, -1),
                float3(-1, -1, 1), float3(1, -1, 1), float3(-1, 1, 1), float3(1, 1, 1)
            };

            // Determine traversal order based on ray direction to traverse Front-to-Back.
            int mask = 0;
            if (rayDir.x < 0) mask |= 1;
            if (rayDir.y < 0) mask |= 2;
            if (rayDir.z < 0) mask |= 4;

            // We want to POP the closest child first.
            // Stack is LIFO. So we PUSH the farthest child first.
            // The XOR sequence 0..7 ^ mask visits children in spatial order (e.g. 0 is min corner).
            // If we iterate i from 7 down to 0, and apply XOR, we process "Back-to-Front" relative to ray.

            for (int i = 7; i >= 0; i--) {
                int idx = i ^ mask;

                 // If child doesn't exist, skip
                 if ((validMask & (1 << idx)) == 0) continue;

                 // Calculate child index
                 // We count how many valid bits are before our bit index
                 uint childOffset = countbits(validMask & ((1 << idx) - 1));
                 uint childIndex = firstChild + childOffset;

                 float3 childPos = current.pos + offsets[idx] * quarterSize;

                 // Intersect Child
                 float2 tC = intersectAABB(rayPos, rayDir, childPos - quarterSize, childPos + quarterSize);

                 // If hit
                 if (tC.x <= tC.y && tC.y >= 0) {
                     if ((leafMask & (1 << idx)) != 0) {
                         // It is a leaf.
                         // Since we traverse front-to-back, the first leaf we pop is the hit.
                         SVONode leafNode = svoBuffer[childIndex];
                         finalColor = unpackColor(leafNode.data).rgb;
                         hit = true;
                         break;
                     } else {
                         // Internal Node -> Push
                         if (stackPtr < 12) {
                             stack[stackPtr].nodeIndex = childIndex;
                             stack[stackPtr].pos = childPos;
                             stack[stackPtr].size = current.size * 0.5;
                             stackPtr++;
                         }
                     }
                 }
            }
        }
    }

    drawImage[screenPos] = float4(finalColor, 1.0);
}
