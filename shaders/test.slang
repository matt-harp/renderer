struct Vertex {
  float3 inPosition;
  float3 inColor;
  float2 uv;
};

struct PushConstants {
  float4x4 mvp;
  Vertex *buffer;
  uint *indices;
}

[[push_constant]]
ConstantBuffer<PushConstants> pc;

[[vk::binding(0, 0)]]
Sampler2D texSampler;

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
  float4 color = texSampler.Sample(vertIn.uv);
  return color;
}
