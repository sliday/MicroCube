constant uint FEATURE_SHADOWS = 1u << 0u;
constant uint FEATURE_LIGHTS = 1u << 1u;
constant uint FEATURE_OPTICS = 1u << 2u;
constant uint FEATURE_SDF = 1u << 3u;
constant uint FEATURE_GAUSSIAN = 1u << 4u;
constant uint FEATURE_ALL = FEATURE_SHADOWS | FEATURE_LIGHTS | FEATURE_OPTICS | FEATURE_SDF | FEATURE_GAUSSIAN;
constant uint EVIDENCE_VIEW_SHIFT = 8u;
constant uint COUNTER_AGGREGATION = 1u << 16u;
constant uint RENDER_OPTIONS_VALID = 1u << 31u;

constant float3 kPalette[43] = {
    float3(0.000000f, 0.000000f, 0.000000f),
    float3(0.034020f, 0.034020f, 0.031500f),
    float3(0.040320f, 0.039816f, 0.036792f),
    float3(0.046620f, 0.045864f, 0.042336f),
    float3(0.050400f, 0.049140f, 0.045360f),
    float3(0.059220f, 0.057456f, 0.052920f),
    float3(0.068040f, 0.066024f, 0.060984f),
    float3(0.075600f, 0.072576f, 0.066024f),
    float3(0.086940f, 0.083664f, 0.076104f),
    float3(0.098280f, 0.094500f, 0.086184f),
    float3(0.090720f, 0.088200f, 0.075600f),
    float3(0.103320f, 0.100296f, 0.086184f),
    float3(0.115920f, 0.112392f, 0.097020f),
    float3(0.059220f, 0.052920f, 0.042840f),
    float3(0.068040f, 0.060984f, 0.049392f),
    float3(0.076860f, 0.069048f, 0.055944f),
    float3(0.064260f, 0.075600f, 0.055440f),
    float3(0.073080f, 0.085680f, 0.063000f),
    float3(0.081900f, 0.095760f, 0.070560f),
    float3(0.075600f, 0.084420f, 0.059220f),
    float3(0.085680f, 0.095760f, 0.067284f),
    float3(0.095760f, 0.107100f, 0.075600f),
    float3(0.078120f, 0.083160f, 0.070560f),
    float3(0.088200f, 0.093744f, 0.079632f),
    float3(0.098280f, 0.104580f, 0.088704f),
    float3(0.083160f, 0.075600f, 0.080640f),
    float3(0.093744f, 0.085680f, 0.091224f),
    float3(0.104580f, 0.095760f, 0.102060f),
    float3(0.086940f, 0.090720f, 0.078120f),
    float3(0.098280f, 0.102312f, 0.088200f),
    float3(0.109620f, 0.113904f, 0.098280f),
    float3(0.090720f, 0.094500f, 0.088200f),
    float3(0.102060f, 0.105840f, 0.099036f),
    float3(0.113400f, 0.117432f, 0.109872f),
    float3(0.085680f, 0.088200f, 0.086940f),
    float3(0.095760f, 0.098280f, 0.097020f),
    float3(0.105840f, 0.108360f, 0.107100f),
    float3(0.093240f, 0.095760f, 0.094500f),
    float3(0.104580f, 0.107100f, 0.105840f),
    float3(0.115920f, 0.118440f, 0.117180f),
    float3(0.103320f, 0.105084f, 0.103320f),
    float3(0.114660f, 0.116424f, 0.114660f),
    float3(0.126000f, 0.128016f, 0.126000f)
};

constant float kSeaLevel = 52.0f;

inline float terrainHeight(float wx, float wz) {
    float n = valueNoise(wx / 48.0f, wz / 48.0f, 7) * 0.55f
        + valueNoise(wx / 20.0f, wz / 20.0f, 8) * 0.30f
        + valueNoise(wx / 8.0f, wz / 8.0f, 9) * 0.15f;
    float ridge = 1.0f - abs(valueNoise(wx / 88.0f, wz / 88.0f, 10) * 2.0f - 1.0f);
    float land = 72.0f + (n - 0.5f) * 64.0f + ridge * ridge * 25.6f;
    float coast = valueNoise(wx / 56.0f, wz / 56.0f, 12) * 40.0f;
    float radius = length(float2(wx - 16.0f, wz - 28.0f));
    float shore = saturate((150.0f + coast - radius) / 72.0f);
    shore = shore * shore * (3.0f - 2.0f * shore);
    float seabed = 30.0f + (n - 0.5f) * 12.0f;
    return round(mix(seabed, land, shore));
}

inline float islandDensity(float wx, float y, float wz) {
    float distance = abs(y - 160.0f);
    if (distance > 112.0f) {
        return 0.0f;
    }
    return noise3D(wx / 80.0f, y / 48.0f, wz / 80.0f, 53) - distance / 112.0f;
}

