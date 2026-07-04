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
} FrameUniforms;

typedef struct
{
    matrix_float4x4 modelMatrix;
    vector_float4 baseColor;
    uint materialID;
    uint tileID;
    float discoveryAmount;
    uint styleSeed;
} InstanceData;

typedef struct
{
    vector_float3 position;
    vector_float3 normal;
    vector_float2 texCoord;
    float aoFactor;
} MazeVertex;

#endif
