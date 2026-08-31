inline float sdSphere(float3 p, float radius) {
    return length(p) - radius;
}

inline float sdCapsule(float3 p, float3 a, float3 b, float radius) {
    float3 pa = p - a;
    float3 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1.0e-8f), 0.0f, 1.0f);
    return length(pa - ba * h) - radius;
}

inline float smoothUnion(float a, float b, float smoothing) {
    float h = saturate(0.5f + 0.5f * (b - a) / max(smoothing, 1.0e-6f));
    return mix(b, a, h) - smoothing * h * (1.0f - h);
}

inline float fractalDistance(float3 point, uint maximumIterations) {
    float3 z = point;
    float derivative = 1.0f;
    float radius = length(z);
    constexpr float power = 8.0f;
    for (uint iteration = 0u; iteration < min(maximumIterations, 8u); ++iteration) {
        radius = length(z);
        if (radius > 2.0f) {
            break;
        }
        float safeRadius = max(radius, 1.0e-6f);
        float theta = acos(clamp(z.z / safeRadius, -1.0f, 1.0f));
        float phi = atan2(z.y, z.x);
        float radialPower = pow(safeRadius, power - 1.0f);
        derivative = radialPower * power * derivative + 1.0f;
        float magnitude = radialPower * safeRadius;
        theta *= power;
        phi *= power;
        z = magnitude * float3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta)) + point;
    }
    radius = max(length(z), 1.0e-6f);
    return max(0.5f * log(radius) * radius / max(derivative, 1.0e-6f), 1.0e-5f);
}

inline float distanceToInstance(float3 point,
                                thread const SDFInstance &instance,
                                uint fractalIterations) {
    float3 local = point - instance.positionScale.xyz;
    float scale = max(instance.positionScale.w, 1.0e-4f);
    switch (instance.metadata.x) {
        case 1u: {
            float height = max(instance.parameters.x, scale * 2.0f);
            float gait = instance.parameters.z;
            float footY = -height * 0.5f - scale * 0.32f + scale * 0.17f;
            float legX = scale * 0.25f;
            float torso = sdCapsule(local, float3(0.0f, -height * 0.20f, 0.0f),
                                   float3(0.0f, height * 0.24f, 0.0f), scale * 0.30f);
            float head = sdSphere(local - float3(0.0f, height * 0.38f, 0.0f), scale * 0.46f);
            float leftLeg = sdCapsule(
                local,
                float3(-legX, -height * 0.18f, -gait * scale * 0.25f),
                float3(-legX, footY, gait * scale * 0.55f),
                scale * 0.17f
            );
            float rightLeg = sdCapsule(
                local,
                float3(legX, -height * 0.18f, gait * scale * 0.25f),
                float3(legX, footY, -gait * scale * 0.55f),
                scale * 0.17f
            );
            float leftArm = sdCapsule(
                local,
                float3(-scale * 0.22f, height * 0.14f, 0.0f),
                float3(-scale * 0.75f, -height * 0.06f, -gait * scale * 0.42f),
                scale * 0.13f
            );
            float rightArm = sdCapsule(
                local,
                float3(scale * 0.22f, height * 0.14f, 0.0f),
                float3(scale * 0.75f, -height * 0.06f, gait * scale * 0.42f),
                scale * 0.13f
            );
            float leftHorn = sdCapsule(
                local,
                float3(-scale * 0.20f, height * 0.47f, 0.0f),
                float3(-scale * 0.38f, height * 0.69f, 0.0f),
                scale * 0.08f
            );
            float rightHorn = sdCapsule(
                local,
                float3(scale * 0.20f, height * 0.47f, 0.0f),
                float3(scale * 0.38f, height * 0.69f, 0.0f),
                scale * 0.08f
            );
            float creature = smoothUnion(torso, head, scale * 0.18f);
            creature = min(creature, min(leftLeg, rightLeg));
            creature = smoothUnion(creature, min(leftArm, rightArm), scale * 0.08f);
            return min(creature, min(leftHorn, rightHorn));
        }
        case 2u: {
            float phase = instance.parameters.y;
            float d = 1.0e9f;
            uint count = uint(clamp(instance.parameters.x, 1.0f, 6.0f));
            for (uint i = 0u; i < count; ++i) {
                float f1 = fract(float(i) * 0.6180f + phase);
                float f2 = fract(float(i) * 0.3819f + phase * 1.7f);
                float angle = (float(i) + phase) * 2.3999f;
                float ringRadius = scale * (0.22f + 0.62f * f1);
                float3 base = float3(cos(angle) * ringRadius, -scale * 0.5f, sin(angle) * ringRadius);
                float stemHeight = scale * (0.34f + 0.26f * f2);
                float3 capCenter = base + float3(0.0f, stemHeight, 0.0f);
                float stem = sdCapsule(local, base, capCenter, scale * (0.045f + 0.025f * f1));
                float3 q = local - capCenter;
                float cap = (length(q * float3(1.0f, 1.8f, 1.0f)) - scale * (0.15f + 0.08f * f2)) * 0.55f;
                d = min(d, smoothUnion(stem, cap, scale * 0.06f));
            }
            return d;
        }
        case 3u:
            return fractalDistance(local / scale, fractalIterations) * scale;
        default:
            return sdSphere(local, scale);
    }
}

