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

// ── Sky pass ───────────────────────────────────────────────────

struct SkyVertexOut {
    float4 position [[position]];
    float2 clipCoord;
};

vertex SkyVertexOut skyVertexShader(uint vid [[vertex_id]]) {
    float2 positions[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    SkyVertexOut out;
    out.position = float4(positions[vid], 0.9999, 1.0);
    out.clipCoord = positions[vid];
    return out;
}

fragment float4 skyFragmentShader(
    SkyVertexOut in [[stage_in]],
    const device FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]],
    texture2d<float> skyboxTex [[texture(TextureIndexSkybox)]],
    sampler texSampler [[sampler(0)]]
) {
    // Reconstruct view direction from clip coords via inverse VP
    float2 ndc = in.clipCoord;
    float4 clipNear = float4(ndc, 0.0, 1.0);
    float4 clipFar  = float4(ndc, 1.0, 1.0);
    float4 worldNear = frame.inverseViewProjectionMatrix * clipNear;
    float4 worldFar  = frame.inverseViewProjectionMatrix * clipFar;
    worldNear /= worldNear.w;
    worldFar  /= worldFar.w;
    float3 viewDir = normalize(worldFar.xyz - worldNear.xyz);

    // Equirectangular UV from world-space view direction
    float theta = atan2(viewDir.z, viewDir.x);
    float phi = asin(clamp(viewDir.y, -1.0, 1.0));
    float2 skyUV = float2(
        theta / (2.0 * M_PI_F) + 0.5,
        0.5 - phi / M_PI_F
    );

    float3 skyColor = skyboxTex.sample(texSampler, skyUV).rgb;
    return float4(skyColor, 1.0);
}

// ── Shadow pass ───────────────────────────────────────────────

vertex float4 shadowVertexShader(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device MazeVertex* vertices [[buffer(BufferIndexVertices)]],
    const device FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]],
    const device InstanceData* instances [[buffer(BufferIndexInstances)]]
) {
    const device MazeVertex& vert = vertices[vertexID];
    const device InstanceData& inst = instances[instanceID];
    float4 worldPos = inst.modelMatrix * float4(vert.position, 1.0);
    return frame.lightViewProjectionMatrix * worldPos;
}

