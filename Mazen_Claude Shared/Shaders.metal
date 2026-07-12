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

// M11.2b: a fullscreen black overlay whose alpha ramps up then down across a world transition,
// so the swap fades rather than pops. Reuses the sky fullscreen triangle; blended over the scene.
fragment float4 fadeFragmentShader(
    SkyVertexOut in [[stage_in]],
    const device FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]]
) {
    return float4(0.0, 0.0, 0.0, frame.fadeAmount);
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

    float3 stars = skyboxTex.sample(texSampler, skyUV).rgb;

    // M9.5-1 dynamic sky. Day/night is local to the viewer's up — the face normal in first
    // person (via cameraUp), world-up in orbit — so each face gets its own sky, and the sun
    // glows in the daytime sky before fading back to the starfield at night.
    float3 sunDir = normalize(frame.lightDirection);
    float skyDay = smoothstep(-0.25, 0.20, dot(frame.cameraUp, sunDir));

    // Daytime gradient along the local up, warmed toward the sun.
    float up = clamp(dot(viewDir, frame.cameraUp) * 0.5 + 0.5, 0.0, 1.0);
    float3 daySky = mix(float3(0.60, 0.72, 0.86), float3(0.20, 0.42, 0.74), up * up);
    float sd = max(dot(viewDir, sunDir), 0.0);
    daySky += float3(1.0, 0.86, 0.58) * pow(sd, 8.0) * 0.5;                  // sun halo
    // Sunset: redden near the local horizon toward the sun when the sun sits low.
    float lowSun = 1.0 - smoothstep(0.0, 0.30, dot(frame.cameraUp, sunDir));
    float horizonBand = 1.0 - smoothstep(0.0, 0.30, abs(dot(viewDir, frame.cameraUp)));
    daySky = mix(daySky, float3(0.98, 0.46, 0.22), horizonBand * lowSun * sd * 0.7);

    // Night = stars; day = sky with stars faintly showing through (keeps the space identity).
    float3 skyColor = mix(stars, daySky + stars * 0.12, skyDay);
    return float4(skyColor, 1.0);
}

// ── M14b per-vertex inflation ─────────────────────────────────
// M19 relief height field — MUST stay byte-identical to CubeModel.reliefHeight (Swift). A smooth
// sum of sinusoids over the surface direction, range ≈ [-1,1]; continuous ⇒ seams stay continuous.
float m14bReliefHeight(float3 dir) {
    float a = sin(dir.x * 5.1 + dir.y * 2.3);
    float b = sin(dir.y * 4.7 - dir.z * 3.1);
    float c = sin(dir.z * 5.5 + dir.x * 2.9);
    return (a + b + c) / 3.0;
}

// Cube→sphere map (Cobb √) blended by roundness, then M19 relief pushed radially by `amp`.
// Matches CubeModel.inflatedUnitPoint (incl. the relief branch). amp == 0 ⇒ pure inflation.
float3 m14bInflate(float3 p, float r, float amp) {
    float x = p.x, y = p.y, z = p.z;
    float sx = x * sqrt(max(0.0, 1.0 - (y*y + z*z) * 0.5 + (y*y * z*z) / 3.0));
    float sy = y * sqrt(max(0.0, 1.0 - (z*z + x*x) * 0.5 + (z*z * x*x) / 3.0));
    float sz = z * sqrt(max(0.0, 1.0 - (x*x + y*y) * 0.5 + (x*x * y*y) / 3.0));
    float3 blended = mix(p, float3(sx, sy, sz), r);
    if (amp <= 0.0) return blended;
    float len = length(blended);
    if (len < 1e-5) return blended;
    return blended * (1.0 + amp * m14bReliefHeight(blended / len));
}

struct InflatedVertex { float3 position; float3 normal; float3 tangent; };

