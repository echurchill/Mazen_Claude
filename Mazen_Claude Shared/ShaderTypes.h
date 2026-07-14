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
} InstanceData;

typedef struct
{
    vector_float3 position;
    vector_float3 normal;
    vector_float2 texCoord;
    float aoFactor;
} MazeVertex;

#endif
