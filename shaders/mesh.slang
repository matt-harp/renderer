#define GROUP_SIZE 32

import data;

struct TaskData {
  Meshlet* meshlets;
  uint meshlet_count;

  Instance* instances;
  uint32_t* instance_map;
  uint32_t* meshlet_map;
  uint instance_count;

  float3 camera_pos;

  FrustumPlane frustum_planes[6];
};

struct MeshletPayload {
  uint32_t instanceIndices[GROUP_SIZE];
  uint32_t meshletIndices[GROUP_SIZE];
};
groupshared MeshletPayload sPayload;

struct __PushConstants_Mesh {
  TaskData* taskData;
  MeshData* meshletData;
  uint64_t fragData;
};

[[vk::push_constant]] __PushConstants_Mesh __push_mesh;

struct MeshPipelineData<TTaskData = void,
                        TMeshletData = void,
                        TFragmentData = void> {
  property task : TTaskData* {
    [ForceInline] get { return (TTaskData*)__push_mesh.taskData; }
  }

  property meshlet : TMeshletData* {
    [ForceInline] get { return (TMeshletData*)__push_mesh.meshletData; }
  }

  property frag : TFragmentData* {
    [ForceInline] get { return (TFragmentData*)__push_mesh.fragData; }
  }
}

groupshared Atomic<uint32_t> visibleMeshletCount;

[shader("task")]
[numthreads(GROUP_SIZE, 1, 1)]
void taskMain(uint gtid : SV_GroupThreadID,
				uint dtid : SV_DispatchThreadID,
				uint gid : SV_GroupID,
			 	uniform MeshPipelineData<TaskData> data
) {
  uint32_t globalMeshlet = dtid.x;
  uint32_t totalMeshlets = data.task.instance_count * data.task.meshlet_count;

  if (gtid.x == 0) {
    visibleMeshletCount.store(0);
  }
  GroupMemoryBarrierWithGroupSync();

  if (globalMeshlet < totalMeshlets) {
    uint32_t instanceIndex = data.task.instance_map[globalMeshlet];
    uint32_t localMeshlet = data.task.meshlet_map[globalMeshlet];

    Instance instance = data.task.instances[instanceIndex];
    Meshlet meshlet = data.task.meshlets[instance.meshlet_offset + localMeshlet];
      
    // Transform to world space
    float3 worldCenter =
      mul(instance.model_matrix, float4(meshlet.bounding_sphere.xyz, 1.0)).xyz;
    float4 worldBounds = float4(worldCenter, meshlet.bounding_sphere.w);

    bool visible = true;

    // Frustum Cull
    bool frustumVisible = FrustumVisibilityPlanes(
      instance.model_matrix, meshlet.bounding_sphere, data.task.frustum_planes);
    visible &= frustumVisible;
    // if (!frustumVisible) {
    //   pushConstant.culledData.frustumCulled.add(1);
    // }

    // Backface cull from meshoptimizer.h
    // visible = dot(center - camera_position, cone_axis) >= cone_cutoff *
    // length(center - camera_position) + radius
    float3 worldConeAxis =
      normalize(mul((float3x3)instance.model_matrix, meshlet.cone_axis));
    float3 cameraToCenter = worldCenter - data.task.camera_pos.xyz;
    float centerDist = length(cameraToCenter);
    bool backfaceVisible =
      dot(cameraToCenter, worldConeAxis) <
      meshlet.cone_cutoff * centerDist + meshlet.bounding_sphere.w;
    visible &= backfaceVisible;
    // if (!backfaceVisible) {
    //   pushConstant.culledData.backfaceCulled.add(1);
    // }

    // todo: send back to show how many culled from imgui
    if (visible) {
      uint index = visibleMeshletCount.add(1);
      sPayload.instanceIndices[index] = instanceIndex;
      sPayload.meshletIndices[index] = localMeshlet;
    }
    // else {
    //   pushConstant.culledData->totalCulled.add(1);
    // }
  }

  GroupMemoryBarrierWithGroupSync();

  if (gtid.x == 0) {
    uint count = visibleMeshletCount.load();
    DispatchMesh(count, 1, 1, sPayload);
  }
}

struct MeshData {
  float4x4 viewProj;
  Instance* instances;
  Meshlet* meshlets;
  uint8_t* indices;
  uint* vertices;
  Vertex* mesh_vertices;
};

[shader("mesh")]
[outputtopology("triangle")]
[numthreads(32, 1, 1)]
void meshMain(in payload MeshletPayload payload,
         out vertices VertexOutput vertices[64],
         out indices uint3 triangles[128],
         uint3 gid : SV_GroupID,
         uint3 gtid : SV_GroupThreadID,
         uniform MeshPipelineData<void, MeshData> data
) {
  uint32_t instanceIndex = payload.instanceIndices[gid.x];
  uint32_t localMeshlet = payload.meshletIndices[gid.x];

  Instance instance = data.meshlet.instances[instanceIndex];
  Meshlet meshlet =
    data.meshlet.meshlets[instance.meshlet_offset + localMeshlet];

  float4x4 viewProj = data.meshlet.viewProj;
  uint hash =
    (instanceIndex * 40961u + localMeshlet) * 747796405u + 2891336453u;
  float3 color = float3((hash & 0xFF) / 255.0,
                        ((hash >> 8) & 0xFF) / 255.0,
                        ((hash >> 16) & 0xFF) / 255.0);

  SetMeshOutputCounts(meshlet.vertices_count, meshlet.triangle_count);
  uint32_t threadIndex = gtid.x;

  for (uint i = threadIndex; i < meshlet.vertices_count; i += GROUP_SIZE) {
    uint globalVertexIndex = data.meshlet.vertices[meshlet.vertices_offset + i];
    Vertex v = data.meshlet.mesh_vertices[globalVertexIndex];
    float4 worldPos = mul(instance.model_matrix, float4(v.position, 1.0));
    float4 clipPos = mul(viewProj, worldPos);
    vertices[i].position = clipPos;
    vertices[i].color = color;
  }

  for (uint i = threadIndex; i < meshlet.triangle_count; i += GROUP_SIZE) {
    uint triOffset = meshlet.triangle_offset + i * 3;
    triangles[i] = uint3(data.meshlet.indices[triOffset + 0],
                         data.meshlet.indices[triOffset + 1],
                         data.meshlet.indices[triOffset + 2]);
  }
}
