#include <metal_stdlib>
#include <simd/simd.h>
#import "ShaderTypes.h"

using namespace metal;

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
    float aoFactor;
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
    out.aoFactor = vert.aoFactor;
    return out;
}

fragment float4 fragmentShader(
    VertexOut in [[stage_in]],
    const device FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]]
) {
    float3 lightDir = normalize(frame.lightDirection);
    float3 normal = normalize(in.worldNormal);

    // Half-Lambert: wraps light around geometry so no face goes fully dark
    float ndotl = dot(normal, lightDir);
    float halfLambert = ndotl * 0.5 + 0.5;
    halfLambert = halfLambert * halfLambert;

    float3 color;
    float alpha = 1.0;
    float lighting;

    if (in.materialID == 1) {
        float height = in.localPosition.z;
        if (height > 0.1) {
            // Hedge wall — domain-warped 3-color palette
            float warp = valueNoise(in.worldPosition.xy * 3.0);
            float2 warped = in.worldPosition.xy + warp * 0.3;

            float3 dark    = float3(0.20, 0.32, 0.14);
            float3 mid     = float3(0.30, 0.48, 0.22);
            float3 bright  = float3(0.42, 0.58, 0.32);

            float n1 = valueNoise(warped * 6.0);
            float n2 = valueNoise(in.worldPosition.yz * 10.0 + 5.0);
            float blend = n1 * 0.6 + n2 * 0.4;

            if (blend < 0.5) {
                color = mix(dark, mid, blend * 2.0);
            } else {
                color = mix(mid, bright, (blend - 0.5) * 2.0);
            }

            // Fake bump: perturb normal by noise gradient for surface detail
            float eps = 0.02;
            float nGradX = valueNoise((warped + float2(eps, 0)) * 6.0) - n1;
            float nGradY = valueNoise((warped + float2(0, eps)) * 6.0) - n1;
            float3 bumpNormal = normalize(normal + float3(nGradX, nGradY, 0) * 2.5);
            float bumpHL = dot(bumpNormal, lightDir) * 0.5 + 0.5;
            bumpHL = bumpHL * bumpHL;
            lighting = 0.25 + 0.75 * bumpHL;

            // Darken near wall base
            float heightFade = smoothstep(0.1, 0.25, height);
            color *= 0.65 + 0.35 * heightFade;
        } else {
            // Sand/path floor — warm sand with fine sparkle
            float3 sandBase = float3(0.72, 0.62, 0.45);
            float3 sandDark = float3(0.60, 0.50, 0.35);
            float n = valueNoise(in.worldPosition.xz * 6.0 + 100.0);
            color = mix(sandDark, sandBase, n);

            // Fine-grain sparkle
            float sparkle = valueNoise(in.worldPosition.xz * 30.0 + 200.0);
            color += float3(0.04) * smoothstep(0.7, 0.95, sparkle);

            // Contact darkening near tile edges
            float2 edge = abs(in.texCoord - 0.5) * 2.0;
            float edgeDark = max(edge.x, edge.y);
            color *= 0.85 + 0.15 * (1.0 - smoothstep(0.7, 1.0, edgeDark));

            lighting = 0.25 + 0.75 * halfLambert;
        }
    } else if (in.materialID == 4) {
        // Fog tile — domain-warped animated clouds
        float t = frame.time * 0.3;
        float seedOff = float(in.styleSeed) * 0.01;
        float2 baseUV = in.texCoord * 3.0 + float2(t * 0.4 + seedOff, t * 0.25);

        float warpN = valueNoise(baseUV * 0.7 + float2(t * 0.15));
        float2 uv = baseUV + warpN * 0.4;

        float cloud = fbm(uv, 4);
        float cloud2 = fbm(uv * 1.5 + float2(t * 0.2, -t * 0.15) + 50.0, 3);
        float combined = cloud * 0.6 + cloud2 * 0.4;

        float3 fogLight = float3(0.85, 0.88, 0.92);
        float3 fogDark = float3(0.55, 0.58, 0.65);
        color = mix(fogDark, fogLight, combined);
        lighting = 0.6 + 0.4 * halfLambert;
    } else if (in.materialID == 5) {
        // Dissolve fog overlay — burns away with glowing edge
        float t = frame.time * 0.3;
        float seedOff = float(in.styleSeed) * 0.01;
        float2 uv = in.texCoord * 3.0 + float2(t * 0.4 + seedOff, t * 0.25);
        float cloud = fbm(uv, 4);

        float3 fogLight = float3(0.88, 0.90, 0.95);
        float3 fogDark = float3(0.65, 0.68, 0.75);
        color = mix(fogDark, fogLight, cloud);

        float dissolve = in.discoveryAmount;
        float threshold = cloud * 0.7 + 0.15;
        alpha = 1.0 - smoothstep(threshold - 0.15, threshold + 0.05, dissolve);
        alpha *= (1.0 - smoothstep(0.85, 1.0, dissolve));

        // Glowing edge at dissolve boundary
        float edgeDist = dissolve - threshold;
        float edgeGlow = (1.0 - smoothstep(0.0, 0.06, edgeDist)) * step(0.0, edgeDist);
        color += float3(0.3, 0.6, 1.0) * edgeGlow * 0.8;

        lighting = 0.6 + 0.4 * halfLambert;
    } else if (in.materialID == 6) {
        // Player marker — bright red/orange with soft lighting
        color = in.color.rgb;
        lighting = 0.5 + 0.5 * halfLambert;
    } else {
        color = in.color.rgb;
        lighting = 0.25 + 0.75 * halfLambert;
    }

    color *= lighting * in.aoFactor;
    return float4(color, alpha);
}
