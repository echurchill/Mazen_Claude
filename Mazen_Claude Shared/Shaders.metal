#include <metal_stdlib>
#include <simd/simd.h>
#import "ShaderTypes.h"

using namespace metal;

/// Shortest distance from `p` to the line segment a→b. Used to draw the bond-band spine (material
/// 27) as a set of centre-to-edge segments, so one tile can carry a straight run, a corner, or a
/// junction from the same code.
inline float segmentDistance(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float t = saturate(dot(p - a, ab) / max(1e-6, dot(ab, ab)));
    return length(p - (a + ab * t));
}

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

// ── Volumetric cloud portal (original — Claude) ──────────────────────────────────
// OUR OWN raymarched volumetric clouds, in the *style* of "protean clouds" (the deformed-noise volume
// technique) but written from scratch on our valueNoise, so nothing is a port of licensed shader code.
// A short march through a domain-warped fbm density field that churns over time, with a cheap
// forward-scatter light term (silver lining) and a violet→cyan colour ramp. `uv` 0..1; `t` = frame.time.

// Signed billow field at a point, domain-warped so the volume churns/swirls (the "protean" motion).
// `oct` octaves — the renderer uses more for the visible density, fewer for the cheap shadow tap.
float cloudField(float3 p, float t, int oct) {
    p.xy += 0.55 * float2(sin(p.z * 0.8 + t * 0.40), cos(p.z * 0.7 - t * 0.35));   // churn
    float d = 0.0, amp = 0.55, freq = 1.0;
    for (int i = 0; i < oct; i++) {
        // pseudo-3D value noise: two orthogonal slices, the third axis shifting each.
        float n = valueNoise(p.xy * freq + float2(p.z * 0.9, -p.z * 0.6 + t * 0.10))
                + valueNoise(p.zx * freq + float2(p.y * 0.7 - t * 0.08, p.y * 0.5));
        d += amp * (n - 1.0);                         // sum≈[0,2] → signed ≈[-1,1]
        freq *= 2.05; amp *= 0.52;
    }
    return d;
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

// TEACHING TEXT. The only non-diegetic words in the game, so they are deliberately NOT dressed as
// an artifact of the world: this is the game speaking to the player, and pretending otherwise reads
// as neither. A wide transparent strip, drawn low and centred, over everything.
//
// The strip's own aspect is baked in (the texture is 8:1), so the quad is sized from that rather
// than measured per string — a short word simply occupies less of a transparent card.
fragment float4 promptFragmentShader(
    SkyVertexOut in [[stage_in]],
    const device FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]],
    texture2d<float> promptTex [[texture(TextureIndexPrompt)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    // Half-extents come from the CPU so the strip is drawn at exactly its own pixel size. Hard-coding
    // them magnified a 1024-wide texture across a Retina drawable — about 3x — which is why the first
    // version looked like a home computer from 1981 (Eddie). Type does not survive upscaling; thin,
    // wide-tracked type least of all.
    const float halfW = frame.promptHalfW, halfH = frame.promptHalfH;
    const float centreY = -0.74;                  // low, clear of the horizon and of the player
    float2 d = float2(in.clipCoord.x, in.clipCoord.y - centreY);
    if (abs(d.x) > halfW || abs(d.y) > halfH) discard_fragment();
    float2 uv = float2(d.x / halfW, -d.y / halfH) * 0.5 + 0.5;
    float4 t = promptTex.sample(s, uv);
    return float4(t.rgb, t.a * frame.promptOpacity);
}

// Triangular-PDF screen-space dither — breaks up 8-bit framebuffer banding on the smooth sky
// gradient without an HDR target. Applied per fragment (output resolution), so texture
// magnification can't average it away the way it does dither baked into the skybox image.
// PCG-style integer hash: true white noise. (A cheap fract(p*k) hash degrades into a periodic
// pattern at large screen coords — visible as faint screen-locked vertical bands.)
inline float skyHash(uint2 q) {
    uint n = q.x * 1597334677u ^ q.y * 3812015801u;
    n = (n ^ (n >> 16)) * 2246822519u;
    n = (n ^ (n >> 13)) * 3266489917u;
    n =  n ^ (n >> 16);
    return float(n) * (1.0 / 4294967296.0);
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

    // TPDF dither (1.0/255, textbook-minimum) at output resolution so the 8-bit target's ~1-LSB
    // steps dissolve — gated on the LOCAL GRADIENT so it only acts where a ramp actually exists.
    // fwidth is exactly 0 on flat black (a plain starfield's empty sky stays perfectly grain-free)
    // and non-zero across any ramp — nebula haze, the daytime sky — which is precisely where 8-bit
    // contour banding forms. This replaces the old skyDay gate, which couldn't tell a nebula night
    // sky (needs dither) from a clean starfield night sky (must not have it).
    float lum  = dot(skyColor, float3(0.299, 0.587, 0.114));
    float ramp = smoothstep(0.0, 6.0e-5, fwidth(lum));
    uint2 q = uint2(in.position.xy);
    float dither = (skyHash(q) - skyHash(q ^ uint2(0x9E3779B9u, 0x85EBCA6Bu))) * (1.0 / 255.0);
    skyColor += dither * ramp;

    return float4(skyColor, 1.0);
}

// ── M14b per-vertex inflation ─────────────────────────────────
// M19 relief height field — MUST stay byte-identical to CubeModel.reliefHeight (Swift). Rolling
// hills (sinusoids over the surface direction) + localized bowl dents with a subtle rim (craters
// on the moon / hollows on earth). Range clamped to [-1,1]; continuous ⇒ seams stay continuous.
float m14bReliefHeight(float3 dir) {
    float a = sin(dir.x * 5.1 + dir.y * 2.3);
    float b = sin(dir.y * 4.7 - dir.z * 3.1);
    float c = sin(dir.z * 5.5 + dir.x * 2.9);
    float h = (a + b + c) / 3.0 * 0.6;
    float3 centers[5] = { float3(0.30, 0.80, 0.50), float3(-0.60, 0.20, 0.77),
                          float3(0.55, -0.50, 0.67), float3(-0.25, -0.70, -0.67),
                          float3(0.80, 0.35, -0.49) };
    for (int i = 0; i < 5; i++) {
        float t = dot(dir, normalize(centers[i]));
        float bowl = -smoothstep(0.88, 1.0, t);
        float rim = 0.22 * smoothstep(0.855, 0.885, t) * (1.0 - smoothstep(0.885, 0.915, t));
        h += bowl * 0.75 + rim;
    }
    return clamp(h, -1.0, 1.0);
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

struct InflatedVertex { float3 position; float3 normal; float3 tangent; float3 surfacePos; };

// Tile-local vertex → world. roundness == 0: exactly modelMatrix * position (spin pre-baked).
// roundness > 0: inflate the vertex FOOTPRINT (in-plane, height 0) onto the rounded surface in the
// rest frame, extrude by its height along the local curved normal, then apply spinMatrix. The
// footprint-then-extrude split keeps wall tops off the ill-conditioned √ map. (M14b.)
InflatedVertex m14bTransform(float3 localPos, float3 localNormal,
                             float4x4 modelMatrix, float4x4 spinMatrix,
                             float roundness, float invHalfExtent, float reliefAmplitude,
                             float heightScale, float heightPivot) {
    InflatedVertex o;
    // M20: per-instance height animation (switch cap flush / cylinder grow). Applied to the local z
    // HERE — not baked into modelMatrix — so it can't corrupt the curved footprint/height split below.
    float hsc = heightScale <= 0.0 ? 1.0 : heightScale;   // 0 (zero-inited) ⇒ no-op
    localPos.z = heightPivot + (localPos.z - heightPivot) * hsc;
    float3x3 spin3 = float3x3(spinMatrix[0].xyz, spinMatrix[1].xyz, spinMatrix[2].xyz);
    if (roundness <= 0.0) {
        // Flat/rigid. Rigid instances bake spin into modelMatrix and pass spinMatrix = identity
        // (no-op here); the flat floor path passes an un-spun modelMatrix + spinMatrix = spin.
        float3 p = (modelMatrix * float4(localPos, 1.0)).xyz;
        o.position = (spinMatrix * float4(p, 1.0)).xyz;
        o.surfacePos = p;   // pre-spin → surface-fixed (for procedural ground texture)
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
    o.surfacePos = posPreSpin;   // pre-spin → surface-fixed (for procedural ground texture)
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
                                      inst.spinMatrix, inst.roundness, inst.invHalfExtent, inst.reliefAmplitude,
                                      inst.heightScale, inst.heightPivot);
    return frame.lightViewProjectionMatrix * float4(xf.position, 1.0);
}

// M20 — alpha-tested shadow variant, for imported sub-meshes whose diffuse is a cut-out (foliage).
// The plain shadow pass is depth-only, so cut-out leaves cast the shadow of their SOLID geometry —
// a leaf card throws a rectangle. These two carry the UV through and discard the same texels the
// scene pass does (material 20), so the shadow matches the silhouette you actually see.
struct ShadowCutoutOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex ShadowCutoutOut shadowCutoutVertexShader(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device MazeVertex* vertices [[buffer(BufferIndexVertices)]],
    const device FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]],
    const device InstanceData* instances [[buffer(BufferIndexInstances)]]
) {
    const device MazeVertex& vert = vertices[vertexID];
    const device InstanceData& inst = instances[instanceID];
    InflatedVertex xf = m14bTransform(vert.position, vert.normal, inst.modelMatrix,
                                      inst.spinMatrix, inst.roundness, inst.invHalfExtent, inst.reliefAmplitude,
                                      inst.heightScale, inst.heightPivot);
    ShadowCutoutOut out;
    out.position = frame.lightViewProjectionMatrix * float4(xf.position, 1.0);
    out.texCoord = vert.texCoord;
    return out;
}

