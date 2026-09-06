#define GROUP_SIZE 32

import data;

struct TaskData {
  Meshlet *meshlets;
  uint meshlet_count;

  Instance *instances;
  uint instance_count;

  FrustumPlane frustum_planes[6];
};

struct MeshletPayload {
  uint32_t groupMeshletOffset;

  uint32_t meshletIndices[GROUP_SIZE];
};
groupshared MeshletPayload sPayload;

struct __PushConstants_Mesh {
  TaskData *taskData;
  MeshData *meshletData;
  uint64_t fragData;
};

[[vk::push_constant]]
__PushConstants_Mesh __push_mesh;

struct MeshPipelineData<TTaskData = void, TMeshletData = void,
                        TFragmentData = void> {
  property task : TTaskData * {
    [ForceInline]
    get { return (TTaskData *)__push_mesh.taskData; }
  }

  property meshlet : TMeshletData * {
    [ForceInline]
    get { return (TMeshletData *)__push_mesh.meshletData; }
  }

  property frag : TFragmentData * {
    [ForceInline]
    get { return (TFragmentData *)__push_mesh.fragData; }
  }
}

groupshared Atomic<uint32_t> visibleMeshletCount;

[shader("task")]
[numthreads(GROUP_SIZE, 1, 1)]
void taskMain(uint gtid: SV_GroupThreadID, uint dtid: SV_DispatchThreadID,
              uint gid: SV_GroupID, uniform MeshPipelineData<TaskData> data) {
  uint32_t groupMeshletOffset = (gid.x * GROUP_SIZE);
  uint32_t totalMeshlets = data.task.meshlet_count;

  // thread 0 populates shared information for mesh shader
  if (gtid.x == 0) {
    visibleMeshletCount.store(0);
    sPayload.groupMeshletOffset = groupMeshletOffset;
  }

  GroupMemoryBarrierWithGroupSync();

  // group thread count is only 64, will never exceed uint8
  uint8_t threadMeshletOffset = (uint8_t)gtid.x;
  uint groupMeshletCount = min(GROUP_SIZE, totalMeshlets - groupMeshletOffset);

  if (threadMeshletOffset < groupMeshletCount) {
    // uint32_t meshletIndex = groupMeshletOffset + threadMeshletOffset;
    // Meshlet meshlet = data.task.meshlets[meshletIndex];

    // // Transform to world space
    // float3 worldCenter = mul(data.task..modelMatrix,
    //                          float4(meshlet.meshletBoundingSphere.xyz, 1.0))
    //                          .xyz;
    // float4 worldBounds = float4(worldCenter,
    // meshlet.meshletBoundingSphere.w);

    bool visible = true;

    // Frustum Cull
    // FrustumVisibilityPlanes(meshlet)
    // bool frustumVisible = true;
    // for (uint i = 0; i < 6; i++) {
    //   float dist = dot(pushConstant.sceneData.frozenFrustum.planes[i].xyz,
    //                    worldBounds.xyz) +
    //                pushConstant.sceneData.frozenFrustum.planes[i].w;
    //   frustumVisible &= (dist >= -worldBounds.w);
    // }
    // visible &= frustumVisible;
    // if (!frustumVisible) {
    //   pushConstant.culledData.frustumCulled.add(1);
    // }

    // Backface cull from meshoptimizer.h
    // visible = dot(center - camera_position, cone_axis) >= cone_cutoff *
    // length(center - camera_position) + radius
    // float3 worldConeAxis =
    //     normalize(mul((float3x3)pushConstant.modelMatrix, meshlet.coneAxis));
    // float3 cameraToCenter =
    //     worldCenter - pushConstant.sceneData->frozenCameraWorldPos.xyz;
    // float centerDist = length(cameraToCenter);
    // bool backfaceVisible =
    //     dot(cameraToCenter, worldConeAxis) <
    //     meshlet.coneCutoff * centerDist + meshlet.meshletBoundingSphere.w;
    // visible &= backfaceVisible;
    // if (!backfaceVisible) {
    //   pushConstant.culledData.backfaceCulled.add(1);
    // }

    // todo: send back to show how many culled from imgui
    if (visible) {
      uint index = visibleMeshletCount.add(1);
      sPayload.meshletIndices[index] = threadMeshletOffset;
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
  Instance *instances;
  Meshlet *meshlets;
  uint8_t *indices;
  uint *vertices;
  Vertex *mesh_vertices;
};

[shader("mesh")]
[outputtopology("triangle")]
[numthreads(32, 1, 1)]
void meshMain(in payload MeshletPayload payload,
              out vertices VertexOutput vertices[64],
              out indices uint3 triangles[128],
              uint3 gid: SV_GroupID, uint3 gtid: SV_GroupThreadID,
              uniform MeshPipelineData<void, MeshData> data) {
  uint meshletIdx = payload.groupMeshletOffset +
                    payload.meshletIndices[gid.x];
  Meshlet meshlet = data.meshlet.meshlets[meshletIdx];
  float4x4 viewProj = data.meshlet.viewProj;

  uint hash = meshletIdx * 747796405u + 2891336453u;
  float3 color = float3((hash & 0xFF) / 255.0, ((hash >> 8) & 0xFF) / 255.0,
                        ((hash >> 16) & 0xFF) / 255.0);

  SetMeshOutputCounts(meshlet.vertices_count,
                      meshlet.triangle_count);
  uint32_t instanceIndex = gtid.x;
  for (uint i = instanceIndex; i < meshlet.vertices_count; i += GROUP_SIZE) {
    uint globalVertexIndex = data.meshlet.vertices[meshlet.vertices_offset + i];
    Vertex v = data.meshlet.mesh_vertices[globalVertexIndex];

    float4 worldPos = mul(data.meshlet.instances[0].model_matrix, float4(v.position, 1.0));
    float4 clipPos = mul(viewProj, worldPos);

    vertices[i].position = clipPos;
    vertices[i].color = color;
  }

  for (uint i = instanceIndex; i < meshlet.triangle_count;
       i += GROUP_SIZE) {
    uint triOffset = meshlet.triangle_offset + i * 3;

    uint idx0 = data.meshlet.indices[triOffset + 0];
    uint idx1 = data.meshlet.indices[triOffset + 1];
    uint idx2 = data.meshlet.indices[triOffset + 2];

    triangles[i] = uint3(idx0, idx1, idx2);
  }
}
