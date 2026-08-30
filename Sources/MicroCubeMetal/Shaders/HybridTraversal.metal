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

inline bool traceOcclusionExact(texture3d<uint, access::read> volume,
                                float3 origin,
                                float3 direction,
                                float maximumDistance,
                                thread TraceHit &hit) {
    return traceVolume(volume, origin, direction, maximumDistance, 0u, hit);
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
