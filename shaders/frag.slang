import data;

[shader("fragment")]
float4 fragmentMain(VertexOutput input)
{
  return float4(input.color, 1.0);
}