kernel void generateTerrain(texture3d<uint, access::write> volume [[texture(0)]],
                            constant uint &qaTerrainFixture [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (any(gid >= uint2(kWorldSize))) {
        return;
    }

    if (qaTerrainFixture != 0u) {
        for (uint y = 0u; y < kWorldSize; ++y) {
            bool blocker = qaTerrainFixture == 2u
                && gid.x >= 248u && gid.x < 352u
                && y >= 136u && y < 140u
                && gid.y >= 272u && gid.y < 352u;
            volume.write(uint4(blocker ? 1u : 0u), uint3(gid.x, y, gid.y));
        }
        return;
    }

    int wx = int(gid.x) - 256;
    int wz = int(gid.y) - 256;
    int height = clamp(int(terrainHeight(float(wx), float(wz))), 0, 512);

    for (uint blockY = 0u; blockY < kWorldSize; blockY += 4u) {
        for (uint lane = 0u; lane < 4u; ++lane) {
            uint y = blockY + lane;
            bool belowGround = int(y) < height;
            float cave = belowGround
                ? abs(noise3D(float(wx) / 36.0f, float(y) / 36.0f, float(wz) / 36.0f, 41) - 0.5f)
                : 1.0f;
            bool solid = belowGround
                && !(cave < 0.045f && (int(y) < height - 8 || cave < 0.01575f));
            uint material = 0u;

            if (solid) {
                int depthVoxels = height - 1 - int(y);
                float level = (float(height) - 40.0f) / 64.0f
                    + (valueNoise(float(wx) / 24.0f, float(wz) / 24.0f, 31) - 0.5f) * 0.28f;
                float band = valueNoise(float(wx) / 160.0f, float(wz) / 160.0f, 21) * 6.0f
                    + float(y) / 10.0f;
                int surfaceBand = clamp(int(level * 14.0f), 0, 13);
                int materialBand = depthVoxels == 0 ? surfaceBand
                    : (depthVoxels == 1 ? max(0, surfaceBand - 1) : ((int(floor(band)) % 14) + 14) % 14);
                uint shade = min(2u, uint(hash2(wx * 7 + int(y), wz * 13 + int(y), 5) * 3.0f));
                material = 1u + uint(materialBand) * 3u + shade;
                if (hash2(wx * 3, wz * 5, int(y)) > 0.70f) {
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

kernel void buildMixedOccupancy(texture3d<uint, access::read> voxels [[texture(0)]],
                                texture3d<uint, access::write> mixed [[texture(1)]],
                                device const CellHeader *headers [[buffer(0)]],
                                device const uint *cellSDFRefs [[buffer(1)]],
                                device const SDFInstance *sdfs [[buffer(2)]],
                                uint3 gid [[thread_position_in_grid]]) {
    if (any(gid >= uint3(64u))) {
        return;
    }
    uint index = gid.x + 64u * (gid.y + 64u * gid.z);
    CellHeader header = headers[index];
    uint flags = voxels.read(gid, 3u).x != 0u ? 1u : 0u;
    uint sdfCount = header.packedCounts & 0xffffu;
    flags |= sdfCount != 0u ? 2u : 0u;
    flags |= (header.packedCounts >> 16u) != 0u ? 4u : 0u;
    for (uint i = 0u; i < sdfCount; ++i) {
        uint4 metadata = sdfs[cellSDFRefs[header.sdfOffset + i]].metadata;
        flags |= (metadata.z & SDF_FLAG_EMISSIVE) != 0u ? 8u : 0u;
        flags |= metadata.x == SDF_KIND_FRACTAL ? 16u : 0u;
    }
    mixed.write(uint4(flags), gid);
}

kernel void reduceMixedOccupancy(texture3d<uint, access::read> source [[texture(0)]],
                                 texture3d<uint, access::write> destination [[texture(1)]],
                                 uint3 gid [[thread_position_in_grid]]) {
    uint3 destinationSize(destination.get_width(), destination.get_height(), destination.get_depth());
    if (any(gid >= destinationSize)) {
        return;
    }

    uint3 sourceOrigin = gid * 2u;
    uint flags = 0u;
    for (uint z = 0u; z < 2u; ++z) {
        for (uint y = 0u; y < 2u; ++y) {
            for (uint x = 0u; x < 2u; ++x) {
                flags |= source.read(sourceOrigin + uint3(x, y, z)).x;
            }
        }
    }
    destination.write(uint4(flags), gid);
}

kernel void clearVolumeLighting(texture3d<half, access::write> volumeLighting [[texture(2)]],
                                uint3 gid [[thread_position_in_grid]]) {
    if (any(gid >= uint3(64u))) {
        return;
    }
    volumeLighting.write(half4(0.0h, 0.0h, 0.0h, 1.0h), gid);
}

kernel void injectVolumeLighting(
    texture3d<uint, access::read> voxels [[texture(0)]],
    texture3d<half, access::write> volumeLighting [[texture(2)]],
    constant FrameUniforms &frame [[buffer(0)]],
    constant SceneUniforms &scene [[buffer(1)]],
    device const Gaussian *gaussians [[buffer(6)]],
    device const Light *lights [[buffer(7)]],
    device const uint *activeVolumeCells [[buffer(9)]],
    device FrameCounters *frameCounters [[buffer(10)]],
    uint gid [[thread_position_in_grid]],
    uint simdLane [[thread_index_in_simdgroup]]) {
    bool inRange = gid < scene.grid.w;
    uint safeGID = min(gid, max(scene.grid.w, 1u) - 1u);
    uint options = frame.viewportAndOptions.w;
    if ((options & RENDER_OPTIONS_VALID) == 0u) {
        options |= FEATURE_ALL;
    }
    bool shadowsEnabled = (options & FEATURE_SHADOWS) != 0u;
    bool lightsEnabled = (options & FEATURE_LIGHTS) != 0u;
    bool gaussianEnabled = (options & FEATURE_GAUSSIAN) != 0u;
    uint volumeSunShadow = 0u;
    uint volumeLocalShadow = 0u;
    uint linearIndex = activeVolumeCells[safeGID];
    uint3 cell(
        linearIndex & 63u,
        (linearIndex >> 6u) & 63u,
        (linearIndex >> 12u) & 63u
    );
    float3 point = (float3(cell) + 0.5f) * 8.0f;
    float3 sunDirection = normalize(frame.sunDirectionAndAmbient.xyz);
    float sunVisibility = 1.0f;
    if (shadowsEnabled) {
        TraceHit shadowHit;
        sunVisibility = traceOcclusionExact(
            voxels, point + sunDirection * 0.04f, sunDirection, 192.0f, shadowHit
        ) ? 0.08f : 1.0f;
        volumeSunShadow = 1u;
    }
    if (shadowsEnabled && gaussianEnabled) {
        sunVisibility *= gaussianSceneTransmittance(
            point, sunDirection, 0.05f, 192.0f, gaussians, scene.counts.y
        );
    }
    float3 radiance = float3(0.085f, 0.095f, 0.115f) + float3(0.92f, 0.84f, 0.76f) * sunVisibility * 0.72f;

    uint strongestIndex = 0u;
    float strongestScore = -1.0f;
    for (uint index = 0u; index < min(scene.counts.z, lightsEnabled ? 6u : 0u); ++index) {
        Light source = lights[index];
        Light light = animateLight(source, index, frame.cameraPositionAndTime.w);
        float3 delta = light.positionRadius.xyz - point;
        float distanceSquared = max(dot(delta, delta), 1.0f);
        float score = light.colorIntensity.w / distanceSquared;
        if (score > strongestScore) {
            strongestScore = score;
            strongestIndex = index;
        }
    }
    for (uint index = 0u; index < min(scene.counts.z, lightsEnabled ? 6u : 0u); ++index) {
        Light source = lights[index];
        Light light = animateLight(source, index, frame.cameraPositionAndTime.w);
        float3 delta = light.positionRadius.xyz - point;
        float distance = max(length(delta), 0.01f);
        if (distance >= light.positionRadius.w) {
            continue;
        }
        float3 lightDirection = delta / distance;
        float visibility = shadowsEnabled && gaussianEnabled ? gaussianSceneTransmittance(
            point, lightDirection, 0.05f, distance, gaussians, scene.counts.y
        ) : 1.0f;
        if (index == strongestIndex && shadowsEnabled) {
            TraceHit localShadow;
            if (traceOcclusionExact(voxels, point + lightDirection * 0.04f,
                                    lightDirection, distance - 0.08f, localShadow)) {
                visibility *= 0.08f;
            }
            volumeLocalShadow = 1u;
        }
        float falloff = 1.0f - distance / light.positionRadius.w;
        radiance += light.colorIntensity.xyz * light.colorIntensity.w
            * falloff * falloff * visibility * 0.22f;
    }
    if ((options & COUNTER_AGGREGATION) != 0u) {
        uint sunSum = simd_sum(inRange && gaussianEnabled ? volumeSunShadow : 0u);
        uint localSum = simd_sum(inRange && gaussianEnabled ? volumeLocalShadow : 0u);
        if (simdLane == 0u) {
            atomic_fetch_add_explicit(&frameCounters->volumeSunShadows, sunSum, memory_order_relaxed);
            atomic_fetch_add_explicit(&frameCounters->volumeLocalShadows, localSum, memory_order_relaxed);
        }
    }
    if (inRange) {
        half3 outputRadiance = gaussianEnabled ? half3(radiance) : half3(0.0h);
        volumeLighting.write(half4(outputRadiance, half(sunVisibility)), cell);
    }
}

inline float3 shadeSecondaryHit(float3 point,
                                float3 normal,
                                float3 baseColor,
                                float3 sunDirection,
                                float ambient,
                                bool lightsEnabled,
                                device const Light *lights,
                                constant SceneUniforms &scene,
                                float time,
                                thread OpticalRayBudget &secondaryOpticalBudget) {
    float3 color = shadeSecondaryLighting(
        point, normal, baseColor, sunDirection, ambient, secondaryOpticalBudget
    );
    for (uint index = 0u; index < min(scene.counts.z, lightsEnabled ? 6u : 0u); ++index) {
        Light source = lights[index];
        Light light = animateLight(source, index, time);
        float3 delta = light.positionRadius.xyz - point;
        float distance = max(length(delta), 0.01f);
        if (distance >= light.positionRadius.w) {
            continue;
        }
        float falloff = 1.0f - distance / light.positionRadius.w;
        float diffuse = max(dot(normal, delta / distance), 0.0f);
        color += baseColor * light.colorIntensity.xyz * light.colorIntensity.w
            * diffuse * falloff * falloff * 0.12f;
    }
    return color;
}

inline float3 shadeSecondaryHit(float3 point,
                                float3 normal,
                                float3 baseColor,
                                float3 sunDirection,
                                float ambient,
                                device const Light *lights,
                                constant SceneUniforms &scene,
                                float time,
                                thread OpticalRayBudget &secondaryOpticalBudget) {
    return shadeSecondaryHit(
        point, normal, baseColor, sunDirection, ambient, true, lights, scene,
        time, secondaryOpticalBudget
    );
}

inline void aggregateFrameCounters(thread const TraceCounts &counts,
                                   uint secondaryRays,
                                   uint surfaceSunShadows,
                                   uint surfaceLocalShadows,
                                   bool active,
                                   device FrameCounters *frameCounters,
                                   uint simdLane) {
    uint macroSkips = simd_sum(active ? counts.macroSkips : 0u);
    uint macroDescents = simd_sum(active ? counts.macroDescents : 0u);
    uint voxelSteps = simd_sum(active ? counts.voxelSteps : 0u);
    uint sdfSamples = simd_sum(active ? counts.sdfSamples : 0u);
    uint gaussianSamples = simd_sum(active ? counts.gaussianSamples : 0u);
    uint secondary = simd_sum(active ? secondaryRays : 0u);
    uint sunShadows = simd_sum(active ? surfaceSunShadows : 0u);
    uint localShadows = simd_sum(active ? surfaceLocalShadows : 0u);
    uint overflows = simd_sum(active ? counts.budgetOverflows : 0u);
    if (simdLane == 0u) {
        atomic_fetch_add_explicit(&frameCounters->macroSkips, macroSkips, memory_order_relaxed);
        atomic_fetch_add_explicit(&frameCounters->macroDescents, macroDescents, memory_order_relaxed);
        atomic_fetch_add_explicit(&frameCounters->voxelSteps, voxelSteps, memory_order_relaxed);
        atomic_fetch_add_explicit(&frameCounters->sdfSamples, sdfSamples, memory_order_relaxed);
        atomic_fetch_add_explicit(&frameCounters->gaussianSamples, gaussianSamples, memory_order_relaxed);
        atomic_fetch_add_explicit(&frameCounters->secondaryRays, secondary, memory_order_relaxed);
        atomic_fetch_add_explicit(&frameCounters->surfaceSunShadows, sunShadows, memory_order_relaxed);
        atomic_fetch_add_explicit(&frameCounters->surfaceLocalShadows, localShadows, memory_order_relaxed);
        atomic_fetch_add_explicit(&frameCounters->budgetOverflows, overflows, memory_order_relaxed);
    }
}

inline float3 qaPrimitiveIDColor(bool hasHit, uint primitiveKind, uint stableID) {
    if (!hasHit) {
        return float3(0.0f);
    }
    uint hash = stableID ^ ((primitiveKind + 1u) * 0x9e3779b9u);
    hash ^= hash >> 16u;
    hash *= 0x7feb352du;
    hash ^= hash >> 15u;
    return 0.2f + 0.8f * float3(
        float(hash & 0xffu),
        float((hash >> 8u) & 0xffu),
        float((hash >> 16u) & 0xffu)
    ) / 255.0f;
}

inline float3 qaNormalColor(bool hasHit, float3 normal) {
    return hasHit ? normal * 0.5f + 0.5f : float3(0.0f);
}

inline float3 qaShadowMismatchColor(bool comparable, bool exactShadow, bool legacyShadow) {
    if (!comparable || exactShadow == legacyShadow) {
        return float3(0.0f);
    }
    return exactShadow ? float3(1.0f, 0.25f, 0.0f) : float3(1.0f, 0.0f, 1.0f);
}

kernel void raycastHybrid(
    texture3d<uint, access::read> volume [[texture(0)]],
    texture3d<uint, access::read> mixed [[texture(1)]],
    texture3d<half, access::read> volumeLighting [[texture(2)]],
    texture2d<float, access::write> output [[texture(3)]],
    constant FrameUniforms &uniforms [[buffer(0)]],
    constant SceneUniforms &scene [[buffer(1)]],
    device const CellHeader *headers [[buffer(2)]],
    device const uint *sdfRefs [[buffer(3)]],
    device const uint *gaussianRefs [[buffer(4)]],
    device const SDFInstance *sdfs [[buffer(5)]],
    device const Gaussian *gaussians [[buffer(6)]],
    device const Light *lights [[buffer(7)]],
    device const Material *materials [[buffer(8)]],
    device FrameCounters *frameCounters [[buffer(10)]],
    uint2 gid [[thread_position_in_grid]],
    uint simdLane [[thread_index_in_simdgroup]]) {
    uint2 viewport = uniforms.viewportAndOptions.xy;
    bool active = all(gid < viewport);
    uint2 pixelGID = min(gid, max(viewport, uint2(1u)) - 1u);
    uint options = uniforms.viewportAndOptions.w;
    if ((options & RENDER_OPTIONS_VALID) == 0u) {
        options |= FEATURE_ALL;
    }
    uint evidenceView = (options >> EVIDENCE_VIEW_SHIFT) & 0xffu;
    bool shadowsEnabled = (options & FEATURE_SHADOWS) != 0u;
    bool lightsEnabled = (options & FEATURE_LIGHTS) != 0u;
    bool opticsEnabled = (options & FEATURE_OPTICS) != 0u;
    bool sdfEnabled = (options & FEATURE_SDF) != 0u;
    bool gaussianEnabled = (options & FEATURE_GAUSSIAN) != 0u;
    uint primitiveMask = (sdfEnabled ? 1u : 0u) | (opticsEnabled ? 2u : 0u);
    uint secondaryRays = 0u;
    uint surfaceSunShadows = 0u;
    uint surfaceLocalShadows = 0u;
    bool surfaceShadowComparable = false;
    bool surfaceExactShadow = false;
    bool surfaceReferenceShadow = false;

    float2 pixel = float2(pixelGID) + 0.5f;
    float horizontal = (2.0f * pixel.x / float(viewport.x) - 1.0f)
        * uniforms.cameraForwardAndFOV.w * uniforms.cameraRightAndAspect.w;
    float vertical = (1.0f - 2.0f * pixel.y / float(viewport.y)) * uniforms.cameraForwardAndFOV.w;
    float3 direction = normalize(uniforms.cameraForwardAndFOV.xyz
        + uniforms.cameraRightAndAspect.xyz * horizontal
        + uniforms.cameraUpAndMaxDistance.xyz * vertical);
    float3 origin = uniforms.cameraPositionAndTime.xyz;
    float3 sunDirection = normalize(uniforms.sunDirectionAndAmbient.xyz);
    float3 color;
    HybridHit hit;
    TraceCounts counts = {};
    bool hasHit = traceMixedScene(
        volume, mixed, headers, sdfRefs, gaussianRefs, sdfs, gaussians, scene,
        origin, direction, uniforms.cameraUpAndMaxDistance.w,
        uniforms.cameraPositionAndTime.w, primitiveMask, hit, counts
    );

    if (hasHit) {
        float3 point = origin + direction * hit.t;
        bool isGlass = opticsEnabled && hit.primitiveKind == 2u;
        float diffuse = max(0.0f, dot(hit.normal, sunDirection));
        float lighting = uniforms.sunDirectionAndAmbient.w
            + (1.0f - uniforms.sunDirectionAndAmbient.w) * diffuse;
        lighting *= hit.normal.y > 0.0f ? 1.0f : (hit.normal.y < 0.0f ? 0.62f : (hit.normal.x != 0.0f ? 0.82f : 0.9f));
        if (hit.primitiveKind == 0u) {
            lighting *= voxelAO(volume, point, hit.normal);
        }

        if ((shadowsEnabled || evidenceView == 7u) && !isGlass && diffuse > 0.0f) {
            TraceHit exactShadowHit;
            surfaceSunShadows = 1u;
            surfaceExactShadow = traceOcclusionExact(
                volume, point + hit.normal * 0.035f, sunDirection, 100.0f, exactShadowHit
            );
            if (evidenceView == 7u) {
                TraceHit referenceShadowHit;
                surfaceShadowComparable = true;
                surfaceReferenceShadow = traceOcclusionReference(
                    volume, point + hit.normal * 0.035f, sunDirection, 100.0f, referenceShadowHit
                );
            }
            if (shadowsEnabled && surfaceExactShadow) {
                lighting *= 0.22f;
            }
        }

        uint materialIndex = hit.primitiveKind == 0u
            ? 0u : min(hit.material, max(scene.counts.w, 1u) - 1u);
        float3 baseColor = hit.primitiveKind == 0u
            ? kPalette[min(hit.material, 42u)]
            : materials[materialIndex].baseColorRoughness.xyz;
        float structure = 0.5f;
        if (hit.primitiveKind == 0u) {
            float patch = noise3D(point.x * 0.6f, point.y * 0.6f, point.z * 0.6f, 89);
            float fine = noise3D(point.x * 1.9f, point.y * 1.9f, point.z * 1.9f, 83);
            float speckle = hash2(
                int(floor(point.x * 3.0f)) * 131 + int(floor(point.y * 3.0f)),
                int(floor(point.z * 3.0f)), 97
            );
            float grain = noise3D(point.x * 5.5f, point.y * 5.5f, point.z * 5.5f, 79);
            float breakup = patch * 0.62f + fine * 0.28f + speckle * 0.10f;
            breakup = breakup * breakup * (3.0f - 2.0f * breakup);
            baseColor *= 0.62f + breakup * 0.76f;
            if (hit.normal.y > 0.5f) {
                float turfNoise = patch * 0.72f + fine * 0.28f;
                float turfMask = smoothstep(0.46f, 0.52f, turfNoise + (grain - 0.5f) * 0.10f)
                    * saturate(1.0f - abs(point.y - 74.0f) / 26.0f);
                float tuft = speckle > 0.86f ? 1.0f : 0.0f;
                structure = mix(0.28f, 0.72f, turfMask) + tuft * 0.30f + (grain - 0.5f) * 0.12f;
                baseColor = mix(baseColor, baseColor * float3(0.55f, 1.35f, 0.45f), turfMask);
                baseColor = mix(baseColor, baseColor * float3(0.95f, 1.10f, 0.72f), tuft * 0.6f);
            } else if (hit.normal.y < -0.5f) {
                structure = 0.5f + (grain - 0.5f) * 0.32f;
            } else {
                float horiz = hit.normal.x != 0.0f ? point.z : point.x;
                int column = int(floor(horiz * 1.1f));
                float columnHash = hash2(column, 0, 113);
                float columnFrac = fract(horiz * 1.1f);
                float jointEdge = min(columnFrac, 1.0f - columnFrac);
                float jointDepth = 0.16f + fract(columnHash * 5.7f) * 0.26f;
                float jointMask = columnHash > 0.58f ? saturate(1.0f - jointEdge / 0.05f) : 0.0f;
                float jitter = (fine - 0.5f) * 0.30f + (grain - 0.5f) * 0.18f;
                float shift = (columnHash - 0.5f) * 0.55f + horiz * 0.07f;
                float bedA = point.y * 2.6f + shift + jitter * 1.6f;
                float bedFracA = fract(bedA);
                float hashA = hash2(int(floor(bedA)), 1, 71);
                float seamA = hashA > 0.30f
                    ? (1.0f - saturate(bedFracA / (0.10f + hashA * 0.16f)))
                        * (0.12f + fract(hashA * 9.7f) * 0.30f)
                    : 0.0f;
                float bedB = point.y * 1.1f + shift * 0.7f + jitter;
                float bedFracB = fract(bedB);
                float hashB = hash2(int(floor(bedB)), 2, 71);
                float seamB = hashB > 0.45f
                    ? (1.0f - saturate(bedFracB / (0.07f + hashB * 0.10f)))
                        * (0.26f + fract(hashB * 7.3f) * 0.22f)
                    : 0.0f;
                float lightBed = fract(hashA * 7.13f) > 0.76f ? 0.20f : 0.0f;
                float facet = (floor(grain * 4.0f) * 0.3333f - 0.5f) * 0.28f;
                float wetZone = saturate((kSeaLevel + 9.0f - point.y) / 9.0f);
                float sparkle = speckle > 0.90f
                    ? 0.55f * max(wetZone, saturate(seamA * 3.0f))
                    : 0.0f;
                structure = saturate(
                    0.54f + lightBed + facet + sparkle
                    - seamA - seamB - jointMask * jointDepth
                );
                float rockiness = saturate((point.y - 88.0f) / 18.0f);
                float3 grey = float3(dot(baseColor, float3(0.3333f)));
                baseColor = mix(baseColor, grey, rockiness * 0.6f);
            }
            float wet = saturate((kSeaLevel + 3.5f - point.y) / 3.5f);
            baseColor = mix(baseColor, baseColor * float3(0.30f, 0.36f, 0.44f), wet * 0.9f);
            float2 faceFrac = hit.normal.x != 0.0f ? fract(point.yz)
                : (hit.normal.y != 0.0f ? fract(point.xz) : fract(point.xy));
            float edgeDistance = min(
                min(faceFrac.x, 1.0f - faceFrac.x),
                min(faceFrac.y, 1.0f - faceFrac.y)
            );
            float crackFloor = hit.normal.y > 0.5f ? 0.82f : 0.50f + speckle * 0.22f;
            baseColor *= crackFloor + (1.0f - crackFloor) * saturate(edgeDistance / 0.11f);
        }
        bool isReflective = !isGlass && hit.primitiveKind != 0u
            && materials[materialIndex].emissionMetalness.w > 0.0f;
        color = baseColor * lighting
            * mix(float3(0.84f, 0.90f, 1.10f), float3(1.14f, 0.97f, 0.84f), saturate(diffuse * 2.5f));
        uint selectedMask = 0u;
        for (uint selection = 0u;
             selection < min(scene.counts.z, lightsEnabled && !isGlass ? 4u : 0u);
             ++selection) {
            uint bestIndex = 0u;
            float bestScore = -1.0f;
            for (uint index = 0u; index < min(scene.counts.z, 6u); ++index) {
                if ((selectedMask & (1u << index)) != 0u) continue;
                Light source = lights[index];
                Light light = animateLight(source, index, uniforms.cameraPositionAndTime.w);
                float3 delta = light.positionRadius.xyz - point;
                float score = light.colorIntensity.w / max(dot(delta, delta), 1.0f);
                if (score > bestScore) {
                    bestScore = score;
                    bestIndex = index;
                }
            }
            selectedMask |= 1u << bestIndex;
            Light source = lights[bestIndex];
            Light light = animateLight(source, bestIndex, uniforms.cameraPositionAndTime.w);
            float3 delta = light.positionRadius.xyz - point;
            float distance = max(length(delta), 0.01f);
            if (distance >= light.positionRadius.w) continue;
            float3 lightDirection = delta / distance;
            float falloff = 1.0f - distance / light.positionRadius.w;
            float visibility = shadowsEnabled && gaussianEnabled ? gaussianSceneTransmittance(
                point + hit.normal * 0.04f, lightDirection, 0.05f, distance,
                gaussians, scene.counts.y
            ) : 1.0f;
            if (selection == 0u && shadowsEnabled) {
                TraceHit localShadow;
                surfaceLocalShadows = 1u;
                if (traceOcclusionExact(volume, point + hit.normal * 0.04f,
                                        lightDirection, distance - 0.08f, localShadow)) {
                    visibility *= 0.08f;
                }
            }
            float diffuseLocal = max(dot(hit.normal, lightDirection), 0.0f);
            color += baseColor * light.colorIntensity.xyz * light.colorIntensity.w
                * diffuseLocal * falloff * falloff * visibility * 0.12f;
        }
        if (hit.primitiveKind == 0u) {
            color = color * mix(0.62f, 1.38f, structure) + (structure - 0.5f) * 0.016f;
        }
        if (hit.primitiveKind != 0u) {
            color += materials[materialIndex].emissionMetalness.xyz;
        }
        if (isGlass && opticsEnabled) {
            OpticalPath path;
            OpticalRayBudget primaryOpticalBudget = {0u, 0u};
            Material material = materials[materialIndex];
            if (traceOpticalSphere(
                origin, direction, hit.opticalSphere.xyz, hit.opticalSphere.w,
                material.opticalAbsorptionIOR.w, material.opticalAbsorptionIOR.xyz, path, primaryOpticalBudget
            )) {
                if (path.totalInternalReflection != 0u || path.canTraceSecondary == 0u) {
                    color = skyColor(path.reflectionDirection, sunDirection);
                } else {
                    HybridHit secondaryHit;
                    TraceCounts secondaryCounts = {};
                    OpticalRayBudget secondaryOpticalBudget = {0u, 0u};
                    bool secondaryFound = traceOpticalScene(
                        volume, mixed, headers, sdfRefs, gaussianRefs, sdfs, gaussians, scene,
                        path.secondaryOrigin, path.exitDirection, uniforms.cameraUpAndMaxDistance.w,
                        uniforms.cameraPositionAndTime.w, primitiveMask,
                        secondaryHit, secondaryCounts, secondaryOpticalBudget
                    );
                    secondaryRays += 1u;
                    counts.hierarchicalSteps += secondaryCounts.hierarchicalSteps;
                    counts.macroSkips += secondaryCounts.macroSkips;
                    counts.macroDescents += secondaryCounts.macroDescents;
                    counts.voxelSteps += secondaryCounts.voxelSteps;
                    counts.sdfSamples += secondaryCounts.sdfSamples;
                    counts.gaussianSamples += secondaryCounts.gaussianSamples;
                    counts.budgetOverflows += secondaryCounts.budgetOverflows;
                    float3 transmittedColor = skyColor(path.exitDirection, sunDirection);
                    if (secondaryFound) {
                        uint secondaryMaterial = secondaryHit.primitiveKind == 0u
                            ? 0u : min(secondaryHit.material, max(scene.counts.w, 1u) - 1u);
                        float3 secondaryBase = secondaryHit.primitiveKind == 0u
                            ? kPalette[min(secondaryHit.material, 42u)]
                            : materials[secondaryMaterial].baseColorRoughness.xyz;
                        transmittedColor = shadeSecondaryHit(
                            path.secondaryOrigin + path.exitDirection * secondaryHit.t, secondaryHit.normal,
                            secondaryBase, sunDirection, uniforms.sunDirectionAndAmbient.w,
                            lightsEnabled, lights, scene,
                            uniforms.cameraPositionAndTime.w, secondaryOpticalBudget
                        );
                        if (secondaryHit.primitiveKind != 0u) {
                            transmittedColor += materials[secondaryMaterial].emissionMetalness.xyz;
                        }
                    }
                    float reflection = fresnelSchlick(
                        max(dot(-direction, hit.normal), 0.0f), material.opticalAbsorptionIOR.w
                    );
                    color = mix(transmittedColor * path.transmission,
                                skyColor(path.reflectionDirection, sunDirection), reflection);
                }
            }
        } else if (isReflective && opticsEnabled) {
            float3 reflectionDirection = normalize(reflect(direction, hit.normal));
            HybridHit secondaryHit;
            TraceCounts secondaryCounts = {};
            OpticalRayBudget secondaryOpticalBudget = {0u, 0u};
            bool secondaryFound = traceOpticalScene(
                volume, mixed, headers, sdfRefs, gaussianRefs, sdfs, gaussians, scene,
                point + hit.normal * 0.01f, reflectionDirection, uniforms.cameraUpAndMaxDistance.w,
                uniforms.cameraPositionAndTime.w, primitiveMask,
                secondaryHit, secondaryCounts, secondaryOpticalBudget
            );
            secondaryRays += 1u;
            counts.hierarchicalSteps += secondaryCounts.hierarchicalSteps;
            counts.macroSkips += secondaryCounts.macroSkips;
            counts.macroDescents += secondaryCounts.macroDescents;
            counts.voxelSteps += secondaryCounts.voxelSteps;
            counts.sdfSamples += secondaryCounts.sdfSamples;
            counts.gaussianSamples += secondaryCounts.gaussianSamples;
            counts.budgetOverflows += secondaryCounts.budgetOverflows;
            float3 reflectionColor = skyColor(reflectionDirection, sunDirection);
            if (secondaryFound) {
                uint secondaryMaterial = secondaryHit.primitiveKind == 0u
                    ? 0u : min(secondaryHit.material, max(scene.counts.w, 1u) - 1u);
                float3 secondaryBase = secondaryHit.primitiveKind == 0u
                    ? kPalette[min(secondaryHit.material, 42u)]
                    : materials[secondaryMaterial].baseColorRoughness.xyz;
                reflectionColor = shadeSecondaryHit(
                    point + reflectionDirection * secondaryHit.t, secondaryHit.normal,
                    secondaryBase, sunDirection, uniforms.sunDirectionAndAmbient.w,
                    lightsEnabled, lights, scene,
                    uniforms.cameraPositionAndTime.w, secondaryOpticalBudget
                );
                if (secondaryHit.primitiveKind != 0u) {
                    reflectionColor += materials[secondaryMaterial].emissionMetalness.xyz;
                }
            }
            color = mix(color, reflectionColor, saturate(materials[materialIndex].emissionMetalness.w));
        }
        float fogStart = uniforms.cameraUpAndMaxDistance.w * uniforms.fogAndExposure.x;
        float fogEnd = uniforms.cameraUpAndMaxDistance.w * uniforms.fogAndExposure.y;
        float fog = saturate((hit.t - fogStart) / max(0.001f, fogEnd - fogStart));
        color = mix(color, kFogColor, fog);
    } else {
        color = skyColor(direction, sunDirection);
    }

    float volumeLimit = hasHit ? hit.t : uniforms.cameraUpAndMaxDistance.w;
    if (origin.y > kSeaLevel && direction.y < -1.0e-4f) {
        float waterT = (origin.y - kSeaLevel) / -direction.y;
        if (waterT < volumeLimit) {
            float3 waterPoint = origin + direction * waterT;
            float waveTime = uniforms.cameraPositionAndTime.w;
            float chop = valueNoise(waterPoint.x * 1.7f + waveTime * 0.8f, waterPoint.z * 2.6f, 61);
            float chopMask = smoothstep(0.55f, 0.78f, chop);
            float facing = saturate(-direction.y);
            float grazing = 1.0f - facing;
            float grazing2 = grazing * grazing;
            float fresnel = 0.03f + 0.97f * grazing2 * grazing2 * grazing;
            float2 flatDir = normalize(float2(direction.x, direction.z));
            float2 flatSun = normalize(float2(sunDirection.x, sunDirection.z));
            float lane = saturate(dot(flatDir, flatSun));
            float lane2 = lane * lane;
            float lane8 = lane2 * lane2 * lane2 * lane2;
            constexpr float3 seaDeep = float3(0.030f, 0.042f, 0.050f);
            constexpr float3 seaReflect = float3(0.300f, 0.330f, 0.375f);
            constexpr float3 seaGlow = float3(0.62f, 0.46f, 0.34f);
            float3 reflectTone = mix(seaReflect, seaGlow, lane8 * 0.55f);
            float3 waterColor = mix(seaDeep, reflectTone, saturate(fresnel * (0.70f + chop * 0.45f)));
            waterColor += seaGlow * lane8 * chopMask * grazing2 * 0.30f;
            if (hasHit) {
                float clarity = exp(-(hit.t - waterT) * 0.28f);
                waterColor = mix(waterColor, color * float3(0.42f, 0.55f, 0.53f), clarity * 0.5f);
            }
            float fogStart = uniforms.cameraUpAndMaxDistance.w * uniforms.fogAndExposure.x;
            float fogEnd = uniforms.cameraUpAndMaxDistance.w * uniforms.fogAndExposure.y;
            float waterFog = saturate((waterT - fogStart) / max(0.001f, fogEnd - fogStart));
            color = mix(waterColor, kFogColor, waterFog);
            volumeLimit = waterT;
        }
    }
    float transmittance = 1.0f;
    float3 scattering(0.0f);
    for (uint index = 0u; index < min(scene.counts.y, gaussianEnabled ? 48u : 0u); ++index) {
        Gaussian gaussian = gaussians[index];
        float opticalDepth = gaussianOpticalDepth(origin, direction, 0.0f, volumeLimit, gaussian);
        if (opticalDepth <= 1.0e-5f) continue;
        ++counts.gaussianSamples;
        float segmentTransmittance = exp(-min(opticalDepth, 20.0f));
        int3 cell = int3(clamp(floor(gaussian.localCenterSigma.xyz / 8.0f), float3(0.0f), float3(63.0f)));
        float3 incident = float3(volumeLighting.read(uint3(cell)).xyz);
        scattering += transmittance * (1.0f - segmentTransmittance)
            * gaussian.colorDensity.xyz * incident;
        transmittance *= segmentTransmittance;
    }
    color = color * transmittance + scattering;

    float sampleDistance = hasHit ? hit.t : min(64.0f, uniforms.cameraUpAndMaxDistance.w);
    float3 samplePoint = clamp(origin + direction * sampleDistance, float3(0.0f), float3(511.999f));
    if (evidenceView == 1u) {
        uint flags = mixed.read(uint3(samplePoint / 8.0f), 0u).x;
        float3 gridColor(0.025f, 0.035f, 0.05f);
        float channels = 1.0f;
        if ((flags & 1u) != 0u) { gridColor += float3(0.20f, 0.85f, 0.35f); channels += 1.0f; }
        if ((flags & 2u) != 0u) { gridColor += float3(0.95f, 0.25f, 0.70f); channels += 1.0f; }
        if ((flags & 4u) != 0u) { gridColor += float3(0.15f, 0.75f, 1.00f); channels += 1.0f; }
        if ((flags & 8u) != 0u) { gridColor += float3(1.00f, 0.72f, 0.12f); channels += 1.0f; }
        if ((flags & 16u) != 0u) { gridColor += float3(0.95f, 0.18f, 0.15f); channels += 1.0f; }
        color = gridColor / channels;
    } else if (evidenceView == 2u) {
        uint3 mixedCell = uint3(samplePoint / 8.0f);
        uint3 voxelCell = uint3(samplePoint);
        float3 mixedLevels(0.0f);
        float3 voxelLevels(0.0f);
        float mixedWeight = 0.0f;
        float voxelWeight = 0.0f;
        for (uint level = 0u; level <= 6u; ++level) {
            if (mixed.read(mixedCell >> level, level).x != 0u) {
                float t = float(level) / 6.0f;
                mixedLevels += float3(1.0f - t, 0.25f + 0.55f * t, t);
                mixedWeight += 1.0f;
            }
        }
        for (uint level = 0u; level <= 9u; ++level) {
            if (volume.read(voxelCell >> level, level).x != 0u) {
                float t = float(level) / 9.0f;
                voxelLevels += float3(0.10f + 0.25f * t, 1.0f - t * 0.55f, 0.35f + 0.65f * t);
                voxelWeight += 1.0f;
            }
        }
        mixedLevels /= max(mixedWeight, 1.0f);
        voxelLevels /= max(voxelWeight, 1.0f);
        color = mixedWeight > 0.0f
            ? mix(mixedLevels, voxelLevels, voxelWeight > 0.0f ? 0.45f : 0.0f)
            : float3(0.025f, 0.035f, 0.05f);
    } else if (evidenceView == 3u) {
        color = float3(
            saturate(float(counts.hierarchicalSteps) / 96.0f),
            saturate(float(counts.voxelSteps + counts.sdfSamples) / 64.0f),
            saturate(float(counts.gaussianSamples + secondaryRays * 8u
                + surfaceSunShadows * 4u + surfaceLocalShadows * 4u) / 32.0f)
        );
    } else if (evidenceView == 4u) {
        float totalWork = float(
            counts.hierarchicalSteps + counts.voxelSteps + counts.sdfSamples
            + counts.gaussianSamples + secondaryRays * 16u
            + surfaceSunShadows * 8u + surfaceLocalShadows * 8u
        );
        float heat = saturate(log2(1.0f + totalWork) / 11.0f);
        color = float3(heat, heat * heat, (1.0f - heat) * 0.85f);
    } else if (evidenceView == 5u) {
        color = hasHit
            ? qaPrimitiveIDColor(true, hit.primitiveKind, hit.stableID)
            : qaPrimitiveIDColor(false, 0u, 0u);
    } else if (evidenceView == 6u) {
        color = hasHit ? qaNormalColor(true, hit.normal) : qaNormalColor(false, float3(0.0f));
    } else if (evidenceView == 7u) {
        color = qaShadowMismatchColor(
            surfaceShadowComparable, surfaceExactShadow, surfaceReferenceShadow
        );
    }

    if ((options & COUNTER_AGGREGATION) != 0u) {
        aggregateFrameCounters(
            counts, secondaryRays, surfaceSunShadows, surfaceLocalShadows,
            active, frameCounters, simdLane
        );
    }
    if (!active) {
        return;
    }
    if (evidenceView < 5u || evidenceView > 7u) {
        color = pow(saturate(color * uniforms.fogAndExposure.z), float3(1.0f / 2.2f));
    }
    output.write(float4(color, 1.0f), gid);
}
