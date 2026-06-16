#include <metal_stdlib>
#include <simd/simd.h>
#import "ShaderTypes.h"

using namespace metal;

// Simplex-like noise for fog
float hash2D(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash2D(i);
    float b = hash2D(i + float2(1, 0));
    float c = hash2D(i + float2(0, 1));
    float d = hash2D(i + float2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(float2 p, int octaves) {
    float value = 0.0;
    float amp = 0.5;
    for (int i = 0; i < octaves; i++) {
        value += amp * valueNoise(p);
        p *= 2.1;
        amp *= 0.5;
    }
    return value;
}

struct VertexOut {
    float4 position [[position]];
    float3 worldNormal;
    float3 worldPosition;
    float3 localPosition;
    float2 texCoord;
    float4 color;
    uint materialID;
    float discoveryAmount;
    uint styleSeed;
};

vertex VertexOut vertexShader(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device MazeVertex* vertices [[buffer(BufferIndexVertices)]],
    const device FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]],
    const device InstanceData* instances [[buffer(BufferIndexInstances)]]
) {
    const device MazeVertex& vert = vertices[vertexID];
    const device InstanceData& inst = instances[instanceID];

    float4 worldPos = inst.modelMatrix * float4(vert.position, 1.0);

    float3x3 normalMatrix = float3x3(
        inst.modelMatrix.columns[0].xyz,
        inst.modelMatrix.columns[1].xyz,
        inst.modelMatrix.columns[2].xyz
    );
    float3 worldNormal = normalize(normalMatrix * vert.normal);

    VertexOut out;
    out.position = frame.viewProjectionMatrix * worldPos;
    out.worldNormal = worldNormal;
    out.worldPosition = worldPos.xyz;
    out.localPosition = vert.position;
    out.texCoord = vert.texCoord;
    out.color = inst.baseColor;
    out.materialID = inst.materialID;
    out.discoveryAmount = inst.discoveryAmount;
    out.styleSeed = inst.styleSeed;
    return out;
}

fragment float4 fragmentShader(
    VertexOut in [[stage_in]],
    const device FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]]
) {
    float3 lightDir = normalize(float3(0.4, 0.8, 0.6));
    float ndotl = max(dot(in.worldNormal, lightDir), 0.0);
    float lighting = 0.3 + 0.7 * ndotl;

    float3 color;
    float alpha = 1.0;

    if (in.materialID == 1) {
        float height = in.localPosition.z;
        if (height > 0.1) {
            // Hedge wall with layered noise
            float3 hedgeBase = float3(0.28, 0.45, 0.22);
            float3 hedgeLight = float3(0.38, 0.55, 0.30);
            float n1 = valueNoise(in.worldPosition.xy * 8.0);
            float n2 = valueNoise(in.worldPosition.yz * 12.0 + 5.0);
            float blend = n1 * 0.6 + n2 * 0.4;
            color = mix(hedgeBase, hedgeLight, blend);
            // Darken near base of wall
            float heightFade = smoothstep(0.1, 0.4, height);
            color *= 0.7 + 0.3 * heightFade;
        } else {
            // Floor — sandy path with subtle variation
            float3 sandBase = float3(0.72, 0.62, 0.45);
            float3 sandDark = float3(0.60, 0.50, 0.35);
            float n = valueNoise(in.worldPosition.xz * 6.0 + 100.0);
            color = mix(sandDark, sandBase, n);
        }
    } else if (in.materialID == 4) {
        // Fog tile — animated clouds
        float t = frame.time * 0.3;
        float seedOff = float(in.styleSeed) * 0.01;
        float2 uv = in.texCoord * 3.0 + float2(t * 0.4 + seedOff, t * 0.25);

        float cloud = fbm(uv, 4);
        float cloud2 = fbm(uv * 1.5 + float2(t * 0.2, -t * 0.15) + 50.0, 3);
        float combined = cloud * 0.6 + cloud2 * 0.4;

        float3 fogLight = float3(0.85, 0.88, 0.92);
        float3 fogDark = float3(0.55, 0.58, 0.65);
        color = mix(fogDark, fogLight, combined);
        lighting = 0.7 + 0.3 * ndotl;
    } else if (in.materialID == 5) {
        // Dissolve fog overlay — burns away as discoveryAmount goes 0→1
        float t = frame.time * 0.3;
        float seedOff = float(in.styleSeed) * 0.01;
        float2 uv = in.texCoord * 3.0 + float2(t * 0.4 + seedOff, t * 0.25);
        float cloud = fbm(uv, 4);

        float3 fogLight = float3(0.88, 0.90, 0.95);
        float3 fogDark = float3(0.65, 0.68, 0.75);
        color = mix(fogDark, fogLight, cloud);

        // Noise-driven dissolve threshold
        float dissolve = in.discoveryAmount;
        float threshold = cloud * 0.7 + 0.15;
        alpha = 1.0 - smoothstep(threshold - 0.15, threshold + 0.05, dissolve);
        // Ensure fully gone at discovery=1
        alpha *= (1.0 - smoothstep(0.85, 1.0, dissolve));
        lighting = 0.7 + 0.3 * ndotl;
    } else if (in.materialID == 6) {
        // Player marker — bright red/orange
        color = in.color.rgb;
        lighting = 0.6 + 0.4 * ndotl;
    } else {
        color = in.color.rgb;
    }

    color *= lighting;
    return float4(color, alpha);
}
