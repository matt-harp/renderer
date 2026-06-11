struct VertexOutput
{
  float4 position : SV_Position;
  float3 color : TEXCOORD0;
};

struct DummyPayLoad
{
    uint InstanceIndices[32];
    uint MeshletIndices[32];
};

struct Instance {
	float4x4 model_matrix;
	// offset in the global meshlet buffer
	uint meshlet_offset;
	uint meshlet_count;
	uint2 padding;
	float3 bounding_center;
	float bounding_radius;
}

struct Meshlet {
    float4 bounding_sphere;
    float3 cone_apex;
    float cone_cutoff;
    float3 cone_axis;
    uint vertices_offset;
    uint triangle_offset;
    uint16_t vertices_count;
    uint16_t triangle_count;
};

struct Vertex {
    float3 position;
};

struct SceneData {
    float4x4 viewProj;
    Vertex* mesh_vertices;
    Meshlet* meshlets;
    uint* vertices;
    uint8_t* indices;
    Instance* instances;
    uint meshlet_count;
    uint instance_count;
};

struct PushConstant {
    float4x4 model;
    SceneData* scene;
};

[[vk::push_constant]]
PushConstant pushConstant;

groupshared DummyPayLoad sPayload;

[shader("task")]
[numthreads(32, 1, 1)]
void taskMain(uint gtid : SV_GroupThreadID, uint dtid : SV_DispatchThreadID, uint gid : SV_GroupID)
{
	bool visible = false;

	uint instanceIndex = dtid / pushConstant.scene.meshlet_count;
	uint meshletIndex = dtid % pushConstant.scene.meshlet_count;

	if (instanceIndex < pushConstant.scene.instance_count && meshletIndex < pushConstant.scene.meshlet_count) {
		visible = true;
	}

	uint offset = WavePrefixCountBits(visible);
	if (visible) {
		sPayload.InstanceIndices[offset] = instanceIndex;
		sPayload.MeshletIndices[offset] = meshletIndex;
	}

	GroupMemoryBarrierWithGroupSync();

	uint visibleCount = WaveActiveCountBits(visible);

    DispatchMesh(visibleCount, 1, 1, sPayload);
}

[shader("mesh")]
[outputtopology("triangle")]
[numthreads(128, 1, 1)]
void meshMain(
    in payload DummyPayLoad payload,
    out vertices VertexOutput vertices[64],
    out indices uint3 triangles[128],
    uint3 DispatchThreadID : SV_DispatchThreadID,
    uint gid : SV_GroupID,
    uint gtid : SV_GroupThreadID
)
{
	Instance instance = pushConstant.scene.instances[payload.InstanceIndices[gid]];
    uint meshlet_index = payload.MeshletIndices[gid];

    Meshlet m = pushConstant.scene->meshlets[meshlet_index];
    SetMeshOutputCounts(m.vertices_count, m.triangle_count);

    if (gtid < m.triangle_count) {
        uint start = m.triangle_offset + (gtid * 3);
        triangles[gtid] = uint3(pushConstant.scene->indices[start], pushConstant.scene->indices[start+1], pushConstant.scene->indices[start+2]);
    }

    float4x4 mvp = mul(pushConstant.scene->viewProj, instance.model_matrix);
    if (gtid < m.vertices_count) {
        uint vert_idx = pushConstant.scene->vertices[m.vertices_offset + gtid];

        vertices[gtid].position = mul(mvp, float4(pushConstant.scene->mesh_vertices[vert_idx].position, 1.0));

        float3 color = float3(
            float(gid & 1),
            float(gid & 3) / 4.0,
            float(gid & 7) / 8.0);
        vertices[gtid].color = color;
    }
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input)
{
  return float4(input.color, 1.0);
}