inline float3 sdfNormal(float3 point,
                        thread const SDFInstance &instance,
                        uint fractalIterations) {
    constexpr float epsilon = 0.002f;
    float3 x(epsilon, 0.0f, 0.0f);
    float3 y(0.0f, epsilon, 0.0f);
    float3 z(0.0f, 0.0f, epsilon);
    float3 gradient(
        distanceToInstance(point + x, instance, fractalIterations)
            - distanceToInstance(point - x, instance, fractalIterations),
        distanceToInstance(point + y, instance, fractalIterations)
            - distanceToInstance(point - y, instance, fractalIterations),
        distanceToInstance(point + z, instance, fractalIterations)
            - distanceToInstance(point - z, instance, fractalIterations)
    );
    float gradientLength = length(gradient);
    return isfinite(gradientLength) && gradientLength > 1.0e-8f
        ? gradient / gradientLength
        : float3(0.0f, 1.0f, 0.0f);
}

inline SDFInstance animateSDFInstance(thread const SDFInstance &source, float time) {
    SDFInstance instance = source;
    if (instance.metadata.x == 1u) {
        // Creature positions (wander + terrain re-grounding) are animated on
        // the CPU into the shared instance buffer each frame, so a wandering
        // figure stays planted on the slope it walked onto. Only the limb
        // gait phase is derived here.
        float phase = instance.parameters.y + time * 0.78f;
        instance.parameters.z = sin(phase * 2.0f);
        instance.parameters.w = cos(phase * 2.0f);
    }
    return instance;
}

inline Light animateLight(thread const Light &source, uint index, float time) {
    Light light = source;
    float phase = float(index) * 0.83f + time * 0.78f;
    light.positionRadius.x += sin(phase) * 2.2f;
    light.positionRadius.y += abs(sin(phase * 1.7f)) * 0.22f;
    light.positionRadius.z += cos(phase * 0.73f) * 1.5f;
    light.colorIntensity.w *= 0.45f + 0.55f * (0.5f + 0.5f * sin(time * 2.4f + float(index) * 1.37f));
    return light;
}

inline float homogeneousTransmittance(float extinction, float distance) {
    return exp(-max(extinction, 0.0f) * max(distance, 0.0f));
}

struct OpticalPath {
    float3 entryDirection;
    float3 exitDirection;
    float3 reflectionDirection;
    float3 transmission;
    float3 secondaryOrigin;
    uint totalInternalReflection;
    uint canTraceSecondary;
};

struct OpticalRayBudget {
    uint rayDepth;
    uint recursiveSecondaryRayCount;
};