// ── Scene pass ─────────────────────────────────────────────────

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
    const device FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]],
    texture2d_array<float> diffuseArray [[texture(TextureIndexDiffuseArray)]],
    texture2d_array<float> normalArray [[texture(TextureIndexNormalArray)]],
    depth2d<float> shadowMap [[texture(TextureIndexShadowMap)]],
    sampler texSampler [[sampler(0)]]
) {
    float3 lightDir = normalize(frame.lightDirection);
    float3 normal = normalize(in.worldNormal);

    // Half-Lambert: wraps light around geometry so no face goes fully dark
    float ndotl = dot(normal, lightDir);
    float halfLambert = ndotl * 0.5 + 0.5;
    halfLambert = halfLambert * halfLambert;

    float3 sunColor = float3(1.0, 0.95, 0.85);
    float3 skyAmbient = float3(0.35, 0.45, 0.65);

    // Shadow mapping — only for solid geometry, not fog
    float shadowFactor = 1.0;
    if (in.materialID != 4 && in.materialID != 5) {
        float4 lightClip = frame.lightViewProjectionMatrix * float4(in.worldPosition, 1.0);
        float3 lightNDC = lightClip.xyz;
        float2 shadowUV = lightNDC.xy * float2(0.5, -0.5) + 0.5;
        float currentDepth = lightNDC.z;

        if (shadowUV.x > 0.001 && shadowUV.x < 0.999 &&
            shadowUV.y > 0.001 && shadowUV.y < 0.999) {
            float bias = max(0.003, 0.008 * (1.0 - dot(normal, lightDir)));

            float shadow = 0.0;
            float2 texelSize = float2(1.0 / 1024.0);
            for (int x = -1; x <= 1; x++) {
                for (int y = -1; y <= 1; y++) {
                    float2 offset = float2(float(x), float(y)) * texelSize;
                    float closestDepth = shadowMap.sample(texSampler, shadowUV + offset);
                    shadow += (currentDepth - bias > closestDepth) ? 1.0 : 0.0;
                }
            }
            shadow /= 9.0;
            shadowFactor = 1.0 - shadow * 0.55;
        }
    }

    float3 color;
    float alpha = 1.0;
    float3 lighting;

    float seedF = float(in.styleSeed) * 0.0073;

    if (in.materialID == 1) {
        float height = in.localPosition.z;

        // Derive TBN from world normal for normal mapping
        float3 T, B;
        float3 absN = abs(normal);
        if (absN.z > absN.x && absN.z > absN.y) {
            T = float3(1, 0, 0); B = float3(0, 1, 0);
        } else if (absN.x > absN.y) {
            T = float3(0, 1, 0); B = float3(0, 0, 1);
        } else {
            T = float3(1, 0, 0); B = float3(0, 0, 1);
        }
        float3x3 TBN = float3x3(T, B, normal);

        // Sample textures
        float3 mossColor = diffuseArray.sample(texSampler, in.texCoord, 0).rgb;
        float3 mossN = normalArray.sample(texSampler, in.texCoord, 0).rgb * 2.0 - 1.0;
        float3 gravelColor = diffuseArray.sample(texSampler, in.texCoord, 1).rgb;
        float3 gravelN = normalArray.sample(texSampler, in.texCoord, 1).rgb * 2.0 - 1.0;
        float3 stoneColor = diffuseArray.sample(texSampler, in.texCoord, 2).rgb;
        float3 stoneN = normalArray.sample(texSampler, in.texCoord, 2).rgb * 2.0 - 1.0;

        // Orbit mode: stone base instead of gravel
        float camDist = length(frame.cameraPosition);
        float orbitBlend = smoothstep(3.0, 5.0, camDist);
        float3 baseColor = mix(gravelColor, stoneColor, orbitBlend);
        float3 baseN = mix(gravelN, stoneN, orbitBlend);

        float blend = smoothstep(0.02, 0.25, height);
        float3 texColor = mix(baseColor, mossColor, blend);
        float3 mapN = mix(baseN, mossN, blend);

        // Per-tile subtle tint variation
        float tileHue = fract(seedF * 1.618);
        texColor *= 1.0 + float3(-0.04, 0.06, -0.02) * tileHue;

        // Normal mapping
        float3 perturbedN = normalize(TBN * mapN);
        float bumpHL = dot(perturbedN, lightDir) * 0.5 + 0.5;
        bumpHL = bumpHL * bumpHL;
        lighting = skyAmbient * 0.25 + sunColor * 0.75 * bumpHL * shadowFactor;

        if (height > 0.05) {
            // Wall: darken near base
            float heightFade = smoothstep(0.05, 0.35, height);
            texColor *= 0.55 + 0.45 * heightFade;
        } else {
            // Floor: darken to add contrast, plus contact darkening near tile edges
            texColor *= 0.7;
            float2 edgePos = abs(in.localPosition.xy) / 0.48;
            float edgeDark = max(edgePos.x, edgePos.y);
            texColor *= 0.85 + 0.15 * (1.0 - smoothstep(0.7, 1.0, edgeDark));
        }

        color = texColor;
    } else if (in.materialID == 4 || in.materialID == 5) {
        // Volumetric fog layers — each layer is semi-transparent
        float t = frame.time * 0.3;
        float seedOff = float(in.styleSeed) * 0.01;
        // Use localPosition.z to offset each layer's cloud pattern
        float layerOff = in.localPosition.z * 7.13;
        float2 baseUV = in.texCoord * 3.0 + float2(t * 0.4 + seedOff + layerOff, t * 0.25 - layerOff * 0.5);

        float warpN = valueNoise(baseUV * 0.7 + float2(t * 0.15));
        float2 uv = baseUV + warpN * 0.4;

        float cloud = fbm(uv, 4);
        float cloud2 = fbm(uv * 1.5 + float2(t * 0.2, -t * 0.15) + 50.0, 3);
        float combined = cloud * 0.6 + cloud2 * 0.4;

        float3 faceTint = in.color.rgb;
        float3 fogBase = faceTint * 0.03;
        float3 fogHighlight = faceTint * 0.18;
        color = mix(fogBase, fogHighlight, combined);
        lighting = float3(1.0);

        // Base layer (z≈0) is fully opaque; upper layers for dissolve effect
        float heightFactor = 1.0 - smoothstep(0.0, 0.5, in.localPosition.z);
        float layerAlpha = (0.2 * combined + 0.12) * heightFactor;
        alpha = (in.localPosition.z < 0.01) ? 1.0 : layerAlpha;

        if (in.materialID == 5) {
            // Dissolve: reduce opacity for seen-but-unvisited rooms
            alpha *= 0.4;
            float dissolve = in.discoveryAmount;
            float threshold = cloud * 0.7 + 0.15;
            float dissolveAlpha = 1.0 - smoothstep(threshold - 0.15, threshold + 0.05, dissolve);
            dissolveAlpha *= (1.0 - smoothstep(0.85, 1.0, dissolve));
            alpha *= dissolveAlpha;

            float edgeDist = dissolve - threshold;
            float edgeGlow = (1.0 - smoothstep(0.0, 0.06, edgeDist)) * step(0.0, edgeDist);
            color += float3(0.3, 0.6, 1.0) * edgeGlow * 0.8;
        }
    } else if (in.materialID == 6) {
        // Player marker — bright red/orange with soft lighting
        color = in.color.rgb;
        lighting = skyAmbient * 0.5 + sunColor * 0.5 * halfLambert * shadowFactor;
    } else if (in.materialID == 7) {
        // Dark metallic cubie frame
        color = float3(0.06, 0.06, 0.08);
        float3 viewDir = normalize(frame.cameraPosition - in.worldPosition);
        float3 halfVec = normalize(lightDir + viewDir);
        float spec = pow(max(dot(normal, halfVec), 0.0), 48.0);
        lighting = skyAmbient * 0.2 + sunColor * 0.3 * halfLambert * shadowFactor + float3(spec * 0.25);
    } else if (in.materialID == 8) {
        // Corner / jamb posts — flat light green, lit and shadowed (M10 Phase B)
        color = in.color.rgb;
        lighting = skyAmbient * 0.3 + sunColor * 0.7 * halfLambert * shadowFactor;
    } else {
        color = in.color.rgb;
        lighting = skyAmbient * 0.25 + sunColor * 0.75 * halfLambert * shadowFactor;
    }

    color *= lighting * in.aoFactor;

    // Distance fog — greyscale textured, auto-adapts for FP vs orbit
    if (in.materialID != 4) {
        float dist = distance(in.worldPosition, frame.cameraPosition);
        float camFromCenter = length(frame.cameraPosition);
        float orbitFactor = smoothstep(3.0, 5.0, camFromCenter);
        float fogNear = mix(1.0, 4.0, orbitFactor);
        float fogFar = mix(3.5, 14.0, orbitFactor);
        float fogFactor = smoothstep(fogNear, fogFar, dist);

        float t = frame.time * 0.08;
        float2 fogUV = in.worldPosition.xy * 2.5 + float2(in.worldPosition.z * 1.3);
        float fogN1 = fbm(fogUV + float2(t * 0.5, -t * 0.3), 4);
        float fogN2 = fbm(fogUV * 1.8 + float2(-t * 0.3, t * 0.4) + 37.0, 3);
        float fogTex = fogN1 * 0.6 + fogN2 * 0.4;

        float3 nightHorizon = float3(0.04, 0.05, 0.08);
        float fogBrightness = mix(0.7, 1.3, fogTex);
        float3 fogColor = nightHorizon * fogBrightness;

        fogFactor *= (0.85 + 0.3 * fogTex);
        fogFactor = saturate(fogFactor);

        color = mix(color, fogColor, fogFactor);
    }

    return float4(color, alpha);
}
