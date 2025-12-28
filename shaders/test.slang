struct Vertex {
  float3 inPosition;
  float3 inColor;
};

struct PushConstants {
  float4x4 mvp;
  Vertex *buffer;
  uint *indices;
}

[[push_constant]]
ConstantBuffer<PushConstants> pc;

struct VSOutput {
  float4 pos : SV_Position;
  float3 color;
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

  return output;
}

[shader("fragment")]
float4 fragMain(VSOutput vertIn) : SV_TARGET {
  return float4(vertIn.color, 1.0);
}
