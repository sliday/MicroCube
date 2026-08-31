#include <metal_stdlib>
using namespace metal;

constant uint kWorldSize = 512u;
constant uint kTopMip = 9u;
constant float kTraceEpsilon = 0.001f;
constant uint SDF_FLAG_EMISSIVE = 1u;
constant uint SDF_KIND_FRACTAL = 3u;

inline float hash2(int x, int z, int seed) {
    uint h = uint(x) * 374761393u + uint(z) * 668265263u + uint(seed) * 1274126177u;
    h = (h ^ (h >> 13u)) * 1274126177u;
    h ^= h >> 16u;
    return float(h) * (1.0f / 4294967296.0f);
}

inline float valueNoise(float x, float z, int seed) {
    int ix = int(floor(x));
    int iz = int(floor(z));
    float2 f = float2(x - float(ix), z - float(iz));
    float2 u = f * f * (3.0f - 2.0f * f);
    float a = hash2(ix, iz, seed);
    float b = hash2(ix + 1, iz, seed);
    float c = hash2(ix, iz + 1, seed);
    float d = hash2(ix + 1, iz + 1, seed);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

inline float noise3D(float x, float y, float z, int seed) {
    int iy = int(floor(y));
    float f = y - float(iy);
    float u = f * f * (3.0f - 2.0f * f);
    return mix(valueNoise(x, z, seed + iy * 37), valueNoise(x, z, seed + (iy + 1) * 37), u);
}

struct FrameUniforms {
    float4 cameraPositionAndTime;
    float4 cameraForwardAndFOV;
    float4 cameraRightAndAspect;
    float4 cameraUpAndMaxDistance;
    float4 sunDirectionAndAmbient;
    uint4 viewportAndOptions;
    float4 fogAndExposure;
};

struct SceneUniforms {
    uint4 counts;
    uint4 grid;
    float4 fog;
    uint4 budgets;
};

struct CellHeader {
    uint sdfOffset;
    uint gaussianOffset;
    uint packedCounts;
    uint reserved;
};

struct SDFInstance {
    float4 sweptBoundsMin;
    float4 sweptBoundsMax;
    float4 positionScale;
    float4 rotationQuaternion;
    float4 parameters;
    uint4 metadata;
};

struct Gaussian {
    float4 localCenterSigma;
    float4 colorDensity;
    float4 motionPhase;
};

struct Light {
    float4 positionRadius;
    float4 colorIntensity;
};

struct Material {
    float4 baseColorRoughness;
    float4 emissionMetalness;
    float4 opticalAbsorptionIOR;
    float4 transmissionAcoustic;
};

struct FrameCounters {
    atomic_uint macroSkips;
    atomic_uint macroDescents;
    atomic_uint voxelSteps;
    atomic_uint sdfSamples;
    atomic_uint gaussianSamples;
    atomic_uint secondaryRays;
    atomic_uint surfaceSunShadows;
    atomic_uint surfaceLocalShadows;
    atomic_uint volumeSunShadows;
    atomic_uint volumeLocalShadows;
    atomic_uint budgetOverflows;
    atomic_uint reserved;
};

struct TraceHit {
    float t;
    int3 voxel;
    float3 normal;
    uint material;
};

struct HybridHit {
    float t;
    float3 normal;
    uint material;
    uint primitiveKind;
    uint stableID;
    float4 opticalSphere;
};

struct TraceCounts {
    uint hierarchicalSteps;
    uint macroSkips;
    uint macroDescents;
    uint voxelSteps;
    uint sdfSamples;
    uint gaussianSamples;
    uint budgetOverflows;
};
