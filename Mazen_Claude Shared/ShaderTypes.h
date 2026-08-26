#ifndef ShaderTypes_h
#define ShaderTypes_h

#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif

#include <simd/simd.h>

typedef NS_ENUM(EnumBackingType, BufferIndex)
{
    BufferIndexVertices     = 0,
    BufferIndexFrameUniforms = 1,
    BufferIndexInstances    = 2
};

typedef NS_ENUM(EnumBackingType, TextureIndex)
{
    TextureIndexDiffuseArray = 0,
    TextureIndexNormalArray  = 1,
    TextureIndexSkybox       = 2,
    TextureIndexShadowMap    = 3,
    TextureIndexAssetDiffuse = 4,   // M12: imported prop's diffuse texture
    TextureIndexLeaf         = 5,   // M20: leaf-atlas array (RGB + composed opacity) for cutout bushes
    TextureIndexGreenery     = 6,   // M20: misc-greenery card array (RGBA) — ferns/flowers/plants
    TextureIndexTreeSprite   = 7,   // M20: WenrexaTrees billboard-sprite array (RGBA)
    TextureIndexCaustic      = 8,   // M16.6: Builder-glyph caustic symbols (r8 intensity array)
    TextureIndexLabel        = 9,   // M20: rendered text sign-board array (RGBA) for portal signposts
    TextureIndexDendrite     = 10,  // Scene 5: the surveyor's filigree (RG: intensity + growth distance)
    TextureIndexPortalView   = 11,  // captured "what is through this door" views, one slice per route
    TextureIndexPrompt       = 12,  // teaching text, rendered to a wide RGBA strip (see TeachingPrompts)
};