fragment void shadowCutoutFragmentShader(
    ShadowCutoutOut in [[stage_in]],
    texture2d<float> assetDiffuse [[texture(TextureIndexAssetDiffuse)]],
    sampler texSampler [[sampler(0)]]
) {
    if (assetDiffuse.sample(texSampler, in.texCoord).a < 0.5) discard_fragment();
}

// ── Scene pass ─────────────────────────────────────────────────

struct VertexOut {
    float4 position [[position]];
    float3 worldNormal;
    float3 worldTangent;   // M14b: inflated surface tangent, for curve-correct TBN
    float3 worldPosition;
    float3 surfacePosition; // M19: pre-spin position — surface-fixed, for procedural ground texture
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
                                      inst.spinMatrix, inst.roundness, inst.invHalfExtent, inst.reliefAmplitude,
                                      inst.heightScale, inst.heightPivot);
    float4 worldPos = float4(xf.position, 1.0);
    float3 worldNormal = xf.normal;

    VertexOut out;
    out.position = frame.viewProjectionMatrix * worldPos;
    out.worldNormal = worldNormal;
    out.worldTangent = xf.tangent;
    out.worldPosition = worldPos.xyz;
    out.surfacePosition = xf.surfacePos;
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
    texture2d_array<float> leafTex [[texture(TextureIndexLeaf)]],
    texture2d_array<float> greeneryTex [[texture(TextureIndexGreenery)]],
    texture2d_array<float> treeTex [[texture(TextureIndexTreeSprite)]],
    texture2d_array<float> causticTex [[texture(TextureIndexCaustic)]],
    texture2d_array<float> dendriteTex [[texture(TextureIndexDendrite)]],
    texture2d_array<float> labelTex [[texture(TextureIndexLabel)]],
    texture2d_array<float> portalViewTex [[texture(TextureIndexPortalView)]],
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
                    // A shadow is only believed if its caster is NEAR — within a few tiles along
                    // the light ray. The single ortho map covers the whole cube, so without this a
                    // wall on +Z casts onto −Z straight through the world (Eddie: "shadows caused
                    // by the other faces should never show up given the nature of the worlds" —
                    // each face is its own land, and the fiction beats the optics). 3.5 units
                    // admits every same-face shadow (the tallest caster at a grazing sun) and
                    // rejects cross-face ones, whose gap is at least the world's diameter.
                    float gapWorld = (currentDepth - closestDepth) * frame.shadowDepthRange;
                    bool occluded = (currentDepth - bias > closestDepth) && gapWorld < 3.5;
                    shadow += occluded ? 1.0 : 0.0;
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

        // THE TURNABLE SLAB BREATHES (2026-08-07). `discoveryAmount` carries the pulse for this
        // material — it is otherwise unread here, whereas `in.color` genuinely is unread, which is
        // why tinting baseColor on the first attempt produced exactly nothing on screen.
        //
        // Brightened AND cooled: brightness alone reads as a patch of sunlight, and this has to say
        // "held, waiting". Floors only — every other material-1 instance passes 0 deliberately.
        if (in.discoveryAmount > 0.001) {
            float g = clamp(in.discoveryAmount, 0.0, 1.0);
            texColor = texColor * (1.0 + 0.30 * g) + float3(0.05, 0.09, 0.20) * g;
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
    } else if (in.materialID == 21) {
        // M16.6 — the Builder plinth. The mesh flags its parts via UV (texCoord): u >= 0 is the
        // disc's top face carrying the caustic glyph; u < 0 splits by v — the metallic body (v=-1)
        // vs the translucent disc rim (v=-2). `styleSeed` picks the symbol slice (Prop.state), so
        // one mesh + one material serves every plinth in the world.
        float3 amb = skyAmbient * 0.35 + sunColor * 0.65 * halfLambert * shadowFactor;
        if (in.texCoord.x >= 0.0) {
            float glyph = causticTex.sample(texSampler, in.texCoord, in.styleSeed % causticTex.get_array_size()).r;
            // The caustic is LIGHT, not paint: it ADDS over the translucent plate, so where no rays
            // land you still read the bluish resin underneath.
            float3 plate = float3(0.36, 0.52, 0.66);
            color = plate * amb * 0.7 + float3(0.35, 0.66, 1.00) * glyph * 2.1;   // the Builders' blue
            lighting = float3(1.0);                                                // already lit
        } else if (in.texCoord.y < -1.5) {
            // Translucent disc rim — a pale cyan resin, brightened + Fresnel-rimmed so it reads as
            // lit glass rather than a solid puck. (True alpha-blend translucency is a later pass.)
            float3 viewDir = normalize(frame.cameraPosition - in.worldPosition);
            float fres = pow(1.0 - saturate(dot(normal, viewDir)), 2.5);
            color = mix(float3(0.42, 0.60, 0.72), float3(0.70, 0.88, 1.0), fres);
            lighting = amb * 0.6 + float3(0.35);                                   // glassy, low-contrast
        } else {
            color = float3(0.52, 0.55, 0.60);                                      // grey metallic body
            lighting = amb;
        }
    } else if (in.materialID == 22) {
        // M16.6 Phase 2b — the alignment cylinder. UV flags (see addAlignmentCylinder):
        //   u≥2 → the SQUARE wrap (caustic slice 7), split into an upper/lower half that the align
        //         value (passed via discoveryAmount, 0=split → 1=whole) shears together;
        //   0≤u<2 → the top cap SWIRL (slice 5); u<0 → translucent resin.
        float3 amb = skyAmbient * 0.35 + sunColor * 0.65 * halfLambert * shadowFactor;
        const uint SQUARE = 7;                            // TextureLoader.CausticSymbol.square
        if (in.texCoord.x >= 2.0) {
            float align = saturate(in.discoveryAmount);
            float u01 = fract(in.texCoord.x - 2.0);      // 0…1 around the full circumference
            // Eddie: tile the band into THIRDS — the square lives in the middle third (front), the
            // other two thirds are blank PLATE (not bare metal), so it reads at ~1:1 instead of
            // stretched, and there's still no gap around the drum. The square's UPPER half (v<0.5)
            // shifts one tile over when unaligned and slides home as align→1 (the two-halves pivot).
            float shift = (in.texCoord.y < 0.5) ? (1.0 - align) * (1.0 / 3.0) : 0.0;
            float su = fract(u01 - shift);
            float g = 0.0;
            if (su >= 1.0 / 3.0 && su <= 2.0 / 3.0) {
                float2 uv = float2((su - 1.0 / 3.0) * 3.0, in.texCoord.y);
                g = causticTex.sample(texSampler, uv, SQUARE).r;
            }
            float3 plate = float3(0.36, 0.52, 0.66);
            color = plate * amb * 0.7 + float3(0.35, 0.66, 1.00) * g * 2.1;
            lighting = float3(1.0);
        } else if (in.texCoord.x >= 0.0) {
            // The cap's TOP glyph — the prop's own slice (swirl for the door cylinder, the number
            // for a switch), so one material serves both. `styleSeed` selects the slice.
            float g = causticTex.sample(texSampler, in.texCoord, in.styleSeed % causticTex.get_array_size()).r;
            float3 plate = float3(0.36, 0.52, 0.66);
            color = plate * amb * 0.7 + float3(0.35, 0.66, 1.00) * g * 2.1;
            lighting = float3(1.0);
        } else {
            float3 viewDir = normalize(frame.cameraPosition - in.worldPosition);
            float fres = pow(1.0 - saturate(dot(normal, viewDir)), 2.5);
            color = mix(float3(0.42, 0.60, 0.72), float3(0.70, 0.88, 1.0), fres);
            lighting = amb * 0.6 + float3(0.35);
        }
    } else if (in.materialID == 23) {
        // M20 (Eddie) — a portal's animated ENERGY field. Upgraded to a swirling VORTEX: technique
        // The swirl technique came from a BinBun Godot portal shader, reimplemented procedurally for
        // Metal (no textures, no Godot): differential rotation twisting harder toward the rim and
        // scrolling inward, which is what makes an edge read as depth. It now rings a circular
        // opening instead of filling an oval — see below. Emissive, cutout edges, no blend pass.
        float2 uv = in.texCoord;
        float tt = frame.time;
        float3 tint = in.color.rgb;
        {
            // THE PORTAL. One shape for every door in the game: a circular opening onto the place it
            // leads, ringed by a wormhole swirl, attached to no architecture at all — see
            // `TileMeshLibrary.addPortalDisc` for why the stonework went.
            //
            // `styleSeed` low byte is 5 when a captured VIEW exists; the slice rides the high bits.
            // Without one the swirl simply fills the disc, so a route nobody has photographed is a
            // wormhole rather than a hole in the world.
            uint slice = (in.styleSeed >> 8) & 0xFFFFu;
            bool hasView = (in.styleSeed & 0xFFu) == 5u;

            float2 d2 = uv - 0.5;
            float rad = length(d2) * 2.0;              // 0 centre … 1 rim
            if (rad > 1.0) discard_fragment();
            float ang = atan2(d2.y, d2.x);

            // ── the view, with parallax ───────────────────────────────────────
            float3 toEye = normalize(frame.cameraPosition - in.worldPosition);
            float3 n = normalize(in.worldNormal);
            float3 right = normalize(in.worldTangent - n * dot(n, in.worldTangent));
            float3 up = cross(n, right);
            float2 off = float2(dot(toEye, right), dot(toEye, up));
            const float depth = 0.16;
            // MINUS: standing left of a window you see more of the room's RIGHT side, because your
            // line of sight enters the opening and continues rightward (Eddie caught this inverted).
            float2 puv = clamp(uv - off * depth, 0.001, 0.999);
            float3 view = hasView
                ? portalViewTex.sample(texSampler, float2(puv.x, 1.0 - puv.y), slice).rgb
                : float3(0.0);

            // ── the wormhole rim: the outer 10% ───────────────────────────────
            // Differential rotation — the swirl twists harder toward the rim and scrolls inward —
            // so the edge reads as something being DRAWN THROUGH rather than a painted border.
            const float rimStart = 0.90;
            float rimT = smoothstep(rimStart, 1.0, rad);        // 0 at the view, 1 at the edge
            float twist = (1.0 - rad) * 6.0 - tt * 1.1;
            float swirl = 0.5 + 0.5 * sin(ang * 3.0 + twist * 2.0);
            float fib = fbm(float2(ang * 1.6 + tt * 0.15, rad * 5.0 - tt * 0.7), 3);
            float energy = pow(swirl, 1.6) * (0.45 + 0.9 * fib);
            float3 rimCol = tint * (0.35 + 1.6 * energy) + float3(0.62, 0.78, 1.0) * pow(energy, 3.0) * 0.8;

            // The two meet in the last tenth: the view does not stop at a line, it is drawn into the
            // swirl. Without the fade the rim reads as a frame, which is the thing we just removed.
            float3 body = hasView ? view : tint * (0.10 + 0.5 * energy);
            color = mix(body, rimCol, rimT);
            // A hair of the swirl over the whole face keeps the surface alive — it is a threshold,
            // not a photograph hung in the air.
            color += tint * energy * 0.05 * (1.0 - rimT);
            lighting = float3(1.0);                    // emissive: an opening is its own light
        }
    } else if (in.materialID == 24) {
        // M20 (Eddie) — a portal SIGNPOST. The board FACE (texCoord u >= 0) shows the rendered word(s)
        // from the label array (styleSeed = slice); the post + board back/edges (u < 0) are plain wood.
        // Lit like an ordinary matte prop so it reads as a physical sign in the world.
        float3 amb = skyAmbient * 0.35 + sunColor * 0.65 * halfLambert * shadowFactor;
        if (in.texCoord.x >= 0.0) {
            color = labelTex.sample(texSampler, in.texCoord, in.styleSeed % labelTex.get_array_size()).rgb;
        } else {
            color = float3(0.40, 0.28, 0.16);   // wood post / board back + edges
        }
        lighting = amb;
    } else if (in.materialID == 20) {
        // M20: imported sub-mesh whose diffuse carries alpha (Quaternius leaves/flowers) — cut it
        // out so foliage reads as leaves instead of solid quads. Otherwise identical to 11.
        float4 texel = assetDiffuse.sample(texSampler, in.texCoord);
        if (texel.a < 0.5) discard_fragment();
        color = texel.rgb;
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
        // M19 grass — low-frequency colour zones (sunny meadow ↔ deep forest floor) sampled in
        // surface space (pre-spin) so they stay glued to the ground as the world turns, plus fine
        // grain from the moss texture and a high-freq mottle. Living ground with patches.
        float3 wp = in.surfacePosition;
        float3 moss = diffuseArray.sample(texSampler, in.texCoord, 0).rgb;
        float luma = dot(moss, float3(0.299, 0.587, 0.114));
        float zone = fbm(wp.xz * 0.5 + wp.yy * 0.25, 3);              // meadow vs forest patches
        float3 meadow = float3(0.44, 0.60, 0.24);
        float3 forest = float3(0.16, 0.35, 0.15);
        float3 base = mix(forest, meadow, smoothstep(0.25, 0.75, zone));
        float mottle = fbm(wp.xy * 7.0 + wp.yz * 6.0, 3);            // fine blade grain
        color = base * (0.82 + 0.32 * luma) * (0.9 + 0.2 * mottle);
        lighting = skyAmbient * 0.35 + sunColor * 0.6 * halfLambert * shadowFactor;
    } else if (in.materialID == 15) {
        // M19 water — flat blue with a soft specular sheen and a slow shimmer, no texture. Reads
        // as calm stream/pond; unwalkable in the sim, so it's the natural world's routing.
        float3 viewDir = normalize(frame.cameraPosition - in.worldPosition);
        float3 halfVec = normalize(lightDir + viewDir);
        float spec = pow(max(dot(normal, halfVec), 0.0), 40.0);
        float shimmer = 0.5 + 0.5 * sin(frame.time * 1.3 + in.surfacePosition.x * 5.0 + in.surfacePosition.y * 4.0);
        color = mix(float3(0.10, 0.28, 0.45), float3(0.16, 0.40, 0.58), shimmer);
        lighting = skyAmbient * 0.4 + sunColor * 0.4 * halfLambert * shadowFactor + float3(spec * 0.6);
    } else if (in.materialID == 16) {
        // M19 regolith — the moon's grey dust, fully procedural (Apollo-photo reference): a dusty
        // undulation, a finer grain over it, and a sparse speckle of brighter/darker pebbles, so
        // the ground reads gravelly and mottled rather than a flat grey sheet. Sampled in world
        // surface space (pre-spin) so it stays glued to the ground as the moon turns.
        float3 wp = in.surfacePosition;
        float coarse = fbm(wp.xz * 0.6 + wp.yy * 0.3, 4);              // dusty undulation
        float fine   = fbm(wp.xy * 6.0 + wp.yz * 5.0, 3);             // grain
        float micro  = fbm(wp.xy * 16.0 + wp.yz * 14.0, 2);          // fine dust texture
        float speck  = valueNoise(wp.xz * 22.0 + wp.yz * 19.0);       // scattered pebbles
        float speck2 = valueNoise(wp.xy * 48.0 + wp.yz * 41.0);      // fine gravel grains
        float pebble = smoothstep(0.72, 0.92, speck) * 0.20 - smoothstep(0.72, 0.92, 1.0 - speck) * 0.12;
        float grit   = (smoothstep(0.78, 0.95, speck2) - smoothstep(0.78, 0.95, 1.0 - speck2)) * 0.07;
        float tileHue = fract(seedF * 1.618);
        float shade = clamp(0.30 + 0.24 * coarse + 0.12 * fine + 0.06 * micro + 0.08 * tileHue + pebble + grit, 0.12, 0.92);
        color = float3(shade, shade, shade * 1.02);
        lighting = skyAmbient * 0.30 + sunColor * 0.72 * halfLambert * shadowFactor;
    } else if (in.materialID == 37) {
        // THE SURVEYOR'S CRYSTAL BODY (Scene 5). It used to borrow the SUN's material (12), which
        // is UNLIT — `lighting = 1.0` — so every facet of a faceted crystal received exactly the
        // same value and the model collapsed into one flat pale silhouette (Eddie: "kind of washed
        // out"). Emissive was the right INTENT and the wrong implementation: a working machine
        // should glow, not stop being a solid.
        //
        // So it is lit like any prop FIRST — the facets earn their shading and the crystal reads as
        // a crystal — and the glow is ADDED on top, weighted toward the surface that faces AWAY
        // from the sun. That fills the shadowed side, which is the half that actually looked dead,
        // instead of blowing out the half the sun already handles. discoveryAmount carries the
        // glow (0 = idle machine, 1 = mid-pulse); it beats only while filigree is being grown.
        float4 texel = assetDiffuse.sample(texSampler, in.texCoord);
        color = texel.rgb * in.color.rgb;
        float glow = clamp(in.discoveryAmount, 0.0, 1.0);
        float away = 1.0 - max(dot(normal, lightDir), 0.0);
        lighting = skyAmbient * 0.30 + sunColor * 0.70 * halfLambert * shadowFactor
                 + float3(0.42, 0.66, 0.92) * glow * (0.30 + 0.70 * away);
    } else if (in.materialID == 36) {
        // THE SURVEYOR'S FILIGREE — fractal channel-light grown onto bare stone. styleSeed packs
        // (slice | quarter-turns << 8): the dendrite is authored entering from WEST, and the turns
        // point its entry at the parent channel tile. discoveryAmount is GROWTH: revealing
        // g <= growth grows the branch outward tip-first, with a bright working edge just behind
        // the front. color.r carries the parent trunk's liveness — dead trunk, dark filigree
        // ("thin dark cracks"), and deliberately SUBORDINATE to the channels at all times: this is
        // the machine's handwriting, not the puzzle.
        float2 uv = in.texCoord;
        uint turns = (in.styleSeed >> 8) & 3u;
        for (uint t = 0; t < turns; t++) { uv = float2(uv.y, 1.0 - uv.x); }
        float2 den = dendriteTex.sample(texSampler, uv, in.styleSeed & 0xFFu).rg;
        if (den.r < 0.05) discard_fragment();
        float growth = clamp(in.discoveryAmount, 0.0, 1.0);
        if (den.g > growth) discard_fragment();
        float tip = smoothstep(growth - 0.10, growth - 0.02, den.g);   // the edge being built now
        float live = in.color.r;
        float3 dry = float3(0.20, 0.21, 0.24);
        float3 lit = float3(0.55, 0.86, 1.00);
        float glow = clamp(live * 0.4 + frame.worldBloom * 0.5, 0.0, 1.0);
        color = mix(dry, lit, glow) * den.r + lit * tip * 0.5 * den.r;
        lighting = skyAmbient * 0.35 + sunColor * 0.3 * halfLambert * shadowFactor + glow * 0.4 + tip * 0.3;
    } else if (in.materialID == 35) {
        // SCENE 5's CIRCUIT FIXTURES — the source basin and the receiver bowls. Pale translucent
        // mineral that FILLS with the channels' own light from the bottom up: `discoveryAmount` is
        // the fill level (dark / 0.55 filling / 1.0 locked), and uv.y is each vertex's height
        // fraction, so the light has a real surface it rises past. A locked fixture also breathes
        // faintly in the source's rhythm, which is the visible half of "the tone joins the rhythm".
        float fill = clamp(in.discoveryAmount, 0.0, 1.0);
        float3 mineral = float3(0.62, 0.64, 0.66);
        float3 lit = float3(0.55, 0.86, 1.00);
        float below = smoothstep(fill + 0.03, fill - 0.06, in.texCoord.y);   // 1 under the fill line
        float breathe = fill >= 0.97 ? 0.08 * sin(frame.time * 2.6) : 0.0;
        // The 5J bloom lifts every fixture with the world.
        float glow = clamp(below * (0.35 + 0.65 * fill) + frame.worldBloom * 0.35 + breathe, 0.0, 1.0);
        color = mix(mineral, lit, glow);
        lighting = skyAmbient * 0.4 + sunColor * 0.45 * halfLambert * shadowFactor + glow * 0.55;
    } else if (in.materialID == 34) {
        // PALE STONE paving — Scene 5's surface. "Smooth pale stone, laid in wide slabs."
        // A facelet is ~19 m, so the 512-px sheet is repeated a few times across it to bring the
        // slabs to a walkable size rather than stretching one slab over the whole tile. The tone is
        // pushed slightly cool and its contrast pulled IN: the scene's one bright thing has to be
        // the channel, and a busy floor was what made the world read as a dark disco ball.
        float2 uv = in.texCoord * 3.0;
        float3 stone = diffuseArray.sample(texSampler, uv, 3).rgb;
        float3 mean = float3(0.72, 0.71, 0.70);
        stone = mix(mean, stone, 0.72) * float3(0.97, 0.99, 1.03);
        // Per-tile drift so a plain of identical slabs does not read as wallpaper.
        stone *= 0.94 + 0.12 * valueNoise(float2(seedF * 3.1, seedF * 7.7));
        float3 nrm = normalArray.sample(texSampler, uv, 3).rgb * 2.0 - 1.0;
        float bump = clamp(0.85 + 0.30 * nrm.z, 0.7, 1.1);
        color = stone * bump;
        lighting = skyAmbient * 0.34 + sunColor * 0.66 * halfLambert * shadowFactor;
        // 5J — "secondary channels catch reflected light, revealing the underlying grid and face
        // boundaries": during the bloom, every TILE boundary carries a faint line of the channels'
        // light, and the world reads as the diagram it always was. texCoord is 0…1 per tile here,
        // so the boundary is simply the frame of the uv square.
        if (frame.worldBloom > 0.001) {
            float2 tuv = in.texCoord;
            float edge = min(min(tuv.x, 1.0 - tuv.x), min(tuv.y, 1.0 - tuv.y));
            float line = smoothstep(0.035, 0.0, edge);
            color = mix(color, float3(0.55, 0.86, 1.00), line * frame.worldBloom * 0.45);
            lighting += line * frame.worldBloom * 0.3;
        }
    } else if (in.materialID == 38) {
        // THE PRESENTED FACE'S SEAM (see SceneBuilder). A line along the tile's OUTWARD edges —
        // the same four-bit mask the channels carry, read as edges rather than as spokes from the
        // centre. On a rounded world the six faces melt into one sphere, so this is the only thing
        // that says where the face you are about to turn begins and ends.
        //
        // Warm on purpose: the current is blue-white, and a selection that shares its colour reads
        // as part of the puzzle rather than as a control laid over it.
        float2 uv = in.texCoord;
        // Bit 4 ⇒ this is a BAND tile (the side of the turning slab): wash the whole tile rather
        // than lining its edges, so the moving body of the slab reads as one object.
        if (in.styleSeed & 16u) {
            float amount = clamp(in.discoveryAmount, 0.0, 1.0);
            float3 warm = float3(0.86, 0.62, 0.32);
            float3 stone = float3(0.52, 0.50, 0.47);
            color = mix(stone, warm, 0.55 * amount);
            lighting = skyAmbient * 0.55 + sunColor * 0.55 * halfLambert * shadowFactor;
            return float4(color * lighting, 1.0);
        }
        uint edges = in.styleSeed & 0xFu;
        float d = 1e9;
        if (edges & 1u) d = min(d, segmentDistance(uv, float2(0.0, 0.0), float2(1.0, 0.0)));
        if (edges & 2u) d = min(d, segmentDistance(uv, float2(1.0, 0.0), float2(1.0, 1.0)));
        if (edges & 4u) d = min(d, segmentDistance(uv, float2(0.0, 1.0), float2(1.0, 1.0)));
        if (edges & 8u) d = min(d, segmentDistance(uv, float2(0.0, 0.0), float2(0.0, 1.0)));
        // Wide enough to be a CONTINUOUS line at the miniature's size. The first pass was half
        // this and came out dashed — a border that breaks up reads as an artefact rather than as a
        // deliberate edge, which is the opposite of what a control wants to say.
        const float seamW = 0.10;
        if (d > seamW) discard_fragment();
        float core = smoothstep(0.045, 0.010, d);
        float halo = smoothstep(seamW, 0.048, d);
        float amount = clamp(in.discoveryAmount, 0.0, 1.0);
        // "A SLIGHT colorization" — a warm edge that says "this face", not a neon outline.
        float3 warm = float3(1.00, 0.72, 0.36);
        color = warm * (core * 0.62 + halo * 0.26) * amount;
        lighting = mix(skyAmbient * 0.5 + sunColor * 0.5 * halfLambert * shadowFactor,
                       float3(1.0), 0.7 * amount);
    } else if (in.materialID == 33) {
        // SCENE 5's CHANNELS — "veins carrying liquid light", laid in shallow grooves. Same spine as
        // a bond band (centre out to each edge the groove continues through), because they are the
        // same shape; styleSeed carries the mask, discoveryAmount says whether the current reaches
        // this tile.
        //
        // An UNLIT channel still draws, dark and dry. That is the scene's central image — "thin dark
        // cracks where channels have been rotated out of alignment" — and you cannot plan a repair
        // to a route you cannot see.
        float2 uv = in.texCoord;
        const float2 mid = float2(0.5, 0.5);
        uint links = in.styleSeed;
        float d = 1e9;
        if (links & 1u) d = min(d, segmentDistance(uv, mid, float2(0.5, 0.0)));
        if (links & 2u) d = min(d, segmentDistance(uv, mid, float2(1.0, 0.5)));
        if (links & 4u) d = min(d, segmentDistance(uv, mid, float2(0.5, 1.0)));
        if (links & 8u) d = min(d, segmentDistance(uv, mid, float2(0.0, 0.5)));
        // WIDTH. A facelet is ~18.9 m, so these are metres: the halo was 1.9 m each side — a 3.8 m
        // road, not a groove — and its lit core alone was as wide as the obelisk beside it is tall
        // is wrong for "veins". 0.062 puts the groove at ~2.3 m overall, about the width of a
        // receiver's base, which is the relation the two objects should have.
        const float haloW = 0.062;
        if (d > haloW) discard_fragment();
        float core = smoothstep(0.024, 0.006, d);
        float halo = smoothstep(haloW, 0.028, d);
        float live = clamp(in.discoveryAmount, 0.0, 1.0);
        // The current MOVES along the groove — keyed to world position so it flows across tiles
        // rather than restarting in each, and only when the channel is actually fed.
        float travel = fract(dot(in.worldPosition, float3(0.9, 0.9, 0.9)) - frame.time * 0.5);
        float flow = smoothstep(0.55, 1.0, 1.0 - abs(travel - 0.5) * 2.0) * live;

        // THE PULSE. Not a scroll: `discoveryAmount` is depth+1, so this tile knows how many channel
        // steps it is from the source, and `channelPulse` says which step the front has reached. The
        // envelope is therefore the real front — it arrives here when the current does, and stops
        // dead where the route stops, which is the whole of what Scene 5 teaches. The emitter that
        // carries the pulse's sound reads the same number, so they cannot drift apart.
        float depth = in.discoveryAmount - 1.0;
        float pulse = flow * 0.35;
        if (frame.channelPulse >= 0.0 && live > 0.5) {
            float ahead = frame.channelPulse - depth;
            // The diagnostic pulse (5C) is "slightly brighter" — the same front, more of it.
            pulse += exp(-ahead * ahead * 5.5) * (1.0 + frame.channelPulseBright * 0.8);
        }
        // 5J — the bloom: when the circuit locks, every groove floods to full for a few seconds,
        // then settles brighter than it began. Applied to `live` so dry-tile grooves stay dark —
        // "every channel that BELONGS TO THE COMPLETED CIRCUIT glows".
        live = max(live, frame.worldBloom * step(0.5, live));
        float3 dry  = float3(0.16, 0.17, 0.20);          // a groove cut in pale stone
        float3 lit  = float3(0.55, 0.86, 1.00);
        float3 tint = mix(dry, lit, live);
        // BRIGHTNESS. The lit core used to evaluate to ~1.85 in blue and ~1.1 in red, so both
        // clamped and the blue-white tint the scene asks for was thrown away — the groove rendered
        // as flat white paint and the travelling pulse was invisible, being extra brightness added
        // to something already at the ceiling. Keep the resting line UNDER 1.0 so it keeps its
        // colour, and let the pulse be the only thing that blows out.
        color = tint * (core * (0.50 + 0.45 * live) + halo * 0.32) + lit * pulse * 0.50 * core;
        // Dry channels take the world's light; a live one carries its own.
        float3 amb = skyAmbient * 0.4 + sunColor * 0.4 * halfLambert * shadowFactor;
        lighting = mix(amb, float3(1.0), live);
    } else if (in.materialID == 32) {
        // SCENE 3's WALLS — "a patchwork of metal cubes and rectangular blocks: dark iron, tarnished
        // brass, dull steel, oxidized copper, blackened alloy, occasional pale ceramic or crystalline
        // inserts… The blocks vary slightly in size and age, but all conform to the tile topology."
        //
        // Procedural rather than an atlas: there is no art to author, and every wall in the chamber
        // becomes a different piece of salvage. The block grid is deliberately IRREGULAR in one axis
        // — a straight grid reads as tiling, and the script wants "repaired, replaced, or accumulated
        // across enormous spans of time".
        float3 lp = in.localPosition;
        // Give every face its OWN 2D basis, taken from the local-space normal.
        //
        // Two goes at this failed for the same underlying reason: the pattern needs to know which
        // plane it is on, and both earlier attempts got that from something unstable. First the
        // WORLD normal — which the idle spin rotates, so walls flipped layout between frames while
        // the camera stood still. Then `lp.x + lp.y`, which is stable but DEGENERATE on a wall's end
        // cap: `along` barely varies across that little face, so the whole cap fell in one block
        // cell sitting on a floor() boundary and flipped colour with sub-pixel shifts as the player
        // turned (Eddie, three frames from one spot at slightly different angles).
        //
        // The local normal from screen-space derivatives of localPosition is exact for a flat face,
        // costs two instructions, and cannot rotate with the world — so the basis is per-face, never
        // degenerate, and frame-stable.
        float3 ln = normalize(cross(dfdx(lp), dfdy(lp)));
        float3 an = abs(ln);
        float2 uv = (an.x > an.y && an.x > an.z) ? lp.yz
                  : ((an.y > an.z) ? lp.xz : lp.xy);
        // Blocks are laid in courses, and each course is offset — masonry, not graph paper.
        float course = floor(uv.y * 9.0);
        float row = fract(uv.y * 9.0);
        float along = uv.x;
        float shift = fract(sin(course * 12.9898) * 43758.5453) * 0.5;
        float unit = floor(along * 6.0 + shift);
        float col = fract(along * 6.0 + shift);
        // One hash per block picks its metal and its age.
        float h = fract(sin(unit * 78.233 + course * 37.719) * 43758.5453);
        float h2 = fract(sin(unit * 12.111 + course * 91.7) * 24634.6345);
        float3 metalTint;
        if (h < 0.26)      metalTint = float3(0.20, 0.20, 0.23);   // dark iron
        else if (h < 0.44) metalTint = float3(0.42, 0.34, 0.17);   // tarnished brass
        else if (h < 0.62) metalTint = float3(0.34, 0.36, 0.38);   // dull steel
        else if (h < 0.78) metalTint = float3(0.24, 0.36, 0.31);   // oxidized copper
        else if (h < 0.94) metalTint = float3(0.14, 0.14, 0.16);   // blackened alloy
        else               metalTint = float3(0.68, 0.66, 0.62);   // pale ceramic insert
        // Age: some blocks are newer than their neighbours, which is the "repaired, replaced" read.
        metalTint *= 0.72 + 0.5 * h2;
        // SEAMS between blocks, and the deeper joint between courses.
        float seamA = smoothstep(0.0, 0.045, col) * smoothstep(1.0, 0.955, col);
        float seamB = smoothstep(0.0, 0.070, row) * smoothstep(1.0, 0.930, row);
        float seam = seamA * seamB;
        // RIVETS near the corners of the larger blocks.
        float2 rv = float2(fract(col * 2.0) - 0.5, fract(row * 2.0) - 0.5);
        float rivet = (h2 > 0.55) ? smoothstep(0.16, 0.09, length(rv)) : 0.0;
        float3 base = metalTint * (0.35 + 0.65 * seam) + metalTint * rivet * 0.45;
        // DORMANT LIGHT CHANNELS — "occasional", and dormant: they carry a trace, not a glow. The
        // chamber's real light is the orb, and these only hint that the walls once did more.
        float channel = (h > 0.90 && h2 < 0.34) ? smoothstep(0.46, 0.5, row) * smoothstep(0.54, 0.5, row) : 0.0;
        // 3I AFTER FOUR: "dormant light channels awaken across portions of the maze. The chamber
        // becomes easier to navigate." Not all of them — portions, so the hash decides which.
        float woken = smoothstep(0.55, 0.70, frame.chamberWoken) * step(0.55, h2);
        float3 amb = skyAmbient * 0.30 + sunColor * 0.35 * halfLambert * shadowFactor;
        // A tight specular so metal reads as metal under the orb's moving light rather than as stone.
        float3 viewDir = normalize(frame.cameraPosition - in.worldPosition);
        float3 halfV = normalize(viewDir + normalize(frame.lightDirection));
        float spec = pow(saturate(dot(normal, halfV)), 42.0) * (0.10 + 0.30 * h2) * seam;
        color = base;
        color += float3(0.30, 0.62, 0.72) * channel * (0.30 + 1.5 * woken);
        // 3J THE WAVE: "a wave of light travels outward from the orb… and across all six faces. The
        // wave reveals the full cube for a moment." A front expanding by distance from the centre,
        // which is the chamber's origin — so it genuinely sweeps outward through the room rather
        // than fading everything up together.
        if (frame.chamberWave > 0.0 && frame.chamberWave < 1.0) {
            float d = length(in.worldPosition);
            float front = frame.chamberWave * 9.0 - d;
            float pass = smoothstep(0.0, 0.5, front) * smoothstep(2.4, 0.6, front);
            color += float3(0.42, 0.68, 0.95) * pass * 0.85;
        }
        lighting = amb + float3(1.0) * spec;
    } else if (in.materialID == 30) {
        // SCENE 3's ORB — "from one angle it appears spherical. From another, its surface reveals
        // shifting crystalline planes. Fine internal structures rotate or refract independently,
        // suggesting depth greater than its external volume should contain."
        //
        // The geometry is a plain sphere on purpose: faceted GEOMETRY would freeze the shape, and
        // the script wants it to refuse classification. So the facets live here and MOVE — three
        // sets of planes rotating at unrelated rates, which is what stops the eye settling on a
        // solid. `discoveryAmount` is how many obelisks are lit, 0…1.
        float woken = clamp(in.discoveryAmount, 0.0, 1.0);
        float3 p = normalize(in.localPosition);
        float3 viewDir = normalize(frame.cameraPosition - in.worldPosition);
        float t = frame.time;
        // Three plane families, each turning about a different axis at its own rate. Their sum is
        // never periodic in any direction the player can watch for.
        float f1 = dot(p, normalize(float3(cos(t * 0.13), 0.6, sin(t * 0.13))));
        float f2 = dot(p, normalize(float3(sin(t * 0.081), cos(t * 0.081), 0.35)));
        float f3 = dot(p, normalize(float3(0.4, sin(t * 0.056), cos(t * 0.056))));
        // Quantise into facets — the bands ARE the crystalline planes.
        float facet = fract(f1 * 3.5) + fract(f2 * 2.75) + fract(f3 * 4.25);
        float planes = smoothstep(1.1, 1.9, facet) * 0.55 + smoothstep(2.1, 2.6, facet) * 0.45;
        // A rim that reads as a surface you cannot quite locate.
        float fres = pow(1.0 - saturate(dot(normal, viewDir)), 2.2);
        // "Initially the orb emits only a faint internal glow. Its light rises and falls slowly,
        // almost like breathing." The breath slows and deepens as the chamber wakes.
        // 3J: "the orb's internal facets accelerate. Its glow strengthens." The wave doubles the
        // rate while it passes, then the chamber settles darker for having been bright.
        float wave = frame.chamberWave > 0.0 ? sin(frame.chamberWave * 3.14159) : 0.0;
        float breath = 0.72 + 0.28 * sin(t * (0.55 + 0.35 * woken + 1.6 * wave));
        float3 cold = float3(0.30, 0.52, 0.72);
        float3 hot  = float3(0.72, 0.88, 1.00);
        float3 body = mix(cold, hot, woken * 0.75);
        // 3I AFTER THREE: "faint lines appear inside it, suggesting an incomplete internal
        // structure." Latitude lines that only resolve once half the chamber is lit — an interior
        // the orb was not showing you before.
        float inner = smoothstep(0.45, 0.62, woken)
                    * smoothstep(0.86, 1.0, abs(sin(p.y * 11.0 + t * 0.21)));
        color = body * (0.16 + 0.55 * planes) * breath
              + float3(0.55, 0.78, 1.00) * fres * (0.35 + 0.65 * woken)
              + body * woken * 0.30
              + float3(0.60, 0.82, 1.00) * inner * 0.35
              + float3(0.80, 0.93, 1.00) * wave * 0.55;
        lighting = float3(1.0);          // it is a light source, not a lit thing
    } else if (in.materialID == 31) {
        // SCENE 3's BEAM. "The beam is not perfectly steady. It pulses in slow intervals:
        // brightening → narrowing → dimming → brightening. Its rhythm should feel alive without
        // implying biological machinery."
        //
        // texCoord.y runs 0 at the obelisk to 1 at the orb end. The pulse travels ALONG it, and the
        // beam narrows as it brightens — done as an alpha cutout on the cross-section rather than by
        // scaling geometry, so all six stay one instanced draw.
        float along = in.texCoord.y;
        float across = abs(in.texCoord.x - 0.5) * 2.0;      // 0 centre … 1 edge
        float glow = clamp(in.discoveryAmount, 0.0, 1.0);
        float t = frame.time;
        // A BEAM DOES NOT CROSS A PORTAL (Eddie: "the beam from the orb looks like it is poking
        // through the portal… because it is"). Geometrically it does — the chamber's beams run from
        // its obelisks to the orb at the centre, and a door standing in that line is simply in the
        // way. Rather than move the door or shorten the beam by hand, the beam DIMS as it nears the
        // opening, which reads as the portal swallowing light that reaches it: the right story for a
        // hole in the world, and it costs one distance test against the portal light the renderer
        // already publishes every frame.
        // …except the 3K TARGETING beam (styleSeed 6), whose entire job is to touch the portal and
        // say "there". Fading that one is what made it stop short — the fix for the six broad beams
        // crossing a door, applied to the one beam that is supposed to arrive at it.
        if (frame.portalLightRadius > 0.0 && in.styleSeed != 6u) {
            float toPortal = distance(in.worldPosition, frame.portalLightPosition);
            glow *= smoothstep(frame.portalLightRadius * 0.45, frame.portalLightRadius * 1.05, toPortal);
            if (glow < 0.01) discard_fragment();
        }
        // 3K's TARGETING beam is styleSeed 6 — the seventh, after the six obelisk beams. "Narrow,
        // continuous, sharply directional, brighter at its point of contact": no pulse at all, and
        // it brightens toward the far end instead of tapering, because that end is the message.
        if (in.styleSeed == 6u) {
            float core = 1.0 - smoothstep(0.0, 0.62, across);
            if (core <= 0.001) discard_fragment();
            float contact = 0.55 + 1.35 * smoothstep(0.55, 1.0, along);
            color = float3(0.86, 0.95, 1.00) * core * contact;
            lighting = float3(1.0);
            return float4(color, 1.0);
        }
        // The cycle. One slow rhythm, offset along the beam so the whole length is never at once.
        // 3I AFTER TWO: "their rhythms begin to alternate." styleSeed carries the beam's index, so
        // each runs a half-cycle out of phase with its neighbour instead of six beams breathing as
        // one — which would read as a machine rather than as six separate things answering.
        float phase = float(in.styleSeed) * 1.04;
        float cycle = sin(t * 0.9 - along * 2.1 + phase);
        float bright = 0.55 + 0.45 * cycle;
        float width = 1.0 - 0.35 * bright;                   // brighter ⇒ narrower, per the script
        // 3J: "the six beams contract into narrower, brighter lines." Briefly, while the wave runs.
        float wave = frame.chamberWave > 0.0 ? sin(frame.chamberWave * 3.14159) : 0.0;
        width *= 1.0 - 0.55 * wave;
        bright += 1.1 * wave;
        if (across > width) discard_fragment();
        // Soft core, and a taper toward the orb end so the beam ARRIVES rather than stopping.
        float core = 1.0 - smoothstep(0.0, width, across);
        float taper = 1.0 - 0.35 * smoothstep(0.55, 1.0, along);
        float3 tint = mix(float3(0.36, 0.62, 0.95), float3(0.78, 0.92, 1.00), bright);
        color = tint * (0.35 + 1.05 * core) * bright * taper * glow;
        lighting = float3(1.0);
    } else if (in.materialID == 29) {
        // DUST (Scene 2). A pale mote lit by the sky, thinning to nothing as it settles. Cutout, not
        // alpha-blended: this is the opaque pass, so the fade is a screen-door dither on a hashed
        // position — the same trick the portal veils use. Cheap, order-independent, and at this size
        // the pattern is invisible; you read it as dust thinning, which is what it is.
        float2 sp = floor(in.position.xy);
        float noise = fract(sin(dot(sp, float2(12.9898, 78.233))) * 43758.5453);
        float life = clamp(in.discoveryAmount, 0.0, 1.0);
        if (noise > life) discard_fragment();
        // Round the square card off, so a mote is a speck and not a chip.
        if (length(in.texCoord - 0.5) > 0.5) discard_fragment();
        // Eddie could not find it at all: a grey speck against grey stone in the middle of a turning
        // world is invisible even when you know where to look. It now GLOWS — emissive, so it reads
        // in shadow and at night, brightest as it is shaken loose and cooling as it settles. Dust
        // that lights up is not physical, but this has a job: to say "the world just moved, HERE".
        float glow = life * life;                       // hottest at the moment it breaks free
        float3 ember = mix(float3(0.72, 0.70, 0.66), float3(1.00, 0.93, 0.72), glow);
        color = ember * (0.55 + 2.2 * glow);
        lighting = float3(1.0);                         // unlit: a mote should not go dark in shade
    } else if (in.materialID == 28) {
        // THE LAYERED VESSEL (Scene 4D). Smooth stone/ceramic with faint green-blue traces in the
        // grooves, three major rings each crossed by a narrow luminous seam, and the swirl on its cap.
        //
        // "The seams do not align vertically." Each ring holds one anchor's bond, and its seam turns
        // home as that anchor is released — so the vessel READS the lock, and reads it from across
        // the world, before the player knows what a bond is. `discoveryAmount` carries rings-aligned
        // 0…3 normalised to 0…1 (see Prop.anim); ring i is home once that count passes i.
        //
        // The body is a surface of revolution, so turning a ring and turning its SEAM look identical.
        // Drawing the seam here — rather than rotating geometry — is what lets three rings turn
        // independently off one static mesh and one float.
        float3 amb = skyAmbient * 0.35 + sunColor * 0.65 * halfLambert * shadowFactor;
        const uint SWIRL = 5;                             // TextureLoader.CausticSymbol.swirl
        float3 ceramic = float3(0.60, 0.60, 0.57);        // smooth, pale, faintly warm
        if (in.texCoord.x < 2.0) {
            // Top cap — the swirl, the MOTION glyph Scene 2 taught.
            // The swirl runs bright while the vessel demonstrates (4D beat 1) and keeps a low ember
            // once it has been read; baseColor.a carries that level.
            float g = causticTex.sample(texSampler, in.texCoord, SWIRL).r;
            float lit = clamp(in.color.a, 0.0, 1.0);
            color = ceramic * amb + float3(0.30, 0.72, 0.66) * g * (0.9 + 3.4 * lit);
            lighting = float3(1.0);
        } else {
            float ang   = fract(in.texCoord.x - 2.0);     // 0…1 once around, from the front seam
            float ring  = floor(in.texCoord.y);           // 0,1,2 = a major ring; 3 = plain body
            float local = fract(in.texCoord.y);           // height within the band
            // Authored misalignment per ring, in turns. Deliberately unequal and in opposite senses
            // so three seams never read as one pattern rotating — they read as three separate things
            // that have drifted, which is the point.
            const float3 restOffset = float3(0.31, -0.23, 0.14);
            float aligned = clamp(in.discoveryAmount, 0.0, 1.0) * 3.0;   // rings released, 0…3
            // Scene 4D beat 2 — while a twist is refused, the LEADING ring (the next one not yet
            // home) attempts to turn and springs back. Signed radians packed by SceneBuilder; the
            // seam angle is in turns, hence /2π. The ring nearly arrives and does not: the lock is
            // demonstrated by the object, with no message anywhere.
            float strainTurns = (float(in.styleSeed) / 2000.0 - 0.25) / 6.2831853;
            float leadRing = floor(aligned);
            float3 body = ceramic * amb;
            // Green-blue in the grooves: the band edges, where a real vase would hold its glaze.
            float groove = smoothstep(0.5, 0.0, abs(local - 0.5)) ;
            body = mix(body * 0.82 + float3(0.06, 0.15, 0.14), body, groove);
            if (ring < 2.5) {
                int i = int(ring);
                float home = clamp(aligned - float(i), 0.0, 1.0);        // 0 adrift … 1 home
                float seamAt = restOffset[i] * (1.0 - home);             // turns home as it releases
                // The leading ring strains harder than the body it sits in (which is already turning
                // with the whole vessel), so the attempt reads as THIS ring trying, not the vase.
                if (float(i) == leadRing) seamAt += strainTurns * 2.5;
                float d = abs(fract(ang - seamAt + 0.5) - 0.5);          // angular distance, wrapped
                float coreW = 0.008, haloW = 0.030;
                float core = smoothstep(coreW, 0.0, d);
                float halo = smoothstep(haloW, 0.0, d);
                // A seam is a slot in the body, so it dims the ceramic before it lights.
                body *= 1.0 - 0.45 * halo;
                // Cool blue-green while adrift, warming to gold as it comes home — the same
                // vocabulary the bond bands use, so the two objects are visibly talking about the
                // same thing.
                float3 adriftC = float3(0.34, 0.78, 0.74);
                float3 homeC   = float3(1.00, 0.82, 0.34);
                float3 seamC   = mix(adriftC, homeC, home);
                // Faint breathing while adrift; steady once home (motion means "unresolved").
                float breathe = 1.0 - 0.18 * (1.0 - home) * (0.5 + 0.5 * sin(frame.time * 1.7 + float(i) * 2.1));
                color = body + seamC * (core * 1.7 + halo * 0.5) * breathe;
                // The seam is emissive, the ceramic around it is not: blend toward unlit by how much
                // of this pixel is actually seam, so a lit slot doesn't wash out the whole band.
                float lit = max(core, halo * 0.5);
                lighting = float3(1.0) * (0.35 + 0.65 * lit) + amb * (1.0 - lit);
            } else {
                color = body;
                lighting = float3(1.0);
            }
        }
    } else if (in.materialID == 27) {
        // BOND BAND — a luminous seam set into the ground, tracing what holds the world rigid.
        // `discoveryAmount` carries the refusal flare: while a twist strains against this bond the
        // band runs hot, which is what turns a refusal from a dead end into information.
        // The seam is drawn as a SPINE from the tile centre out to each edge the band continues
        // through (`styleSeed`, N=1 E=2 S=4 W=8 — see SceneBuilder.bandLink), so a run reads as one
        // line, a corner turns, and a junction joins. Everything off the spine is DISCARDED, leaving
        // the ground it is set into visible: this quad is an overlay on the world, not a floor of its
        // own. (It used to paint the whole tile, so every pixel away from the stripe came out black —
        // a run of bonds read as black tiles with a white line through them. It also assumed uv ran
        // 0…1 while the shared grass mesh bakes in `uvScale`, which put the line off-centre; the band
        // now uses `bandFloor`, whose UVs really are normalised.)
        float2 uv = in.texCoord;
        const float2 mid = float2(0.5, 0.5);
        uint links = in.styleSeed;
        float d = 1e9;
        if (links & 1u) d = min(d, segmentDistance(uv, mid, float2(0.5, 0.0)));   // north (v=0)
        if (links & 2u) d = min(d, segmentDistance(uv, mid, float2(1.0, 0.5)));   // east  (u=1)
        if (links & 4u) d = min(d, segmentDistance(uv, mid, float2(0.5, 1.0)));   // south (v=1)
        if (links & 8u) d = min(d, segmentDistance(uv, mid, float2(0.0, 0.5)));   // west  (u=0)
        if (links == 0u) d = length(uv - mid);          // a lone bonded tile: a full stop, not a line
        const float haloW = 0.11;
        if (d > haloW) discard_fragment();              // the ground shows through everywhere else
        float core = smoothstep(0.045, 0.012, d);
        float halo = smoothstep(haloW, 0.03, d);
        // Travelling pulse: keyed to WORLD position, not tile UV, so the bead flows along a run
        // instead of restarting inside every tile. Slow — it should read as something under tension.
        float travel = fract(dot(in.worldPosition, float3(0.7, 0.7, 0.7)) - frame.time * 0.22);
        float bead = smoothstep(0.72, 1.0, 1.0 - abs(travel - 0.5) * 2.0);

        float flare = clamp(in.discoveryAmount, 0.0, 1.0);
        float3 cold = float3(0.42, 0.72, 0.95);          // held
        float3 hot  = float3(1.00, 0.36, 0.16);          // straining
        float3 tint = mix(cold, hot, flare);

        color = tint * (core * 1.5 + halo * 0.45 + bead * 0.8 * core);
        // Emissive: a seam of light does not wait for the sun.
        lighting = float3(1.0) * (0.55 + 0.45 * flare) + skyAmbient * 0.15;
    } else if (in.materialID == 26) {
        // AWAKENING OBELISK. `discoveryAmount` is the activation level 0→1, and the light climbs the
        // shaft with it: pale stone below the front, a bright leading edge, and a lit, faintly
        // pulsing column behind. Script (Scene 2H): "A line of light appears at the base of the left
        // obelisk. It climbs toward the tip." The same material serves Scene 3's six obelisks, whose
        // activation is the identical gesture.
        float tipH = 1.16;                                   // matches addObelisk's tip height
        float h = clamp(in.localPosition.z / tipH, 0.0, 1.0);
        float level = clamp(in.discoveryAmount, 0.0, 1.0);

        float3 stone = float3(0.62, 0.60, 0.55);             // the dormant obelisk's colour
        float3 lit   = float3(0.55, 0.80, 1.00);             // cold Builder light

        // Behind the front: lit, with a slow breathing pulse so it reads alive, not painted.
        float pulse = 0.85 + 0.15 * sin(frame.time * 2.2 - h * 6.0);
        float below = smoothstep(level, level - 0.06, h);     // 1 under the front, 0 above it
        // The front itself — a bright narrow band riding the boundary.
        float edge = exp(-pow((h - level) / 0.035, 2.0)) * step(0.001, level) * step(level, 0.999);

        float3 base = mix(stone, lit * pulse, below * 0.85);
        color = base + lit * edge * 1.6;
        // Emissive-leaning: the lit portion should carry its own glow rather than depend on the sun.
        lighting = skyAmbient * 0.35 + sunColor * 0.55 * halfLambert * shadowFactor
                 + float3(0.55, 0.75, 1.0) * (below * 0.35 + edge * 0.9);
    } else if (in.materialID == 25) {
        // Riveted PLATING (Eddie, ref: weathered steel bridge plate) — the exposed shell of a slab
        // that turns, so it reads as built structure rather than lawn. One facelet per cubie is a
        // ~19 m rectangle, far too coarse to read as metal on its own, so each tile is subdivided
        // into panels; every panel picks its own tone and weathering, giving the "multiple bits of
        // metal" look. Deliberately generic: Scene 3's interior is specified in the same language
        // ("dark iron, tarnished brass, dull steel, oxidized copper"), so this is written to be its
        // material too rather than a Scene 2 one-off.
        float2 uv = in.texCoord;
        float2 panels = float2(3.0, 2.0);                 // panels per tile — ~6 m plates
        float2 g = uv * panels;
        float2 pid2 = floor(g), f = fract(g);
        float pid = valueNoise(pid2 * 7.31 + seedF * 13.0);

        float3 iron  = float3(0.26, 0.27, 0.30);          // dark iron
        float3 steel = float3(0.40, 0.44, 0.49);          // dull blue steel
        float3 oxide = float3(0.36, 0.29, 0.24);          // rust / tarnish
        float3 base = mix(iron, steel, smoothstep(0.05, 0.65, pid));
        base = mix(base, oxide, smoothstep(0.60, 1.0, pid) * 0.65);

        // Weathering: broad staining plus a finer grain, biased per panel so neighbours differ.
        float stain = fbm(uv * 5.0 + pid * 9.0, 3);
        float grain = fbm(uv * 26.0 + pid * 3.0, 2);
        base *= 0.82 + 0.30 * stain + 0.07 * grain;

        // Seams: a dark groove between panels, and a deeper one at the cubie boundary, so the plate
        // reads as many pieces bolted together rather than one sheet.
        float2 dp = min(f, 1.0 - f);
        float panelSeam = smoothstep(0.0, 0.05, min(dp.x, dp.y));
        float2 dt = min(uv, 1.0 - uv);
        float tileSeam = smoothstep(0.0, 0.022, min(dt.x, dt.y));
        base *= (0.52 + 0.48 * panelSeam) * (0.62 + 0.38 * tileSeam);

        color = clamp(base, 0.04, 0.95);
        // Metal takes a harder light than ground: less ambient fill, a touch more directional.
        lighting = skyAmbient * 0.26 + sunColor * 0.80 * halfLambert * shadowFactor;
    } else if (in.materialID == 17) {
        // M20 alpha-cutout foliage card. Sample the real leaf atlas (RGB colour + opacity in alpha)
        // when one is bound; else fall back to a procedural leaf mask. Discard the gaps so a flat
        // card reads as leaves. Two-sided lighting (foliage is lit from either face).
        float twoSided = abs(dot(normal, lightDir)) * 0.5 + 0.5;
        if (frame.leafLoaded > 0.5) {
            uint slice = in.styleSeed % leafTex.get_array_size();  // per-bush LeafSet (styleSeed = slice)
            float4 leaf = leafTex.sample(texSampler, in.texCoord, slice);
            if (leaf.a < 0.5) discard_fragment();
            color = leaf.rgb * (0.82 + 0.45 * in.color.g);        // atlas colour, subtle per-bush brightness
        } else {
            float2 uv = in.texCoord;
            float2 p = uv - 0.5;
            float radial = length(p * float2(1.0, 1.25));
            float clump = fbm(uv * 5.0 + float2(seedF, -seedF), 3);
            float mask = (1.0 - smoothstep(0.34, 0.5, radial)) * smoothstep(0.34, 0.56, clump);
            if (mask < 0.22) discard_fragment();
            color = in.color.rgb * (0.6 + 0.55 * clump);
        }
        lighting = skyAmbient * 0.40 + sunColor * 0.55 * twoSided * shadowFactor;
    } else if (in.materialID == 18) {
        // M20 misc-greenery card (fern/flower/plant) — already-alpha RGBA, styleSeed = slice.
        // V-flipped: CGImage rows load top-down but Metal samples v=0 at top, so uncorrected sprites
        // render upside-down (invisible on the symmetric leaf atlas, obvious on a plant).
        if (frame.greeneryLoaded > 0.5) {
            float2 uv = float2(in.texCoord.x, 1.0 - in.texCoord.y);
            float4 g = greeneryTex.sample(texSampler, uv, in.styleSeed % greeneryTex.get_array_size());
            if (g.a < 0.5) discard_fragment();
            color = g.rgb;
        } else { color = in.color.rgb; }
        lighting = skyAmbient * 0.42 + sunColor * 0.55 * (abs(dot(normal, lightDir)) * 0.5 + 0.5) * shadowFactor;
    } else if (in.materialID == 19) {
        // M20 WenrexaTrees billboard sprite — already-alpha RGBA, styleSeed = slice. V-flipped (see 18).
        if (frame.treeSpriteLoaded > 0.5) {
            float2 uv = float2(in.texCoord.x, 1.0 - in.texCoord.y);
            float4 t = treeTex.sample(texSampler, uv, in.styleSeed % treeTex.get_array_size());
            if (t.a < 0.5) discard_fragment();
            color = t.rgb;
        } else { color = in.color.rgb; }
        lighting = skyAmbient * 0.42 + sunColor * 0.55 * (abs(dot(normal, lightDir)) * 0.5 + 0.5) * shadowFactor;
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

    // SCENE 3 — THE CHAMBER LIGHTS ITSELF. There is no sun in here: "light comes from narrow seams
    // between selected wall blocks, dim recessed fixtures, weak reflections from the central
    // crystal, dormant obelisk markings." The orb and its beams are the only real sources, and
    // until now they lit only themselves — six bright objects in a room they left dark.
    //
    // The orb is a point. Each beam is a SEGMENT, shaded from its closest point to this surface,
    // which is what a line of light actually does and costs one clamp more than a point light. The
    // count is zero in every world without an orb, so this loop is free everywhere else — which
    // matters, since this renderer is fill-bound.
    for (int i = 0; i < frame.chamberLightCount; ++i) {
        float3 la = frame.chamberLightA[i].xyz;
        float3 lb = frame.chamberLightB[i].xyz;
        float radius = frame.chamberLightA[i].w;
        // Closest point on the segment. For the orb A == B, so this collapses to a point light.
        float3 ab = lb - la;
        float denom = max(1e-6, dot(ab, ab));
        float tOn = saturate(dot(in.worldPosition - la, ab) / denom);
        float3 lp = la + ab * tOn;
        float3 toLight = lp - in.worldPosition;
        float dist = length(toLight);
        if (dist >= radius) continue;
        float fall = 1.0 - dist / radius;
        fall *= fall;
        // Never fully dark on the far side: this is a lantern in an enclosed metal room, and light
        // in here has nowhere to go but bounce.
        float facing = 0.40 + 0.60 * saturate(dot(normal, toLight / max(dist, 1e-4)));
        color += frame.chamberLightColor[i].rgb * (frame.chamberLightB[i].w * fall * facing);
    }

    // Scene 1G — THE PORTAL'S SPILL. "Colored illumination trembles faintly across the stone ahead,
    // too saturated to be sunlight… light from the portal spills across the floor and up the nearby
    // walls. It also reflects from the vessel placed beside the arch."
    //
    // An emissive surface lights only itself, so the arch could never do this on its own; the CPU
    // publishes the nearest active portal as a point light and it is added here, after the material
    // has decided its own colour. ADDITIVE on purpose: this is light arriving, so it brightens what
    // it falls on rather than tinting it, and it survives on surfaces that are already lit.
    if (frame.portalLightRadius > 0.0) {
        float3 toLight = frame.portalLightPosition - in.worldPosition;
        float dist = length(toLight);
        if (dist < frame.portalLightRadius) {
            // Smooth to zero at the radius so the pool of light has no visible boundary — a hard
            // edge would read as a decal on the floor rather than as illumination.
            float fall = 1.0 - dist / frame.portalLightRadius;
            fall *= fall * fall;        // cubic: bright only right at the arch, gone a tile or two out
            // Surfaces facing the portal catch more, but never nothing: a doorway's light bounces,
            // and a wall edge-on going fully black is the giveaway of a fake point light.
            float facing = 0.35 + 0.65 * saturate(dot(normal, toLight / max(dist, 1e-4)));
            color += frame.portalLightColor * (frame.portalLightIntensity * fall * facing);
        }
    }

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
        // An enclosed chamber has no horizon to fade into. Fading toward grey there reads as mist
        // indoors; fading toward near-black reads as distance, which is what "distant and muted"
        // means when there is no sun. A trace of the chamber's own blue keeps it from looking like
        // the geometry has simply been clipped away.
        horizon = mix(horizon, float3(0.020, 0.026, 0.038), frame.darkHaze);
        float fogBrightness = mix(0.7, 1.3, fogTex);
        float3 fogColor = horizon * fogBrightness;

        fogFactor *= (0.85 + 0.3 * fogTex);
        fogFactor = saturate(fogFactor);

        color = mix(color, fogColor, fogFactor);
    }

    return float4(color, alpha);
}