inline bool traceOpticalSphere(float3 origin,
                               float3 direction,
                               float3 center,
                               float radius,
                               float indexOfRefraction,
                               float3 absorption,
                               thread OpticalPath &path,
                               thread OpticalRayBudget &opticalBudget) {
    if (opticalBudget.rayDepth != 0u) {
        ++opticalBudget.recursiveSecondaryRayCount;
    }
    float3 offset = origin - center;
    float projection = dot(offset, direction);
    float discriminant = projection * projection - dot(offset, offset) + radius * radius;
    if (discriminant < 0.0f) {
        return false;
    }
    float root = sqrt(discriminant);
    float nearT = -projection - root;
    float farT = -projection + root;
    if (farT <= kTraceEpsilon) {
        return false;
    }

    float safeIOR = max(indexOfRefraction, 1.0f);
    bool originInside = nearT <= kTraceEpsilon;
    float entryT = originInside ? farT : nearT;
    float3 entryPoint = origin + direction * entryT;
    float3 entryNormal = normalize(entryPoint - center);
    path.reflectionDirection = normalize(reflect(direction, entryNormal));
    path.totalInternalReflection = 0u;
    path.canTraceSecondary = 0u;

    if (originInside) {
        float3 exitDirection = refract(direction, -entryNormal, safeIOR);
        if (length_squared(exitDirection) <= 1.0e-8f) {
            path.entryDirection = direction;
            path.exitDirection = path.reflectionDirection;
            path.secondaryOrigin = entryPoint + entryNormal * 0.01f;
            path.transmission = exp(-max(absorption, float3(0.0f)) * entryT);
            path.totalInternalReflection = 1u;
            return true;
        }
        path.entryDirection = direction;
        path.exitDirection = normalize(exitDirection);
        path.secondaryOrigin = entryPoint + path.exitDirection * 0.01f;
        path.transmission = exp(-max(absorption, float3(0.0f)) * entryT);
        path.canTraceSecondary = 1u;
        return true;
    }

    float3 insideDirection = refract(direction, entryNormal, 1.0f / safeIOR);
    if (length_squared(insideDirection) <= 1.0e-8f) {
        path.entryDirection = path.reflectionDirection;
        path.exitDirection = path.reflectionDirection;
        path.secondaryOrigin = entryPoint + path.reflectionDirection * 0.01f;
        path.transmission = float3(0.0f);
        path.totalInternalReflection = 1u;
        return true;
    }
    insideDirection = normalize(insideDirection);
    float3 insideOrigin = entryPoint + insideDirection * kTraceEpsilon;
    float3 insideOffset = insideOrigin - center;
    float exitProjection = dot(insideOffset, insideDirection);
    float exitDiscriminant = exitProjection * exitProjection - dot(insideOffset, insideOffset) + radius * radius;
    float exitT = -exitProjection + sqrt(max(exitDiscriminant, 0.0f));
    float3 exitPoint = insideOrigin + insideDirection * exitT;
    float3 exitNormal = normalize(exitPoint - center);
    float3 exitDirection = refract(insideDirection, -exitNormal, safeIOR);
    path.entryDirection = insideDirection;
    path.transmission = exp(-max(absorption, float3(0.0f)) * exitT);
    if (length_squared(exitDirection) <= 1.0e-8f) {
        path.exitDirection = normalize(reflect(insideDirection, exitNormal));
        path.secondaryOrigin = exitPoint + exitNormal * 0.01f;
        path.totalInternalReflection = 1u;
        return true;
    }
    path.exitDirection = normalize(exitDirection);
    path.secondaryOrigin = exitPoint + path.exitDirection * 0.01f;
    path.canTraceSecondary = 1u;
    return true;
}

inline float fresnelSchlick(float cosine, float indexOfRefraction) {
    float ratio = (indexOfRefraction - 1.0f) / (indexOfRefraction + 1.0f);
    float baseReflectance = ratio * ratio;
    return baseReflectance + (1.0f - baseReflectance) * pow(1.0f - saturate(cosine), 5.0f);
}

inline float3 shadeSecondaryLighting(float3 point,
                                     float3 normal,
                                     float3 baseColor,
                                     float3 sunDirection,
                                     float ambient,
                                     thread OpticalRayBudget &opticalBudget) {
    float direct = max(dot(normal, sunDirection), 0.0f);
    return baseColor * (ambient + (1.0f - ambient) * direct);
}

