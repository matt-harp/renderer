struct Vertex {
  float3 inPosition;
  float3 inColor;
  float2 uv;
};

struct PushConstants {
  float4x4 mvp;
  Vertex *buffer;
  uint *indices;
  uint texture_id;
  uint sampler_id;
}

[[push_constant]]
ConstantBuffer<PushConstants> pc;

[[vk::binding(0, 0)]]
Texture2D textures[];

[[vk::binding(1, 0)]]
SamplerState samplers[];

struct VSOutput {
  float4 pos : SV_Position;
  float3 color : COLOR;
  float2 uv: TEXCOORD;
};

[shader("vertex")]
VSOutput vertMain(uint vertexID: SV_VertexID) {
  VSOutput output;

  uint index = pc.indices[vertexID];
  Vertex v = pc.buffer[index];

  float4 localPos = float4(v.inPosition, 1.0);
  output.pos = mul(pc.mvp, localPos);
  // printf("z = %f", output.pos.z);
  output.color = v.inColor;
  output.uv = v.uv;

  return output;
}

[shader("fragment")]
float4 fragMain(VSOutput vertIn) : SV_TARGET {
  return textures[pc.texture_id].Sample(samplers[pc.sampler_id], vertIn.uv);
}