// Tile-local vertex → world. roundness == 0: exactly modelMatrix * position (spin pre-baked).
// roundness > 0: inflate the vertex FOOTPRINT (in-plane, height 0) onto the rounded surface in the
// rest frame, extrude by its height along the local curved normal, then apply spinMatrix. The
// footprint-then-extrude split keeps wall tops off the ill-conditioned √ map. (M14b.)
InflatedVertex m14bTransform(float3 localPos, float3 localNormal,
                             float4x4 modelMatrix, float4x4 spinMatrix,
                             float roundness, float invHalfExtent, float reliefAmplitude) {
    InflatedVertex o;
    float3x3 spin3 = float3x3(spinMatrix[0].xyz, spinMatrix[1].xyz, spinMatrix[2].xyz);
    if (roundness <= 0.0) {
        // Flat/rigid. Rigid instances bake spin into modelMatrix and pass spinMatrix = identity
        // (no-op here); the flat floor path passes an un-spun modelMatrix + spinMatrix = spin.
        float3 p = (modelMatrix * float4(localPos, 1.0)).xyz;
        o.position = (spinMatrix * float4(p, 1.0)).xyz;
        float3x3 nm = float3x3(modelMatrix[0].xyz, modelMatrix[1].xyz, modelMatrix[2].xyz);
        o.normal = normalize(spin3 * (nm * localNormal));
        o.tangent = normalize(spin3 * modelMatrix[0].xyz);
        return o;
    }
    float H = 1.0 / invHalfExtent;
    float3 footFlat = (modelMatrix * float4(localPos.x, localPos.y, 0.0, 1.0)).xyz;
    float h = localPos.z;
    float3 u = footFlat * invHalfExtent;
    float3 surf = m14bInflate(u, roundness, reliefAmplitude) * H;
    float3 tHat = normalize(modelMatrix[0].xyz);
    float3 bHat = normalize(modelMatrix[1].xyz);
    float eps = 0.5 * invHalfExtent;
    // Finite-difference the surface (relief included) so wall/prop normals follow the hills.
    float3 dT = m14bInflate(u + tHat * eps, roundness, reliefAmplitude) * H - surf;
    float3 dB = m14bInflate(u + bHat * eps, roundness, reliefAmplitude) * H - surf;
    float3 nInf = normalize(cross(dT, dB));
    if (dot(nInf, normalize(surf)) < 0.0) nInf = -nInf;
    float3 rightI = normalize(dT - nInf * dot(dT, nInf));
    float3 upI = cross(nInf, rightI);
    float3 posPreSpin = surf + nInf * h;
    float3x3 inflBasis = float3x3(rightI, upI, nInf);
    o.position = (spinMatrix * float4(posPreSpin, 1.0)).xyz;
    o.normal = normalize(spin3 * (inflBasis * localNormal));
    o.tangent = normalize(spin3 * rightI);
    return o;
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
    InflatedVertex xf = m14bTransform(vert.position, vert.normal, inst.modelMatrix,
                                      inst.spinMatrix, inst.roundness, inst.invHalfExtent, inst.reliefAmplitude);
    return frame.lightViewProjectionMatrix * float4(xf.position, 1.0);
}

// ── Scene pass ─────────────────────────────────────────────────

struct VertexOut {
    float4 position [[position]];
    float3 worldNormal;
    float3 worldTangent;   // M14b: inflated surface tangent, for curve-correct TBN
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

    // M14b: inflate per-vertex when this instance's roundness > 0 (flat/rigid otherwise).
    InflatedVertex xf = m14bTransform(vert.position, vert.normal, inst.modelMatrix,
                                      inst.spinMatrix, inst.roundness, inst.invHalfExtent, inst.reliefAmplitude);
    float4 worldPos = float4(xf.position, 1.0);
    float3 worldNormal = xf.normal;