inline float gaussianDensity(float3 point, thread const Gaussian &gaussian) {
    float3 delta = point - gaussian.localCenterSigma.xyz;
    float sigma = max(gaussian.localCenterSigma.w, 0.001f);
    return max(gaussian.colorDensity.w, 0.0f) * exp(-0.5f * dot(delta, delta) / (sigma * sigma));
}

inline float errorFunctionApproximation(float value) {
    float signValue = value < 0.0f ? -1.0f : 1.0f;
    float x = abs(value);
    float t = 1.0f / (1.0f + 0.3275911f * x);
    float polynomial = (((((1.061405429f * t - 1.453152027f) * t) + 1.421413741f) * t
                         - 0.284496736f) * t + 0.254829592f) * t;
    return signValue * (1.0f - polynomial * exp(-x * x));
}

inline float gaussianOpticalDepth(float3 origin,
                                  float3 direction,
                                  float minimumDistance,
                                  float maximumDistance,
                                  thread const Gaussian &gaussian) {
    float sigma = max(gaussian.localCenterSigma.w, 0.001f);
    float3 delta = gaussian.localCenterSigma.xyz - origin;
    float projection = dot(delta, direction);
    float perpendicularSquared = max(dot(delta, delta) - projection * projection, 0.0f);
    float amplitude = max(gaussian.colorDensity.w, 0.0f)
        * exp(-0.5f * perpendicularSquared / (sigma * sigma));
    float inverseScale = 1.0f / (sqrt(2.0f) * sigma);
    float integral = sigma * sqrt(0.5f * M_PI_F)
        * (errorFunctionApproximation((maximumDistance - projection) * inverseScale)
           - errorFunctionApproximation((minimumDistance - projection) * inverseScale));
    return max(amplitude * integral, 0.0f);
}

