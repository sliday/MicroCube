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

struct TraceHit {
    float t;
    int3 voxel;
    float3 normal;
    uint material;
};

constant float3 kPalette[43] = {
    float3(0.000000f, 0.000000f, 0.000000f),
    float3(0.294118f, 0.345098f, 0.290196f),
    float3(0.341176f, 0.400000f, 0.337255f),
    float3(0.388235f, 0.454902f, 0.384314f),
    float3(0.250980f, 0.364706f, 0.219608f),
    float3(0.294118f, 0.427451f, 0.254902f),
    float3(0.333333f, 0.486275f, 0.294118f),
    float3(0.333333f, 0.388235f, 0.301961f),
    float3(0.388235f, 0.450980f, 0.352941f),
    float3(0.443137f, 0.513725f, 0.400000f),
    float3(0.333333f, 0.411765f, 0.254902f),
    float3(0.384314f, 0.478431f, 0.294118f),
    float3(0.439216f, 0.545098f, 0.337255f),
    float3(0.388235f, 0.435294f, 0.313725f),
    float3(0.454902f, 0.505882f, 0.364706f),
    float3(0.517647f, 0.576471f, 0.415686f),
    float3(0.419608f, 0.454902f, 0.294118f),
    float3(0.490196f, 0.529412f, 0.345098f),
    float3(0.556863f, 0.603922f, 0.392157f),
    float3(0.466667f, 0.478431f, 0.321569f),
    float3(0.541176f, 0.556863f, 0.372549f),
    float3(0.615686f, 0.635294f, 0.427451f),
    float3(0.501961f, 0.494118f, 0.345098f),
    float3(0.584314f, 0.572549f, 0.403922f),
    float3(0.666667f, 0.654902f, 0.458824f),
    float3(0.525490f, 0.486275f, 0.333333f),
    float3(0.607843f, 0.568627f, 0.384314f),
    float3(0.694118f, 0.647059f, 0.439216f),
    float3(0.545098f, 0.501961f, 0.407843f),
    float3(0.635294f, 0.584314f, 0.474510f),
    float3(0.725490f, 0.662745f, 0.541176f),
    float3(0.568627f, 0.466667f, 0.345098f),
    float3(0.662745f, 0.541176f, 0.403922f),
    float3(0.752941f, 0.615686f, 0.458824f),
    float3(0.592157f, 0.521569f, 0.474510f),
    float3(0.686275f, 0.607843f, 0.552941f),
    float3(0.784314f, 0.690196f, 0.631373f),
    float3(0.615686f, 0.431373f, 0.368627f),
    float3(0.713725f, 0.501961f, 0.427451f),
    float3(0.815686f, 0.572549f, 0.490196f),
    float3(0.635294f, 0.533333f, 0.517647f),
    float3(0.741176f, 0.619608f, 0.603922f),
    float3(0.843137f, 0.705882f, 0.686275f)
};

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

inline float terrainHeight(float wx, float wz) {
    float n = valueNoise(wx / 48.0f, wz / 48.0f, 7) * 0.55f
        + valueNoise(wx / 20.0f, wz / 20.0f, 8) * 0.30f
        + valueNoise(wx / 8.0f, wz / 8.0f, 9) * 0.15f;
    float ridge = 1.0f - abs(valueNoise(wx / 88.0f, wz / 88.0f, 10) * 2.0f - 1.0f);
    return round(72.0f + (n - 0.5f) * 64.0f + ridge * ridge * 25.6f);
}

inline float islandDensity(float wx, float y, float wz) {
    float distance = abs(y - 160.0f);
    if (distance > 112.0f) {
        return 0.0f;
    }
    return noise3D(wx / 80.0f, y / 48.0f, wz / 80.0f, 53) - distance / 112.0f;
}

