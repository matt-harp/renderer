struct Vertex {
  float2 inPosition;
  float2 _padding;
  float3 inColor;
};

struct PushConstants {
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

  output.pos = float4(v.inPosition, 0.0, 1.0);
  printf("%d", index);
  output.color = v.inColor;

  return output;
}

[shader("fragment")]
float4 fragMain(VSOutput vertIn) : SV_TARGET {
  return float4(vertIn.color, 1.0);
}
