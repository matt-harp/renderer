struct Vertex {
  float2 inPosition;
  float2 _padding;
  float3 inColor;
};

struct PushConstants {
	Vertex* buffer;
}

[[push_constant]] ConstantBuffer<PushConstants> pc;

struct VSOutput {
  float4 pos : SV_Position;
  float3 color;
};

[shader("vertex")]
VSOutput vertMain(uint vertexID: SV_VertexID) {
  VSOutput output;

  Vertex v = pc.buffer[vertexID];

  output.pos = float4(v.inPosition, 0.0, 1.0);
  output.color = v.inColor;

  return output;
}

[shader("fragment")]
float4 fragMain(VSOutput vertIn) : SV_TARGET { return float4(vertIn.color, 1.0); }
