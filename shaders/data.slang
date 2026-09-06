struct Instance {
    float4x4 model_matrix;
    // offset and count into the global meshlet buffer for this instance's mesh
    uint meshlet_offset;
    uint meshlet_count;
    float4 bounding_sphere;
    uint8_t _padding[8];
};

struct Meshlet {
    float4 bounding_sphere;
    float3 cone_apex;
    float cone_cutoff;
    float3 cone_axis;
    uint vertices_offset;
    uint triangle_offset;
    uint vertices_count;
    uint triangle_count;
};

struct Vertex {
    float3 position;
};

struct FrustumPlane {
    float3 normal;
    float d;
}

bool FrustumVisibilityPlanes(float4x4 model_matrix, float4 bounding_sphere, FrustumPlane planes[]) {
    float3 center = mul(model_matrix, float4(bounding_sphere.xyz, 1.0)).xyz;

    float scale = max(max(length(model_matrix[0].xyz), length(model_matrix[1].xyz)), length(model_matrix[2].xyz));

    [unroll]
    for(int i = 0; i < 6; i++) {
        FrustumPlane plane = planes[i];
        float d = dot(plane.normal, center) + plane.d;
        if (d < -bounding_sphere.w * scale) {
            return false;
        }
    }

    return true;
}

struct VertexOutput
{
  float4 position : SV_Position;
  float3 color : TEXCOORD0;
};