kernel void generateTerrain(texture3d<uint, access::write> volume [[texture(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (any(gid >= uint2(kWorldSize))) {
        return;
    }

    int wx = int(gid.x) - 256;
    int wz = int(gid.y) - 256;
    int height = clamp(int(terrainHeight(float(wx), float(wz))), 0, 512);
    int bx = int(floor(float(wx) / 2.0f));
    int bz = int(floor(float(wz) / 2.0f));

    for (uint blockY = 0u; blockY < kWorldSize; blockY += 4u) {
        for (uint lane = 0u; lane < 4u; ++lane) {
            uint y = blockY + lane;
            bool belowGround = int(y) < height;
            float cave = belowGround
                ? abs(noise3D(float(wx) / 36.0f, float(y) / 36.0f, float(wz) / 36.0f, 41) - 0.5f)
                : 1.0f;
            float island = belowGround ? 0.0f : islandDensity(float(wx), float(y), float(wz));
            bool islandTop = !belowGround && island > 0.7f
                && islandDensity(float(wx), float(y + 1u), float(wz)) <= 0.7f;
            bool solid = belowGround
                ? !(cave < 0.045f && (int(y) < height - 8 || cave < 0.01575f))
                : island > 0.7f;
            uint material = 0u;

            if (solid) {
                int depthVoxels = belowGround ? height - 1 - int(y) : (islandTop ? 0 : 2);
                float level = (float(height) - 40.0f) / 64.0f
                    + (valueNoise(float(wx) / 24.0f, float(wz) / 24.0f, 31) - 0.5f) * 0.28f;
                float band = valueNoise(float(wx) / 160.0f, float(wz) / 160.0f, 21) * 6.0f
                    + float(y) / 10.0f;
                int surfaceBand = clamp(int(level * 14.0f), 0, 13);
                int materialBand = depthVoxels == 0 ? surfaceBand
                    : (depthVoxels == 1 ? max(0, surfaceBand - 1) : ((int(floor(band)) % 14) + 14) % 14);
                int by = int(y) / 2;
                uint shade = min(2u, uint(hash2(bx * 7 + by, bz * 13 + by, 5) * 3.0f));
                material = 1u + uint(materialBand) * 3u + shade;
                if (hash2(wx * 3, wz * 5, int(y)) > 0.82f) {
                    material = 1u + uint(materialBand) * 3u + ((shade + 1u) % 3u);
                }
            }

            volume.write(uint4(material), uint3(gid.x, y, gid.y));
        }
    }
}

kernel void reduceOccupancy(texture3d<uint, access::read> source [[texture(0)]],
                            texture3d<uint, access::write> destination [[texture(1)]],
                            uint3 gid [[thread_position_in_grid]]) {
    uint3 destinationSize(destination.get_width(), destination.get_height(), destination.get_depth());
    if (any(gid >= destinationSize)) {
        return;
    }

    uint3 sourceOrigin = gid * 2u;
    uint occupied = 0u;
    for (uint z = 0u; z < 2u; ++z) {
        for (uint y = 0u; y < 2u; ++y) {
            for (uint x = 0u; x < 2u; ++x) {
                occupied |= source.read(sourceOrigin + uint3(x, y, z)).x;
            }
        }
    }
    destination.write(uint4(occupied != 0u), gid);
}

inline bool intersectWorld(float3 origin, float3 direction, thread float &nearT, thread float &farT) {
    float3 inverseDirection = 1.0f / copysign(max(abs(direction), float3(1.0e-7f)), direction);
    float3 a = (float3(0.0f) - origin) * inverseDirection;
    float3 b = (float3(float(kWorldSize)) - origin) * inverseDirection;
    float3 nearPlane = min(a, b);
    float3 farPlane = max(a, b);
    nearT = max(max(nearPlane.x, nearPlane.y), max(nearPlane.z, 0.0f));
    farT = min(farPlane.x, min(farPlane.y, farPlane.z));
    return farT > nearT;
}

inline uint minimumAxis(float3 value) {
    if (value.x <= value.y && value.x <= value.z) {
        return 0u;
    }
    return value.y <= value.z ? 1u : 2u;
}

inline uint maximumAxis(float3 value) {
    if (value.x >= value.y && value.x >= value.z) {
        return 0u;
    }
    return value.y >= value.z ? 1u : 2u;
}

inline float3 axisNormal(uint axis, float3 direction) {
    float3 normal(0.0f);
    normal[axis] = direction[axis] > 0.0f ? -1.0f : 1.0f;
    return normal;
}

inline bool traceVolume(texture3d<uint, access::read> volume,
                        float3 origin,
                        float3 direction,
                        float maximumDistance,
                        uint stopLevel,
                        thread TraceHit &hit) {
    float nearT;
    float farT;
    if (!intersectWorld(origin, direction, nearT, farT)) {
        return false;
    }
    farT = min(farT, maximumDistance);
    if (farT <= nearT) {
        return false;
    }

    float3 inverseDirection = 1.0f / copysign(max(abs(direction), float3(1.0e-7f)), direction);
    float t = nearT;
    uint level = kTopMip;

    for (uint step = 0u; step < 4096u && t < farT; ++step) {
        float3 point = origin + direction * (t + kTraceEpsilon);
        int3 voxel = int3(floor(point));
        if (any(voxel < int3(0)) || any(voxel >= int3(kWorldSize))) {
            break;
        }

        uint occupied = volume.read(uint3(voxel) >> level, level).x;
        uint requiredLevel = stopLevel > 0u && t > float(1u << stopLevel) * 2.0f ? stopLevel : 0u;
        if (occupied != 0u) {
            if (level > requiredLevel) {
                --level;
                continue;
            }
            if (level > 0u) {
                hit.t = t;
                hit.voxel = voxel;
                hit.normal = -direction;
                hit.material = 1u;
                return true;
            }

            float3 voxelMinimum = float3(voxel);
            float3 voxelMaximum = voxelMinimum + 1.0f;
            float3 a = (voxelMinimum - origin) * inverseDirection;
            float3 b = (voxelMaximum - origin) * inverseDirection;
            float3 entryPlane = min(a, b);
            uint axis = maximumAxis(entryPlane);
            hit.t = max(nearT, max(entryPlane.x, max(entryPlane.y, entryPlane.z)));
            hit.voxel = voxel;
            hit.normal = axisNormal(axis, direction);
            hit.material = volume.read(uint3(voxel), 0u).x;
            return hit.material != 0u;
        }

        float cellSize = float(1u << level);
        float3 cellMinimum = floor(point / cellSize) * cellSize;
        float3 boundary = select(cellMinimum, cellMinimum + cellSize, direction > 0.0f);
        float3 exits = (boundary - origin) * inverseDirection;
        float3 candidates = select(float3(INFINITY), exits, exits > t + kTraceEpsilon);
        uint axis = minimumAxis(candidates);
        float nextT = candidates[axis];
        if (!isfinite(nextT)) {
            break;
        }
        t = nextT + kTraceEpsilon;
        level = min(kTopMip, level + 1u);
    }
    return false;
}

inline uint occupancy(texture3d<uint, access::read> volume, int3 position) {
    if (any(position < int3(0)) || any(position >= int3(kWorldSize))) {
        return 0u;
    }
    return volume.read(uint3(position), 0u).x != 0u;
}

inline float vertexAO(uint sideA, uint sideB, uint corner) {
    return sideA != 0u && sideB != 0u ? 0.0f : float(3u - sideA - sideB - corner);
}

inline float voxelAO(texture3d<uint, access::read> volume, float3 point, float3 normal) {
    int3 solidVoxel = int3(floor(point - normal * 0.5f));
    int3 base = solidVoxel + int3(normal);
    int3 tangentA;
    int3 tangentB;
    float2 fraction;

    if (normal.x != 0.0f) {
        tangentA = int3(0, 1, 0);
        tangentB = int3(0, 0, 1);
        fraction = fract(point.yz);
    } else if (normal.y != 0.0f) {
        tangentA = int3(1, 0, 0);
        tangentB = int3(0, 0, 1);
        fraction = fract(point.xz);
    } else {
        tangentA = int3(1, 0, 0);
        tangentB = int3(0, 1, 0);
        fraction = fract(point.xy);
    }

    uint sideANegative = occupancy(volume, base - tangentA);
    uint sideAPositive = occupancy(volume, base + tangentA);
    uint sideBNegative = occupancy(volume, base - tangentB);
    uint sideBPositive = occupancy(volume, base + tangentB);
    float ao00 = vertexAO(sideANegative, sideBNegative, occupancy(volume, base - tangentA - tangentB));
    float ao10 = vertexAO(sideAPositive, sideBNegative, occupancy(volume, base + tangentA - tangentB));
    float ao01 = vertexAO(sideANegative, sideBPositive, occupancy(volume, base - tangentA + tangentB));
    float ao11 = vertexAO(sideAPositive, sideBPositive, occupancy(volume, base + tangentA + tangentB));
    float ao = mix(mix(ao00, ao10, fraction.x), mix(ao01, ao11, fraction.x), fraction.y) / 3.0f;
    return mix(0.4f, 1.0f, ao);
}

inline float3 skyColor(float3 direction, float3 sunDirection) {
    constexpr float3 skyTop = float3(92.0f, 132.0f, 196.0f) / 255.0f;
    constexpr float3 skyHorizon = float3(186.0f, 206.0f, 226.0f) / 255.0f;
    constexpr float3 fogColor = float3(150.0f, 170.0f, 195.0f) / 255.0f;
    constexpr float3 sunColor = float3(255.0f, 246.0f, 214.0f) / 255.0f;
    float height = saturate(direction.y * 1.6f + 0.15f);
    float3 color = mix(skyHorizon, skyTop, height);
    color = mix(color, fogColor, saturate(1.0f - abs(direction.y) * 6.0f));
    float sunDot = dot(direction, sunDirection);
    float glow = saturate((sunDot - 0.96f) / 0.04f);
    glow *= glow;
    glow *= glow;
    float sunlight = saturate((sunDot > 0.9985f ? 1.0f : 0.0f) + glow);
    return mix(color, sunColor, sunlight);
}

kernel void raycast(texture3d<uint, access::read> volume [[texture(0)]],
                    texture2d<float, access::write> output [[texture(1)]],
                    constant FrameUniforms &uniforms [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    uint2 viewport = uniforms.viewportAndOptions.xy;
    if (any(gid >= viewport)) {
        return;
    }

    float2 pixel = float2(gid) + 0.5f;
    float horizontal = (2.0f * pixel.x / float(viewport.x) - 1.0f)
        * uniforms.cameraForwardAndFOV.w * uniforms.cameraRightAndAspect.w;
    float vertical = (1.0f - 2.0f * pixel.y / float(viewport.y)) * uniforms.cameraForwardAndFOV.w;
    float3 direction = normalize(uniforms.cameraForwardAndFOV.xyz
        + uniforms.cameraRightAndAspect.xyz * horizontal
        + uniforms.cameraUpAndMaxDistance.xyz * vertical);
    float3 origin = uniforms.cameraPositionAndTime.xyz;
    float3 sunDirection = normalize(uniforms.sunDirectionAndAmbient.xyz);
    float3 color;
    TraceHit hit;

    if (traceVolume(volume, origin, direction, uniforms.cameraUpAndMaxDistance.w, 0u, hit)) {
        float3 point = origin + direction * hit.t;
        float diffuse = max(0.0f, dot(hit.normal, sunDirection));
        float lighting = uniforms.sunDirectionAndAmbient.w
            + (1.0f - uniforms.sunDirectionAndAmbient.w) * diffuse;
        lighting *= hit.normal.y > 0.0f ? 1.0f : (hit.normal.y < 0.0f ? 0.62f : (hit.normal.x != 0.0f ? 0.82f : 0.9f));
        lighting *= voxelAO(volume, point, hit.normal);

        if (diffuse > 0.0f) {
            TraceHit shadowHit;
            if (traceVolume(volume, point + hit.normal * 0.035f, sunDirection, 100.0f, 0u, shadowHit)) {
                lighting *= 0.45f;
            }
        }

        color = kPalette[min(hit.material, 42u)] * lighting;
        float fogStart = uniforms.cameraUpAndMaxDistance.w * uniforms.fogAndExposure.x;
        float fogEnd = uniforms.cameraUpAndMaxDistance.w * uniforms.fogAndExposure.y;
        float fog = saturate((hit.t - fogStart) / max(0.001f, fogEnd - fogStart));
        color = mix(color, float3(150.0f, 170.0f, 195.0f) / 255.0f, fog);
    } else {
        color = skyColor(direction, sunDirection);
    }

    color = pow(saturate(color * uniforms.fogAndExposure.z), float3(1.0f / 2.2f));
    output.write(float4(color, 1.0f), gid);
}