inline float gaussianSceneTransmittance(float3 origin,
                                        float3 direction,
                                        float minimumDistance,
                                        float maximumDistance,
                                        device const Gaussian *gaussians,
                                        uint gaussianCount) {
    float opticalDepth = 0.0f;
    for (uint index = 0u; index < min(gaussianCount, 48u); ++index) {
        Gaussian gaussian = gaussians[index];
        opticalDepth += gaussianOpticalDepth(
            origin, direction, minimumDistance, maximumDistance, gaussian
        );
    }
    return exp(-min(opticalDepth, 20.0f));
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

inline bool traceVoxelRange(texture3d<uint, access::read> volume,
                            float3 origin,
                            float3 direction,
                            float minimumDistance,
                            float maximumDistance,
                            uint stopLevel,
                            thread TraceHit &hit,
                            thread uint &stepCount) {
    float nearT;
    float farT;
    if (!intersectWorld(origin, direction, nearT, farT)) {
        return false;
    }
    nearT = max(nearT, minimumDistance);
    farT = min(farT, maximumDistance);
    if (farT <= nearT) {
        return false;
    }

    float3 inverseDirection = 1.0f / copysign(max(abs(direction), float3(1.0e-7f)), direction);
    float t = nearT;
    uint level = kTopMip;

    for (uint step = 0u; step < 4096u && t < farT; ++step) {
        ++stepCount;
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

inline bool traceVolume(texture3d<uint, access::read> volume,
                        float3 origin,
                        float3 direction,
                        float maximumDistance,
                        uint stopLevel,
                        thread TraceHit &hit) {
    uint stepCount = 0u;
    return traceVoxelRange(volume, origin, direction, 0.0f, maximumDistance, stopLevel, hit, stepCount);
}

inline bool intersectBounds(float3 origin,
                            float3 direction,
                            float3 minimum,
                            float3 maximum,
                            thread float &nearT,
                            thread float &farT) {
    float3 inverseDirection = 1.0f / copysign(max(abs(direction), float3(1.0e-7f)), direction);
    float3 a = (minimum - origin) * inverseDirection;
    float3 b = (maximum - origin) * inverseDirection;
    float3 nearPlane = min(a, b);
    float3 farPlane = max(a, b);
    nearT = max(nearPlane.x, max(nearPlane.y, nearPlane.z));
    farT = min(farPlane.x, min(farPlane.y, farPlane.z));
    return farT >= max(nearT, 0.0f);
}

inline bool originInsideBounds(float3 origin, float3 minimum, float3 maximum) {
    return all(origin >= minimum) && all(origin <= maximum);
}

inline int3 macroCellAt(float3 origin, float3 direction, float distance) {
    return int3(floor((origin + direction * (distance + kTraceEpsilon)) / 8.0f));
}

inline bool traceSDFInstance(float3 origin,
                            float3 direction,
                            float minimumDistance,
                            float maximumDistance,
                            thread const SDFInstance &instance,
                            constant SceneUniforms &scene,
                            thread HybridHit &hit,
                            thread TraceCounts &counts) {
    float nearT;
    float farT;
    if (!intersectBounds(origin, direction, instance.sweptBoundsMin.xyz,
                         instance.sweptBoundsMax.xyz, nearT, farT)) {
        return false;
    }
    if (instance.metadata.x == 4u) {
        float3 center = instance.positionScale.xyz;
        float radius = max(instance.positionScale.w, 0.001f);
        float3 offset = origin - center;
        float projection = dot(offset, direction);
        float discriminant = projection * projection - dot(offset, offset) + radius * radius;
        if (discriminant < 0.0f) {
            return false;
        }
        float root = sqrt(discriminant);
        float hitT = -projection - root;
        if (hitT < minimumDistance) {
            hitT = -projection + root;
        }
        if (hitT < minimumDistance || hitT > maximumDistance || hitT < 0.0f) {
            return false;
        }
        float3 point = origin + direction * hitT;
        hit.t = hitT;
        hit.normal = normalize(point - center);
        hit.material = instance.metadata.y;
        hit.primitiveKind = 2u;
        hit.stableID = instance.metadata.w;
        hit.opticalSphere = float4(center, radius);
        ++counts.sdfSamples;
        return true;
    }
    float t = max(minimumDistance, max(nearT, 0.0f));
    float limit = min(maximumDistance, farT);
    uint stepBudget = instance.metadata.x == 3u ? scene.budgets.z
        : (instance.metadata.x == 1u ? scene.budgets.y : scene.budgets.x);
    for (uint step = 0u; step < stepBudget && t <= limit; ++step) {
        float3 point = origin + direction * t;
        float distance = distanceToInstance(point, instance, scene.budgets.w);
        ++counts.sdfSamples;
        if (!isfinite(distance)) {
            ++counts.budgetOverflows;
            return false;
        }
        if (abs(distance) <= 0.0015f) {
            hit.t = t;
            hit.normal = sdfNormal(point, instance, scene.budgets.w);
            hit.material = instance.metadata.y;
            hit.primitiveKind = 1u;
            hit.stableID = instance.metadata.w;
            hit.opticalSphere = float4(0.0f);
            return true;
        }
        t += max(abs(distance) * 0.8f, 0.001f);
    }
    if (t <= limit) {
        ++counts.budgetOverflows;
    }
    return false;
}

inline bool traceMixedScene(texture3d<uint, access::read> voxels,
                            texture3d<uint, access::read> mixed,
                            device const CellHeader *headers,
                            device const uint *sdfRefs,
                            device const uint *gaussianRefs,
                            device const SDFInstance *sdfs,
                            device const Gaussian *gaussians,
                            constant SceneUniforms &scene,
                            float3 origin,
                            float3 direction,
                            float maximumDistance,
                            float time,
                            uint primitiveMask,
                            thread HybridHit &hit,
                            thread TraceCounts &counts) {
    float nearT;
    float farT;
    if (!intersectWorld(origin, direction, nearT, farT)) {
        return false;
    }
    farT = min(farT, maximumDistance);
    float t = nearT;
    float bestT = farT;
    HybridHit bestHit;
    bool found = false;
    uint level = min(scene.grid.z, 6u);
    float3 inverseDirection = 1.0f / copysign(max(abs(direction), float3(1.0e-7f)), direction);

    for (uint step = 0u; step < 4096u && t < farT; ++step) {
        ++counts.hierarchicalSteps;
        float3 point = origin + direction * (t + kTraceEpsilon);
        int3 macroCell = int3(floor(point / 8.0f));
        if (any(macroCell < int3(0)) || any(macroCell >= int3(64))) {
            break;
        }
        uint flags = mixed.read(uint3(macroCell) >> level, level).x;
        if (flags != 0u && level > 0u) {
            ++counts.macroDescents;
            --level;
            continue;
        }

        float nodeSize = 8.0f * float(1u << level);
        float3 nodeMinimum = floor(point / nodeSize) * nodeSize;
        float3 boundary = select(nodeMinimum, nodeMinimum + nodeSize, direction > 0.0f);
        float3 exits = (boundary - origin) * inverseDirection;
        float3 candidates = select(float3(INFINITY), exits, exits > t + kTraceEpsilon);
        float nodeExit = min(candidates.x, min(candidates.y, candidates.z));
        if (!isfinite(nodeExit)) {
            break;
        }

        if (flags == 0u) {
            ++counts.macroSkips;
            t = nodeExit + kTraceEpsilon;
            level = min(scene.grid.z, level + 1u);
            continue;
        }

        uint cellIndex = uint(macroCell.x) + 64u * (uint(macroCell.y) + 64u * uint(macroCell.z));
        CellHeader header = headers[cellIndex];
        if ((flags & 1u) != 0u) {
            TraceHit voxelHit;
            uint voxelSteps = 0u;
            if (traceVoxelRange(voxels, origin, direction, t, min(nodeExit, bestT), 0u, voxelHit, voxelSteps)
                && voxelHit.t < bestT) {
                bestT = voxelHit.t;
                bestHit.t = voxelHit.t;
                bestHit.normal = voxelHit.normal;
                bestHit.material = voxelHit.material;
                bestHit.primitiveKind = 0u;
                bestHit.stableID = 0xffffffffu;
                bestHit.opticalSphere = float4(0.0f);
                found = true;
            }
            counts.voxelSteps += voxelSteps;
        }

        uint sdfCount = min(header.packedCounts & 0xffffu, 8u);
        for (uint reference = 0u; reference < sdfCount; ++reference) {
            uint instanceIndex = sdfRefs[header.sdfOffset + reference];
            if (instanceIndex >= scene.counts.x) {
                ++counts.budgetOverflows;
                continue;
            }
            SDFInstance sourceInstance = sdfs[instanceIndex];
            uint candidateMask = sourceInstance.metadata.x == 4u ? 2u : 1u;
            if ((primitiveMask & candidateMask) == 0u) {
                continue;
            }
            SDFInstance instance = animateSDFInstance(sourceInstance, time);
            float sweptNear;
            float sweptFar;
            if (!intersectBounds(origin, direction, instance.sweptBoundsMin.xyz,
                                 instance.sweptBoundsMax.xyz, sweptNear, sweptFar)) {
                continue;
            }
            int3 evaluationCell = originInsideBounds(
                origin, instance.sweptBoundsMin.xyz, instance.sweptBoundsMax.xyz
            ) ? macroCellAt(origin, direction, 0.0f) : macroCellAt(origin, direction, max(sweptNear, 0.0f));
            if (any(evaluationCell != macroCell)) {
                continue;
            }
            HybridHit sdfHit;
            if (traceSDFInstance(origin, direction, t, bestT, instance, scene, sdfHit, counts)
                && sdfHit.t < bestT) {
                bestT = sdfHit.t;
                bestHit = sdfHit;
                found = true;
            }
        }

        uint gaussianCount = min(header.packedCounts >> 16u, 16u);
        for (uint reference = 0u; reference < gaussianCount; ++reference) {
            uint gaussianIndex = gaussianRefs[header.gaussianOffset + reference];
            if (gaussianIndex >= scene.counts.y) {
                ++counts.budgetOverflows;
                continue;
            }
            Gaussian gaussian = gaussians[gaussianIndex];
            float radius = max(gaussian.localCenterSigma.w, 0.001f) * 3.0f;
            float gaussianNear;
            float gaussianFar;
            if (intersectBounds(origin, direction, gaussian.localCenterSigma.xyz - radius,
                                gaussian.localCenterSigma.xyz + radius, gaussianNear, gaussianFar)
                && all(macroCellAt(origin, direction, max(gaussianNear, 0.0f)) == macroCell)) {
                ++counts.gaussianSamples;
            }
        }

        if (found && bestT <= nodeExit + kTraceEpsilon) {
            hit = bestHit;
            return true;
        }
        t = nodeExit + kTraceEpsilon;
        level = min(scene.grid.z, 1u);
    }
    if (counts.hierarchicalSteps >= 4096u) {
        ++counts.budgetOverflows;
    }
    if (found) {
        hit = bestHit;
    }
    return found;
}

inline bool traceMixedScene(texture3d<uint, access::read> voxels,
                            texture3d<uint, access::read> mixed,
                            device const CellHeader *headers,
                            device const uint *sdfRefs,
                            device const uint *gaussianRefs,
                            device const SDFInstance *sdfs,
                            device const Gaussian *gaussians,
                            constant SceneUniforms &scene,
                            float3 origin,
                            float3 direction,
                            float maximumDistance,
                            float time,
                            thread HybridHit &hit,
                            thread TraceCounts &counts) {
    return traceMixedScene(
        voxels, mixed, headers, sdfRefs, gaussianRefs, sdfs, gaussians, scene,
        origin, direction, maximumDistance, time, 3u, hit, counts
    );
}

inline bool traceMixedScene(texture3d<uint, access::read> voxels,
                            texture3d<uint, access::read> mixed,
                            device const CellHeader *headers,
                            device const uint *sdfRefs,
                            device const uint *gaussianRefs,
                            device const SDFInstance *sdfs,
                            device const Gaussian *gaussians,
                            constant SceneUniforms &scene,
                            float3 origin,
                            float3 direction,
                            float maximumDistance,
                            thread HybridHit &hit,
                            thread TraceCounts &counts) {
    return traceMixedScene(
        voxels, mixed, headers, sdfRefs, gaussianRefs, sdfs, gaussians, scene,
        origin, direction, maximumDistance, 0.0f, hit, counts
    );
}

inline bool traceOpticalScene(texture3d<uint, access::read> voxels,
                              texture3d<uint, access::read> mixed,
                              device const CellHeader *headers,
                              device const uint *sdfRefs,
                              device const uint *gaussianRefs,
                              device const SDFInstance *sdfs,
                              device const Gaussian *gaussians,
                              constant SceneUniforms &scene,
                              float3 origin,
                              float3 direction,
                              float maximumDistance,
                              float time,
                              uint primitiveMask,
                              thread HybridHit &hit,
                              thread TraceCounts &counts,
                              thread OpticalRayBudget &opticalBudget) {
    if (opticalBudget.rayDepth == 0u) {
        opticalBudget.rayDepth = 1u;
    } else {
        ++opticalBudget.recursiveSecondaryRayCount;
    }
    return traceMixedScene(
        voxels, mixed, headers, sdfRefs, gaussianRefs, sdfs, gaussians, scene,
        origin, direction, maximumDistance, time, primitiveMask, hit, counts
    );
}

inline bool traceOpticalScene(texture3d<uint, access::read> voxels,
                              texture3d<uint, access::read> mixed,
                              device const CellHeader *headers,
                              device const uint *sdfRefs,
                              device const uint *gaussianRefs,
                              device const SDFInstance *sdfs,
                              device const Gaussian *gaussians,
                              constant SceneUniforms &scene,
                              float3 origin,
                              float3 direction,
                              float maximumDistance,
                              float time,
                              thread HybridHit &hit,
                              thread TraceCounts &counts,
                              thread OpticalRayBudget &opticalBudget) {
    return traceOpticalScene(
        voxels, mixed, headers, sdfRefs, gaussianRefs, sdfs, gaussians, scene,
        origin, direction, maximumDistance, time, 3u, hit, counts, opticalBudget
    );
}

inline bool traceOcclusionExact(texture3d<uint, access::read> volume,
                                float3 origin,
                                float3 direction,
                                float maximumDistance,
                                thread TraceHit &hit) {
    return traceVolume(volume, origin, direction, maximumDistance, 0u, hit);
}

inline bool traceOcclusionReference(texture3d<uint, access::read> volume,
                                    float3 origin,
                                    float3 direction,
                                    float maximumDistance,
                                    thread TraceHit &hit) {
    float nearT;
    float farT;
    if (!intersectWorld(origin, direction, nearT, farT)) {
        return false;
    }
    farT = min(farT, maximumDistance);
    float3 inverseDirection = 1.0f / copysign(max(abs(direction), float3(1.0e-7f)), direction);
    float t = nearT;
    for (uint step = 0u; step < 4096u && t < farT; ++step) {
        float3 point = origin + direction * (t + kTraceEpsilon);
        int3 voxel = int3(floor(point));
        if (any(voxel < int3(0)) || any(voxel >= int3(kWorldSize))) {
            break;
        }
        uint material = volume.read(uint3(voxel), 0u).x;
        if (material != 0u) {
            float3 a = (float3(voxel) - origin) * inverseDirection;
            float3 b = (float3(voxel + 1) - origin) * inverseDirection;
            float3 entryPlane = min(a, b);
            uint axis = maximumAxis(entryPlane);
            hit.t = max(nearT, max(entryPlane.x, max(entryPlane.y, entryPlane.z)));
            hit.voxel = voxel;
            hit.normal = axisNormal(axis, direction);
            hit.material = material;
            return true;
        }
        float3 boundary = select(float3(voxel), float3(voxel + 1), direction > 0.0f);
        float3 exits = (boundary - origin) * inverseDirection;
        float3 candidates = select(float3(INFINITY), exits, exits > t + kTraceEpsilon);
        uint axis = minimumAxis(candidates);
        float nextT = candidates[axis];
        if (!isfinite(nextT)) {
            break;
        }
        t = nextT + kTraceEpsilon;
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
    return mix(normal.y > 0.5f ? 0.45f : 0.16f, 1.0f, ao);
}

constant float3 kFogColor = float3(0.44f, 0.47f, 0.52f);

inline float3 skyColor(float3 direction, float3 sunDirection) {
    constexpr float3 skyTop = float3(0.24f, 0.28f, 0.34f);
    constexpr float3 skyHorizon = float3(0.43f, 0.47f, 0.52f);
    constexpr float3 cloudDark = float3(0.27f, 0.29f, 0.34f);
    constexpr float3 cloudBright = float3(0.58f, 0.57f, 0.56f);
    constexpr float3 sunWarm = float3(1.05f, 0.68f, 0.48f);
    constexpr float3 warmBleed = float3(1.10f, 0.94f, 0.82f);
    float height = saturate(direction.y * 1.35f + 0.12f);
    float3 color = mix(skyHorizon, skyTop, height * height);
    float2 uv = direction.xz / max(direction.y, 0.06f);
    float clouds = valueNoise(uv.x * 1.7f, uv.y * 1.7f, 71) * 0.6f
        + valueNoise(uv.x * 4.3f, uv.y * 4.3f, 72) * 0.4f;
    float breakMask = saturate((clouds - 0.44f) / 0.30f);
    float3 deck = mix(cloudDark, cloudBright, breakMask);
    float sunDot = dot(direction, sunDirection);
    float wide = saturate((sunDot - 0.45f) / 0.55f);
    wide *= wide;
    deck *= mix(float3(1.0f), warmBleed, wide * (0.35f + 0.65f * breakMask));
    float window = saturate((sunDot - 0.84f) / 0.16f);
    window *= window;
    deck = mix(deck, sunWarm, window * (0.40f + 0.60f * breakMask));
    float deckAmount = saturate(direction.y * 5.0f);
    color = mix(color, deck, deckAmount * 0.85f);
    float3 haze = mix(kFogColor, sunWarm, wide * 0.35f);
    color = mix(color, haze, saturate(1.0f - abs(direction.y) * 3.0f));
    return color;
}
