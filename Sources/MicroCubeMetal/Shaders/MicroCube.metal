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
    float3 radiance = float3(0.10f) + float3(1.0f, 0.93f, 0.78f) * sunVisibility * 0.72f;

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
            * falloff * falloff * visibility * 0.16f;
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
                lighting *= 0.45f;
            }
        }

        uint materialIndex = hit.primitiveKind == 0u
            ? 0u : min(hit.material, max(scene.counts.w, 1u) - 1u);
        float3 baseColor = hit.primitiveKind == 0u
            ? kPalette[min(hit.material, 42u)]
            : materials[materialIndex].baseColorRoughness.xyz;
        bool isReflective = !isGlass && hit.primitiveKind != 0u
            && materials[materialIndex].emissionMetalness.w > 0.0f;
        color = baseColor * lighting;
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
        color = mix(color, float3(150.0f, 170.0f, 195.0f) / 255.0f, fog);
    } else {
        color = skyColor(direction, sunDirection);
    }

    float volumeLimit = hasHit ? hit.t : uniforms.cameraUpAndMaxDistance.w;
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