    VertexOut out;
    out.position = frame.viewProjectionMatrix * worldPos;
    out.worldNormal = worldNormal;
    out.worldTangent = xf.tangent;
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
    texture2d<float> assetDiffuse [[texture(TextureIndexAssetDiffuse)]],
    sampler texSampler [[sampler(0)]]
) {
    float3 lightDir = normalize(frame.lightDirection);
    float3 normal = normalize(in.worldNormal);

    // Half-Lambert: wraps light around geometry so no face goes fully dark
    float ndotl = dot(normal, lightDir);
    float halfLambert = ndotl * 0.5 + 0.5;
    halfLambert = halfLambert * halfLambert;

    // Per-face day/night (M9.5-2), softened (M9.6-terminator): day/night runs off the surface's
    // *radial* direction — normalize(worldPosition) — instead of the discrete face normal, so the
    // terminator is a smooth band that sweeps the cube (and curves across each face near the edges)
    // rather than a hard line at the face seams. Still per-region (sun-facing bright, far side
    // dark); still the spun direction for free once the cube rotates.
    float3 surfDir = normalize(in.worldPosition);
    float dayFactor = smoothstep(-0.22, 0.22, dot(surfDir, lightDir));
    float moonUp = smoothstep(-0.15, 0.15, dot(surfDir, frame.moonDirection));
    // M9-7 eclipse: when the (nearer) moon aligns with the sun it blocks the sunlight, so the
    // lit faces suddenly darken — dramatic because the moon and sun share an apparent size.
    // M14b: warm/redden the surface sun as it nears the horizon, so sunrise/sunset read on the
    // ground (matching the sky's sunset band) — a story beat on the curved worlds. Slightly boost
    // intensity at grazing so the low sun keeps its drama despite the softened noon term.
    float lowSun = 1.0 - smoothstep(0.0, 0.35, frame.sunElevation);
    float3 sunTint = mix(float3(0.95, 0.92, 0.84), float3(1.05, 0.52, 0.26), lowSun * 0.85);
    float sunPunch = 1.0 + lowSun * 0.25;
    float3 sunColor = sunTint * sunPunch * dayFactor * (1.0 - frame.eclipseFactor);
    float3 dayAmbient = float3(0.35, 0.45, 0.65);
    float3 nightAmbient = float3(0.06, 0.08, 0.16);
    // M9-5 moonlight: a soft, cool, half-Lambert-wrapped directional light on the night side.
    float moonHL = dot(normal, frame.moonDirection) * 0.5 + 0.5;
    moonHL = moonHL * moonHL;
    float3 moonLight = float3(0.5, 0.58, 0.82) * (frame.moonIntensity * moonHL * (1.0 - dayFactor) * moonUp);
    // Eerie reddish twilight lingering on the day side during an eclipse.
    float3 eclipseGlow = float3(0.16, 0.05, 0.03) * (frame.eclipseFactor * dayFactor);
    // skyAmbient is finalized after the shadow block below, so the moonlight can take the
    // night shadow (M9-6) while the ambient and eclipse glow stay unshadowed.

    // Shadow mapping — skip fog (4/5) and posts (8). Posts are thin markers embedded
    // where walls meet, so receiving shadows makes their surface fight the wall depth
    // in the shadow map (hatching); they still cast shadows via the shadow pass.
    float shadowFactor = 1.0;
    if (in.materialID != 4 && in.materialID != 5 && in.materialID != 8) {
        float4 lightClip = frame.lightViewProjectionMatrix * float4(in.worldPosition, 1.0);
        float3 lightNDC = lightClip.xyz;
        float2 shadowUV = lightNDC.xy * float2(0.5, -0.5) + 0.5;
        float currentDepth = lightNDC.z;

        if (shadowUV.x > 0.001 && shadowUV.x < 0.999 &&
            shadowUV.y > 0.001 && shadowUV.y < 0.999) {
            float bias = max(0.0008, 0.0025 * (1.0 - dot(normal, lightDir)));

            float shadow = 0.0;
            float2 texelSize = float2(1.0 / 2048.0);
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

    // M9-6 moon shadows: the single shadow map follows the sun by day and the moon at night
    // (Renderer picks the light), so `shadowFactor` shadows whichever light is active. Only the
    // direct moonlight takes it here — the ambient and eclipse glow stay unshadowed.
    float3 skyAmbient = mix(nightAmbient, dayAmbient, dayFactor) + moonLight * shadowFactor + eclipseGlow;

    float3 color;
    float alpha = 1.0;
    float3 lighting;

    float seedF = float(in.styleSeed) * 0.0073;

    if (in.materialID == 1) {
        float height = in.localPosition.z;

        // M14b: TBN from the (inflated) surface tangent, Gram-Schmidt-orthogonalized against the
        // interpolated normal. Curve-correct and continuous — replaces the dominant-axis selection
        // that flipped mid-surface on a curved floor and swam the normal map.
        // Guard the degenerate case: an E/W wall's face normal lies ALONG the tile tangent, so the
        // passed tangent is ~parallel to the normal and the Gram-Schmidt collapses to ~0 →
        // normalize() → NaN → the wall rendered black (and jittered as the spin rotated the near-
        // parallel vectors). Fall back to a perpendicular reference axis when that happens.
        float3 tRef = in.worldTangent;
        if (abs(dot(normalize(tRef), normal)) > 0.99) {
            tRef = (abs(normal.z) < 0.99) ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
        }
        float3 T = normalize(tRef - normal * dot(tRef, normal));
        float3 B = cross(normal, T);
        float3x3 TBN = float3x3(T, B, normal);

        // Sample textures
        float3 mossColor = diffuseArray.sample(texSampler, in.texCoord, 0).rgb;
        float3 mossN = normalArray.sample(texSampler, in.texCoord, 0).rgb * 2.0 - 1.0;
        float3 gravelColor = diffuseArray.sample(texSampler, in.texCoord, 1).rgb;
        float3 gravelN = normalArray.sample(texSampler, in.texCoord, 1).rgb * 2.0 - 1.0;
        float3 stoneColor = diffuseArray.sample(texSampler, in.texCoord, 2).rgb;
        float3 stoneN = normalArray.sample(texSampler, in.texCoord, 2).rgb * 2.0 - 1.0;

        // Orbit mode: stone base instead of gravel (R2.11: camera-mode flag from the CPU — the old
        // smoothstep(3,5,camDist) proxy misread FP as orbit on larger cubes)
        float orbitBlend = frame.orbitBlend;
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
        // Softer sun so lit faces don't clip to silver-white and wash out the surface detail
        // (the day-side highlight was drowning the texture and hiding the form). Ambient lifted
        // to keep overall exposure roughly constant.
        lighting = skyAmbient * 0.35 + sunColor * 0.55 * bumpHL * shadowFactor;

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
    } else if (in.materialID == 9) {
        // Path-cross floor — warm paved stone, distinct from the surrounding ground (M10 Phase C)
        float3 stone = diffuseArray.sample(texSampler, in.texCoord, 2).rgb;
        color = stone * float3(1.25, 1.12, 0.9);
        lighting = skyAmbient * 0.3 + sunColor * 0.7 * halfLambert * shadowFactor;
    } else if (in.materialID == 11) {
        // M12-C: imported prop with its own diffuse texture, lit + shadowed like the maze.
        color = assetDiffuse.sample(texSampler, in.texCoord).rgb;
        lighting = skyAmbient * 0.3 + sunColor * 0.7 * halfLambert * shadowFactor;
    } else if (in.materialID == 12) {
        // Sun — emissive, unlit (M9). Kept out of the fog below so it stays bright.
        color = in.color.rgb;
        lighting = float3(1.0);
    } else if (in.materialID == 13) {
        // Moon — diffuse grey lit by the sun direction; the cube faces give clean phases
        // (sun-facing side bright, opposite dark). Faint ambient keeps the dark side visible. (M9)
        float moonHL = max(dot(normal, lightDir), 0.0);
        color = in.color.rgb;
        lighting = float3(0.03) + float3(1.05, 1.02, 0.95) * moonHL;
    } else if (in.materialID == 14) {
        // M19 grass — the moss/hedge texture recoloured to meadow green, lit + shadowed like a
        // floor, with a gentle per-tile hue drift so a whole field doesn't read as one flat sheet.
        float3 moss = diffuseArray.sample(texSampler, in.texCoord, 0).rgb;
        float luma = dot(moss, float3(0.299, 0.587, 0.114));
        float3 grass = mix(float3(0.22, 0.42, 0.16), float3(0.42, 0.66, 0.30), luma);
        float tileHue = fract(seedF * 1.618);
        grass *= 1.0 + float3(-0.05, 0.05, -0.06) * tileHue;
        color = grass;
        lighting = skyAmbient * 0.35 + sunColor * 0.6 * halfLambert * shadowFactor;
    } else if (in.materialID == 15) {
        // M19 water — flat blue with a soft specular sheen and a slow shimmer, no texture. Reads
        // as calm stream/pond; unwalkable in the sim, so it's the natural world's routing.
        float3 viewDir = normalize(frame.cameraPosition - in.worldPosition);
        float3 halfVec = normalize(lightDir + viewDir);
        float spec = pow(max(dot(normal, halfVec), 0.0), 40.0);
        float shimmer = 0.5 + 0.5 * sin(frame.time * 1.3 + in.worldPosition.x * 5.0 + in.worldPosition.y * 4.0);
        color = mix(float3(0.10, 0.28, 0.45), float3(0.16, 0.40, 0.58), shimmer);
        lighting = skyAmbient * 0.4 + sunColor * 0.4 * halfLambert * shadowFactor + float3(spec * 0.6);
    } else if (in.materialID == 16) {
        // M19 regolith — the moon's grey dust, fully procedural (Apollo-photo reference): a dusty
        // undulation, a finer grain over it, and a sparse speckle of brighter/darker pebbles, so
        // the ground reads gravelly and mottled rather than a flat grey sheet. Sampled in world
        // space so detail is continuous across tile seams (no per-tile repetition).
        float3 wp = in.worldPosition;
        float coarse = fbm(wp.xz * 0.6 + wp.yy * 0.3, 4);              // dusty undulation
        float fine   = fbm(wp.xy * 6.0 + wp.yz * 5.0, 3);             // grain
        float speck  = valueNoise(wp.xz * 22.0 + wp.yz * 19.0);       // tiny pebbles
        float pebble = smoothstep(0.72, 0.92, speck) * 0.20 - smoothstep(0.72, 0.92, 1.0 - speck) * 0.12;
        float tileHue = fract(seedF * 1.618);
        float shade = clamp(0.30 + 0.26 * coarse + 0.14 * fine + 0.09 * tileHue + pebble, 0.13, 0.9);
        color = float3(shade, shade, shade * 1.02);
        lighting = skyAmbient * 0.30 + sunColor * 0.72 * halfLambert * shadowFactor;
    } else {
        color = in.color.rgb;
        lighting = skyAmbient * 0.25 + sunColor * 0.75 * halfLambert * shadowFactor;
    }

    // Debug (M14): flat matte shading to read raw geometry. Simple Lambert on the *geometric*
    // face normal (not the normal-mapped one) over a neutral grey — flat-shaded facets make the
    // roundness/curvature legible without the texture, normal-map sparkle, or day/night wash. Skip
    // celestials, fog, and the player marker so only the maze surface is flattened.
    bool plainOverride = frame.plainShading > 0.5 &&
                         in.materialID != 4 && in.materialID != 5 &&
                         in.materialID != 12 && in.materialID != 13;
    if (plainOverride) {
        float lambert = max(dot(normal, lightDir), 0.0);
        color = float3(0.62) * (0.2 + 0.8 * lambert) * shadowFactor * in.aoFactor;
        return float4(color, alpha);
    }

    color *= lighting * in.aoFactor;

    // Distance fog — greyscale textured. Range comes size-derived from the CPU (R2.11): FP keeps
    // the historical 1→3.5 depth-cue; in orbit it starts beyond the cube's far corner, so the
    // planet reads clean while truly distant things (the counterpart sky-world) stay hazed.
    if (in.materialID != 4 && in.materialID != 12 && in.materialID != 13) {
        float dist = distance(in.worldPosition, frame.cameraPosition);
        float fogFactor = smoothstep(frame.fogNear, frame.fogFar, dist);
        // Sky objects — geometry beyond the local world's far corner (the counterpart world
        // hanging in the sky) — sit outside the local atmosphere: no fog, like the sun/moon
        // billboards (which are exempted by material above).
        if (dist > frame.skyDistance) { fogFactor = 0.0; }

        float t = frame.time * 0.08;
        float2 fogUV = in.worldPosition.xy * 2.5 + float2(in.worldPosition.z * 1.3);
        float fogN1 = fbm(fogUV + float2(t * 0.5, -t * 0.3), 4);
        float fogN2 = fbm(fogUV * 1.8 + float2(-t * 0.3, t * 0.4) + 37.0, 3);
        float fogTex = fogN1 * 0.6 + fogN2 * 0.4;

        // Fog follows the day/night cycle too, or it glows against a dark night sky.
        float3 nightHorizon = float3(0.04, 0.05, 0.08);
        float3 dayHorizon = float3(0.52, 0.58, 0.66);
        float3 horizon = mix(nightHorizon, dayHorizon, dayFactor);
        float fogBrightness = mix(0.7, 1.3, fogTex);
        float3 fogColor = horizon * fogBrightness;

        fogFactor *= (0.85 + 0.3 * fogTex);
        fogFactor = saturate(fogFactor);

        color = mix(color, fogColor, fogFactor);
    }

    return float4(color, alpha);
}
