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
    TextureIndexColor = 0,
};

typedef struct
{
    matrix_float4x4 viewProjectionMatrix;
    vector_float3 cameraPosition;
    float time;
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
} MazeVertex;

#endif
