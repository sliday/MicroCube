#include <metal_stdlib>
using namespace metal;

constant uint kWorldSize = 512u;
constant uint kTopMip = 9u;
constant float kTraceEpsilon = 0.001f;

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