typedef struct
{
    matrix_float4x4 viewProjectionMatrix;
    vector_float3 cameraPosition;
    float time;
    vector_float3 lightDirection;
    matrix_float4x4 inverseViewProjectionMatrix;
    vector_float3 cameraUp;
    matrix_float4x4 lightViewProjectionMatrix;
    // M9-4 day/night cycle
    float sunElevation;          // dot(sunDir, up): >0 day, <0 night
    vector_float3 moonDirection; // normalized, toward the moon
    float moonIntensity;         // base strength of the moon's fill light
    float eclipseFactor;         // M9-7: 0 normally, →1 as the moon covers the sun
    float fadeAmount;            // M11.2b: 0 clear → 1 black, for the world-transition fade
    float promptOpacity;         // teaching text: 0 none … 1 fully shown
    float promptHalfW;           // …and its quad's half-extents in clip space, sized so the strip
    float promptHalfH;           //    maps 1:1 to drawable pixels (no magnified letterforms)
    float plainShading;          // debug: 1 = flat matte Lambert (no texture/normal-map/fog), to read geometry (M14)
    // R2.11: size-derived fog + camera-mode blend, computed CPU-side per frame. The old in-shader
    // constants (smoothstep(4,14) fog, smoothstep(3,5) orbit gate) assumed the size-5 world and
    // silver-veiled the whole planet from orbit at size 7+.
    float fogNear;               // world-units from the camera where distance fog begins
    float fogFar;                // ... and where it saturates
    float orbitBlend;            // 1 = orbit camera (stone ground base), 0 = first-person (gravel)
    float skyDistance;           // beyond this, geometry is a SKY object (the counterpart world in
                                 // the sky) — outside the local atmosphere, so it takes no fog
    float leafLoaded;            // M20: 1 = a real leaf atlas is bound (sample it), 0 = fall back to the procedural mask
    float greeneryLoaded;        // M20: 1 = misc-greenery card array bound
    float treeSpriteLoaded;      // M20: 1 = WenrexaTrees sprite array bound
    // Scene 1G — the portal LIGHTS ITS SURROUNDINGS. "Colored illumination trembles faintly across
    // the stone ahead, too saturated to be sunlight… light from the portal spills across the floor
    // and up the nearby walls. It also reflects from the vessel placed beside the arch."
    // The approach is meant to be readable BEFORE you round the corner, which nothing emissive can
    // do on its own — an emissive surface lights only itself. So the nearest active portal is
    // published as a point light and the lit materials add it.
    // Scene 3 — the chamber lights itself. The orb is a point; each beam is a SEGMENT, lit by its
    // closest point to the surface being shaded, which is what a line of light actually does and is
    // barely more expensive than a point. Count is 0 in every world that has no orb, so the loop
    // costs nothing where it is not wanted — which matters, the renderer being fill-bound.
    vector_float4 chamberLightA[8];      // xyz = point / segment start, w = radius
    vector_float4 chamberLightB[8];      // xyz = segment end (== A for the orb), w = intensity
    vector_float4 chamberLightColor[8];  // rgb; w unused
    int chamberLightCount;
    // Scene 3I/3J — how awake the chamber is (0…1, obelisks lit), and the completion WAVE that
    // travels out from the orb when the sixth connects (0 = not running, →1 as it passes).
    float chamberWoken;
    float chamberWave;
    /// 1 in a world whose distance fog should fall toward DARK rather than toward a sky horizon —
    /// an enclosed chamber has no horizon to fade into, so fading to grey reads as mist indoors.
    float darkHaze;
    /// Scene 5C — how far the source's pulse has travelled, in channel-steps from the source, or -1
    /// while nothing is travelling. The groove shader lights the tiles the front is passing; the
    /// audio emitter follows the same number, so what you hear and what you see are one fact.
    float channelPulse;
    /// The shadow ortho's (farZ − nearZ) in world units — converts an occluder↔receiver depth gap
    /// back to distance along the light ray, so a caster on the far side of the WORLD can be told
    /// apart from a wall two tiles away.
    float shadowDepthRange;
    /// Scene 5: 1 while the diagnostic pulse is in flight (the front draws brighter), and the 5J
    /// bloom 0→1→0.3 — the whole circuit lighting when it locks, then settling to a resting glow.
    float channelPulseBright;
    float worldBloom;
    vector_float3 portalLightPosition;   // world space; unused when the radius is 0
    float portalLightRadius;             // 0 = no portal light this frame
    vector_float3 portalLightColor;
    float portalLightIntensity;
} FrameUniforms;

typedef struct
{
    matrix_float4x4 modelMatrix;
    vector_float4 baseColor;
    uint materialID;
    uint tileID;
    float discoveryAmount;
    uint styleSeed;
    // M14b per-vertex inflation. When roundness > 0 the vertex shader inflates this instance's
    // vertices onto the rounded surface in the cube's REST frame (modelMatrix must then be the
    // *un-spun* rest placement), then applies spinMatrix. When roundness == 0 the shader uses
    // modelMatrix directly (spin baked in as before) and spinMatrix/invHalfExtent are ignored.
    matrix_float4x4 spinMatrix;  // world spin (+ M11 offset) applied AFTER inflation
    float roundness;             // 0 = flat/rigid (default); >0 = per-vertex superellipsoid inflate
    float invHalfExtent;         // 1 / (cubeSize/2) — maps rest world coords to the unit cube
    float reliefAmplitude;       // M19: 0 = smooth (default); >0 = roll the surface into hills
    // M20: per-instance HEIGHT animation, applied to the vertex's local z BEFORE the inflation's
    // footprint/height split (a Z-scale baked into modelMatrix would corrupt the footprint on a
    // curved world — that floated the flush switch cap). z' = heightPivot + (z - heightPivot)*heightScale.
    float heightScale;           // 1 = unchanged (default)
    float heightPivot;           // pivot the scale is taken about (e.g. the plinth top for a switch cap)
} InstanceData;

typedef struct
{
    vector_float3 position;
    vector_float3 normal;
    vector_float2 texCoord;
    float aoFactor;
} MazeVertex;

#endif
