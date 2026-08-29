# MicroCube Metal Visual Proof Design

**Date:** 2026-08-30

**Status:** Approved scope, pending written-spec review

## Goal

Build a single-window macOS demo that proves one hybrid ray pipeline can render hierarchical voxels, smooth signed-distance-field geometry, a bounded fractal, Gaussian smoke, animated creatures and lights, reflection, refraction, and atmospheric fog. Tune the implementation for Apple Silicon and report measured M4 Max performance.

The demo presents collision, force, and spatial-audio reuse as `CONCEPT`. It does not claim to implement those systems.

## Product boundaries

### Required visual proof before completion

The project may describe an item below as implemented only after its automated gate passes and its required deterministic capture receives visual approval.

- A native AppKit application with one `NSWindow` and one `MTKView`.
- A 512³ material texture with an occupancy mip pyramid.
- A 64³ mixed macrogrid that marks voxels, SDF instances, Gaussian density, emissive content, and the fractal.
- Exact hierarchical voxel shadows.
- Bounded SDF creatures, smooth sculpture, glass object, and fractal.
- Gaussian smoke that receives animated local light and sun shadow.
- One bounded secondary scene ray for reflection or refraction.
- Five evidence views that expose the hybrid traversal.
- An English explainer panel inside the main window.
- Adaptive resolution for normal use and fixed-resolution benchmark mode.

### Concept only

- Shared-field collision and force queries.
- Ray-based spatial-audio delay, reflection, and material absorption.
- Production rigid bodies, arbitrary moving-object grids, and audio convolution.

The explainer must label concept items `CONCEPT`. It must never describe them as running code.

## Experience

### Hero scene

Reset frames a liminal voxel service complex from `(256.5, 112, 256.5)` toward the authored scene near `(284, 103, 297)`. A 58-degree vertical field of view keeps the scene legible beside the explainer.

The scene contains:

- a voxel colonnade and thin ledges on the left, which reveal exact sun shadows;
- a reflective wet channel through the lower center;
- a refractive smooth object near the center;
- six tall SDF creatures crossing Gaussian smoke in the center and left-center;
- pulsing emissive organs that move with the creatures and illuminate smoke and voxels;
- a bounded fractal silhouette at the rear;
- an overhead voxel slab that blocks sun and creature light.

The camera retains free flight. The authored reset view gives users an immediate composition and a stable basis for comparing evidence views.

### Evidence views

Keys `1` through `5` preserve the camera and change only the renderer's presentation:

1. `FINAL FIELD`: the completed voxel, SDF, Gaussian, optical, and atmospheric image.
2. `GRID`: mixed leaf cells, with occupied and empty states.
3. `PYRAMID`: color-coded mixed-grid descent from mip 6 to mip 0. When a leaf contains voxels, the view also shows the separate voxel-material descent from mip 9 to mip 0.
4. `RAY STEPS`: coarse skips, exact voxel steps, SDF samples, Gaussian samples, secondary rays, and shadow rays.
5. `COST`: measured step counts and GPU time. This view reports no speedup until a fixed-scene benchmark measures it.

### Controls

- `W`, `A`, `S`, `D`: horizontal movement
- `Q`, `E`: vertical movement
- `Shift`: faster movement
- Mouse: look
- `1`–`5`: evidence views
- `G`: Gaussian smoke
- `K`: shadows
- `L`: creature lights
- `O`: reflection and refraction
- `X`: SDF creatures and fractal
- `P`: pause scene motion
- `I`: English explainer
- `H`: HUD
- `F`: full screen
- `R`: reset camera
- `Escape`: close the explainer first, then release the mouse

## Single-window English explainer

The app overlays a 424-point-wide `NSVisualEffectView` on the right edge of the existing window. The `MTKView` remains full-window. The reset composition keeps every required proof point inside the uncovered left and center region. At widths below 1100 points, the panel collapses to an `I · WHY RAYS` rail. When the panel opens, the HUD constrains its trailing edge to the panel's leading edge with 16 points of clearance. One `NSScrollView` contains four sections:

1. `IN THIS MAC DEMO`: five focusable evidence-view controls.
2. `FROM THE AUTHOR'S POSTS`: Appendix B, labeled `SOURCE TEXT`. Claims about the earlier JavaScript demo and experimental engine do not describe this Mac build.
3. `CONCEPT FOR THIS MAC DEMO`: collision, forces, and spatial audio, labeled `CONCEPT`.
4. `AUTHOR'S SOURCES`: the sources in the References section.

The panel uses `GPU LIVE`, `DEBUG VIEW`, and `CONCEPT` badges. Text accompanies color. Body copy uses at least 13-point type.

`FROM THE AUTHOR'S POSTS` displays each passage under a persistent `SOURCE QUOTE · ORIGINAL AUTHOR'S DEMO` badge. Passage 2's 1,073,741,824-voxel and 60-fps statement receives the adjacent note `SOURCE CLAIM · NOT A RESULT FROM THIS MAC APP`. Paragraphs that mention “one pass” or “one frame” receive the adjacent note `CURRENT MAC APP · 1 HYBRID IMAGE KERNEL + 1 VOLUME LIGHT KERNEL`. Passage 3's collision, force, and audio paragraphs receive the adjacent note `CONCEPT IN THIS MAC DEMO · NO PHYSICS OR AUDIO SYSTEM RUNS HERE`. The app keeps Appendix B byte-identical and adds these disclosures outside the quoted resource text.

Opening the panel releases mouse capture and moves keyboard focus to the currently selected evidence-view control. All nonmovement shortcuts (`1`–`5`, `G`, `K`, `L`, `O`, `X`, `P`, `I`, `H`, `F`, `R`, and Escape) route at window level while panel controls own focus. Movement (`W`, `A`, `S`, `D`, `Q`, and `E`) and mouse look run only while the `MTKView` owns focus and mouse capture. Closing the panel restores the `MTKView` as first responder. The View menu contains explainer and HUD commands. Renderer shortcuts ignore events containing Command, Control, or Option so VoiceOver and system chords remain available.

The evidence controls accept keyboard focus. The collapsed `I · WHY RAYS` rail uses a focusable `NSButton` with the accessibility label `Open Why Rays explainer`; the close button uses `Close Why Rays explainer`. Source links use native accessible link controls, show a textual availability label, and open in the user's browser. VoiceOver announces evidence-view and toggle-state changes. Increased Contrast raises overlay opacity. Reduce Motion freezes the showcase animation without blocking manual camera movement. The interactive panel does not use `PassthroughVisualEffectView`, whose `hitTest` implementation rejects input.

## Rendering architecture

### GPU resources

The renderer keeps the existing 512³ `r8Uint` voxel material texture and ten mip levels. It adds:

- a 64³ `r8Uint` mixed-occupancy texture with seven mip levels;
- a 64³ `rgba16Float` volume-lighting texture;
- compact cell headers and reference lists;
- SDF, Gaussian, light, and material buffers;
- one scene-uniform buffer beside the existing 112-byte frame ABI.

Each mixed-cell flag uses these bits:

- bit 0: voxel occupancy
- bit 1: bounded SDF instances
- bit 2: Gaussian volume
- bit 3: emissive content
- bit 4: fractal distance estimator

Mip reduction combines child flags with bitwise OR. A leaf can contain voxels and several SDF or Gaussian references.

`buildMixedOccupancy` runs once after voxel mip construction and scene-buffer upload. For mixed cell `c`, it sets bit 0 when `voxelMaterials.read(c, 3)` is occupied, bit 1 when `(CellHeader.packedCounts & 0xffff) > 0`, bit 2 when `(CellHeader.packedCounts >> 16) > 0`, and bits 3 and 4 from the metadata of referenced emissive and fractal instances. It writes mixed mip zero. `reduceMixedOccupancy` builds mips 1 through 6 by bitwise OR. `SceneData` must bin every static or swept instance into each intersected eight-unit cell.

### Frame passes

Each frame uses two bounded compute passes:

1. `injectVolumeLighting` updates the 64³ froxel texture. All six animated lights contribute bounded radiance. Each active froxel traces exact sun visibility and at most one shadow ray toward the strongest contributing local light. The pass records sun-shadow and local-shadow sample counts in evidence mode.
2. `raycastHybrid` resolves the final image. It combines voxel casting, SDF marching, Gaussian integration, lighting, shadowing, reflection, and refraction.

The explainer calls this `1 HYBRID IMAGE KERNEL + 1 VOLUME LIGHT KERNEL`. It does not claim one total GPU dispatch.

The author's “one pass” wording describes the earlier renderer. This Mac demo uses one hybrid image kernel plus one volume-light kernel.

The scene contains at most 48 Gaussians and 4,096 active volume cells, including a one-cell sampling halo around every swept density cell. `activeVolumeCells` stores `UInt32` linear indices using `x + 64 * (y + 64 * z)`. Renderer initialization clears the whole texture to `(0, 0, 0, 1)`. For every listed density or halo cell, `injectVolumeLighting` writes incident smoke-lighting radiance from the sun and all six local lights into RGB, independent of the cell's local density, and writes sun transmittance into alpha. The sun and strongest local light use bounded solid visibility and Gaussian transmittance. `raycastHybrid` samples RGB and multiplies it by analytic Gaussian density and phase; it does not treat RGB as pre-integrated scattering. Halo cells receive evaluated lighting and transmittance, which keeps trilinear sampling continuous. Cells outside the list remain unsampled.

### Hybrid traversal

Each primary ray performs stackless hierarchical DDA through the mixed macrogrid:

1. Skip empty mip nodes.
2. Descend occupied nodes.
3. Enter an eight-unit leaf.
4. Trace exact voxels when bit 0 is set.
5. March referenced SDF bounds when bits 1 or 4 are set.
6. Integrate Gaussian density when bit 2 is set.
7. Choose the nearest solid hit and accumulate volume transmittance before the leaf exit.

Each ray intersects `instance.sweptBounds`. It evaluates the instance only in the leaf interval containing `tSweptEnter`, or the ray-origin leaf when the origin lies inside the swept bounds. It then intersects the current animated bounds and marches once through `min(currentBoundsExit, nearestVoxelT)`. Other leaf references skip that instance.

### Bounded work

- Smooth SDF objects: at most 24 steps.
- Creatures: at most 32 steps.
- Fractal: at most 48 steps and 8 distance-estimator iterations.
- Fractal screen coverage: less than 10 percent in the reset view.
- Local lights evaluated per surface: strongest four of six.
- Local-light shadow rays: strongest light only.
- Sun-shadow rays: one exact visibility query.
- Volume-lighting shadow rays per froxel: one sun ray and at most one strongest-local-light ray.
- Optical path depth: one secondary scene ray.

The refractive object is an analytic sphere. The shader computes its entry and exit normals, applies Snell refraction at both interfaces and Beer absorption, then spends one secondary scene trace after exit. Reflective pixels spend that one-ray budget on reflection. Secondary hits receive ambient plus unshadowed sun and local diffuse; they cast no shadow or optical rays.

Primary sun and strongest-local-light queries trace exact voxel occupancy and bounded SDF occluders, then multiply visibility by analytic Gaussian optical transmittance. Smoke receives light and casts colored or neutral attenuation onto voxel and SDF surfaces.

The demo permits at most 16 SDF instances, 8 SDF references per leaf, 48 Gaussians, 16 Gaussian references per leaf, 4,096 active volume cells, and 4,096 hierarchical DDA iterations per ray. Scene construction and QA fail when data exceeds a cap.

### Exact shadows

The current coarse shadow path treats an occupied 2³ mip cell as an occluder. A live probe measured 404 coarse-versus-exact disagreements among 10,380 sunlit samples, a 3.892 percent mismatch.

`traceOcclusionExact` uses occupancy mips only to skip empty space. It descends every occupied node to mip zero and returns on the first occupied voxel. It uses a normal-facing origin bias, explicit `tMin` and `tMax`, and `nextafter` at cell exits. The reference uses an independent level-zero Amanatides-Woo DDA with the same normal bias, explicit `tMin` and `tMax`, and X-before-Y-before-Z axis-tie rule. Fixtures include face, edge, corner, grazing, inside-world, and world-boundary rays. `traceOcclusionExact` must produce zero false and zero missed voxel occlusions.

### Color and precision

Ray positions, distances, normals, directions, and SDF calculations use `float`. Colors, fog accumulation, and light accumulation may use `half` after profiling proves no visible banding. Metal compiles runtime shader source with fast math because the installed Command Line Tools lack the offline `metal` compiler.

### Runtime shader source assembly

`ShaderSourceLoader` reads `SceneTypes.metal`, `HybridTraversal.metal`, and `MicroCube.metal` from `Bundle.module`, concatenates them in that order, and calls `device.makeLibrary(source:options:)`. The fragments contain no unresolved local `#include` directives. A runtime-library test loads the packaged resources and requires these production kernels:

- `generateTerrain`
- `reduceOccupancy`
- `buildMixedOccupancy`
- `reduceMixedOccupancy`
- `injectVolumeLighting`
- `raycastHybrid`

The test fails on a missing source resource, duplicate definition, compiler diagnostic, or absent function.

## Data contracts

`FrameUniforms` remains seven ordered 16-byte vectors with a 112-byte stride. A new `SceneUniforms` uses four 16-byte vectors:

```c
struct SceneUniforms {
    uint4 counts;
    uint4 grid;
    float4 fog;
    uint4 budgets;
};
```

The mixed-grid cell header remains 16 bytes:

```c
struct CellHeader {
    uint sdfOffset;
    uint gaussianOffset;
    uint packedCounts;
    uint reserved;
};
```

`SceneUniforms` has size 64, stride 64, and alignment 16 bytes. `CellHeader` has size 16, stride 16, and alignment 4 bytes. The low 16 bits of `packedCounts` store `sdfCount`; the high 16 bits store `gaussianCount`. Each count must fit in 16 bits. An offset has no meaning when its corresponding count is zero. `reserved` must equal zero, and mixed-occupancy mip zero provides the sole flag source. Scene construction fails with a readable QA error instead of truncating an overflowing count, offset, or reference list.

The typed scene buffers use these layouts:

```c
struct SDFInstance {
    float4 sweptBoundsMin;
    float4 sweptBoundsMax;
    float4 positionScale;
    float4 rotationQuaternion;
    float4 parameters;
    uint4 metadata;              // kind, material, flags, stable ID
};                               // 96 bytes

struct Gaussian {
    float4 localCenterSigma;
    float4 colorDensity;
    float4 motionPhase;
};                               // 48 bytes

struct Light {
    float4 positionRadius;
    float4 colorIntensity;
};                               // 32 bytes

struct Material {
    float4 baseColorRoughness;
    float4 emissionMetalness;
    float4 opticalAbsorptionIOR;
    float4 transmissionAcoustic;
};                               // 64 bytes

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
};                               // 48 bytes
```

Swift tests assert every size and field offset against the MSL contract. `SceneUniforms.counts` means SDF, Gaussian, light, and material counts. `grid` means dimension, leaf size, top mip, and active-volume-cell count. `budgets` means smooth steps, creature steps, fractal steps, and fractal iterations. The renderer binds per-frame `SceneUniforms` with `setBytes`, as it does for `FrameUniforms`, or uses three aligned slots. It does not mutate one shared slot while three command buffers remain in flight.

Main bindings:

```text
texture(0)  voxelMaterials   r8Uint, 512³, mipmapped
texture(1)  mixedOccupancy   r8Uint, 64³, mipmapped
texture(2)  volumeLighting   rgba16Float, 64³
texture(3)  drawable         bgra8Unorm

buffer(0)   FrameUniforms
buffer(1)   SceneUniforms
buffer(2)   CellHeader[]
buffer(3)   cellSDFRefs[]
buffer(4)   cellGaussianRefs[]
buffer(5)   SDFInstance[]
buffer(6)   Gaussian[]
buffer(7)   Light[]
buffer(8)   Material[]
buffer(9)   activeVolumeCells[]
buffer(10)  FrameCounters
```

`cellSDFRefs`, `cellGaussianRefs`, and `activeVolumeCells` contain 32-bit unsigned integers. Swift treats `FrameCounters` as twelve ordered `UInt32` values and asserts a 48-byte size. The first implementation uses static instance buffers and swept creature bounds. It does not rebuild the mixed grid each frame.

Each ray keeps counters in registers. Counter aggregation runs only in `RAY STEPS`, `COST`, and automated probe modes. Every SIMD-group lane reaches each `simd_sum`; out-of-viewport lanes contribute zero and return only after the collective. One lane per SIMD group atomically updates the frame counter. The renderer owns three counter buffers, clears a slot only after its prior command buffer completes, and reads it from that completion handler. The fixed-scene performance benchmark disables counter atomics, and the HUD omits detailed step totals when aggregation is disabled. `COST` colors pixels from thread-local counts, so it needs no readback.

## HUD and claims

The HUD reports live values only:

```text
SCENE 1/5 · FINAL FIELD · 2 COMPUTE PASSES · {LIVE FPS} · {LIVE GPU MS} · {DRAWABLE}
MIXED 64³ MIP 6→0 · VOXELS 512³ MIP 9→0 · VOXEL DDA + SDF RM + GAUSSIAN · SHADOWS/LIGHTS/OPTICS ON
```

The renderer fills FPS, GPU time, size, scale, and active options from measured state. It fills detailed step counters only while counter aggregation is enabled. `512³` means grid capacity. The app does not call all 134,217,728 addressable cells visible or solid.

Documentation uses `M4 Max tuned`, followed by fixed-resolution percentile results. It avoids the absolute phrase `fastest possible` because this project cannot test every renderer.

## Testing and evidence

### Automated GPU probes

Each probe writes one UTF-8 JSON object with this envelope:

```json
{
  "schemaVersion": 1,
  "probe": "shadow",
  "fixtureVersion": 1,
  "status": "pass",
  "failure": null,
  "device": "Apple M4 Max",
  "metrics": {}
}
```

`status` is `pass` only when every gate for that probe passes. `failure` is null on success and a nonempty string on failure. XCTest decodes the file, rejects unknown schema versions, asserts every required metric, and checks that the JSON status matches the XCTest result.

Required `metrics` keys:

| Probe | Required keys and passing values |
| --- | --- |
| `shadow` | `sampleCount == 10380`, `legacyMismatch == 404`, `falseShadows == 0`, `missedShadows == 0`, `maxHitDistanceError <= 0.002` |
| `mixed` | `mixedLeafVoxel == true`, `mixedLeafSDFRefs == 2`, `wrongNearestHits == 0`, `maxHitDistanceError <= 0.002`, plus `voxelOnly`, `sdfOnly`, `gaussianOnly`, `mixed`, and `empty` objects containing integer `voxelSteps`, `sdfSteps`, and `gaussianSamples` |
| `budgets` | `overflowCount == 0` and integer maxima for `smoothSteps`, `creatureSteps`, `fractalSteps`, `fractalIterations`, `hierarchicalSteps`, `surfaceLights`, `localShadowRays`, `sunShadowRays`, and `secondarySceneRays` |
| `sdf` | `maxDistanceError <= 0.0001`, `maxNormalAngleDegrees <= 0.5`, `maxNormalLengthError <= 0.001`, `nonFiniteCount == 0`, `negativeExteriorStepCount == 0`, `fractalCoverage < 0.10` |
| `optics` | `maxReflectionDirectionError <= 0.0001`, `maxRefractionDirectionError <= 0.0001`, `tirFailureCount == 0`, `recursiveSecondaryRayCount == 0` |
| `volume` | `maxHomogeneousRelativeError <= 0.02`, `maxGaussianRelativeError <= 0.02`, `maxSurfaceTransmittanceRelativeError <= 0.02`, `sunShadowRadianceRatio < 0.35`, `localShadowRadianceRatio < 0.35`, `smokeSunReceiverRatio < 1.0`, `smokeLocalReceiverRatio < 1.0`, `nonFiniteCount == 0` |
| `motion` | `creatureCount == 6`, `lightCount == 6`, `repeatMismatchCount == 0`, `poseDeltaAtOneSecond > 0`, `lightDeltaAtOneSecond > 0` |
| `ui` | `stateMismatchCount == 0`, `focusFailureCount == 0`, `modifierLeakCount == 0`, `accessibilityFailureCount == 0`, `responsiveLayoutFailureCount == 0`, `adaptiveScaleFailureCount == 0`, `fixedScaleFailureCount == 0`, `reduceMotionFailureCount == 0`, `windowCount == 1` |

- Shadow traversal regenerates the fixed 10,380-ray fixture. The legacy path must reproduce 404 disagreements. `traceOcclusionExact` must report zero false shadows, zero missed shadows, and maximum first-hit distance error at most 0.002 against the independent level-zero DDA. Fixtures cover the face, edge, corner, grazing, inside-world, and world-boundary cases defined above.
- Mixed traversal builds voxel-only, SDF-only, Gaussian-only, mixed, and empty fixtures. One mixed leaf must expose voxel occupancy plus two SDF references. Debug counters must show DDA only, ray marching only, Gaussian integration only, all required methods, and no fine traversal, respectively. The hybrid winner must match brute force with hit-distance error at most 0.002.
- Work-budget probes must report zero budget overflows. Each primary ray may use at most 24 smooth-object steps, 32 creature steps, 48 fractal steps, 8 fractal iterations, 4,096 hierarchical DDA iterations, four local surface lights, one local surface-light shadow, one sun shadow, and one secondary scene ray.
- SDF probes test sphere, capsule, smooth union, and fractal samples. Analytic sphere, capsule, and smooth-union distances differ from CPU fixtures by at most `1e-4`; derived normals differ by at most `0.5°`. Fractal samples and normals remain finite, normals stay within `1e-3` of unit length, and exterior fixtures never return a negative step. A primitive-ID capture must show fractal coverage below 10 percent of reset-view pixels.
- Optics probes require reflected and refracted direction error below `1e-4`, correct total internal reflection, and no optical recursion from a secondary hit.
- Volume probes require homogeneous transmittance within 2 percent of `exp(-sigmaT * distance)` and numeric Gaussian integration within 2 percent of its analytic integral. In the blocker fixture, shadowed smoke radiance must remain below 35 percent of clear-path radiance for both sun and strongest local light. A separate surface fixture places a lit voxel and SDF receiver behind smoke. Their direct-light multipliers must stay within 2 percent of `exp(-tau)` and become lower than their clear-path values for both sun and strongest local light.
- Motion probes require exactly six creature instances and six light instances. Repeated runs at the same fixed time must produce byte-identical transforms. Times 0.0 and 1.0 must produce different creature poses and light values.
- UI-state tests require keys `1` through `5` and `G`, `K`, `L`, `O`, `X`, `P`, `I`, and `H` to change only their documented state. Escape closes the panel before releasing mouse capture. Tests also cover the close button, View-menu commands, modifier filtering, focus movement, native links, and accessibility announcements. UI probes test panel layouts at 1099 and 1100 points, HUD clearance, 13-point minimum body text, collapsed-rail and close-button labels, Increased Contrast opacity, and source/concept disclosures. Adaptive-scale tests feed deterministic high and low GPU times, require scale to move in the correct direction, and enforce the 0.35 through 1.0 bounds. Fixed QA and benchmark modes must hold their requested scale for 900 frames. Reduce Motion must freeze creature and light animation while manual camera input still changes the camera.

### Deterministic captures

The packaged app accepts:

`--qa-scene <hero|shadow-fixture|mixed-fixture|optics-fixture|fog-clear|fog-blocked|gaussian-fixture|fractal-fixture> --qa-features <all|none|comma-separated shadows,lights,optics,sdf,gaussian> --qa-time <seconds> --qa-step <seconds> --qa-camera <reset|x,y,z,yaw,pitch> --qa-window-points <width>x<height> --qa-drawable <width>x<height> --qa-scale <0.35...1.0> --qa-view <final|grid|pyramid|steps|cost|primitive-id|normals|shadow-mismatch> --qa-frames <count> --qa-capture-scope <drawable|window> --qa-capture <png> --qa-report <json>`

Benchmark mode adds:

`--benchmark --benchmark-warmup 180 --benchmark-samples 900`

QA mode creates the normal single `NSWindow` and `MTKView`. It disables adaptive scale, wall-clock animation, input mutation, HUD animation, and display-dependent drawable sizing. `--qa-drawable` names drawable pixels, not AppKit points. After the requested completed frame, the renderer copies the drawable before presentation, writes PNG and JSON, asks `NSApplication` to stop, wakes the event loop, and returns the stored status from `AppDelegate.main()`. The process calls `exit(status)` only after `application.run()` returns. It does not create a capture, benchmark, or error window.

`drawable` capture copies the completed Metal drawable before presentation. `window` capture records the existing window's content view after the same frame completes and after AppKit finishes layout. Window capture includes the `MTKView`, HUD, explainer, badges, and collapsed rail. It creates no second window. `--qa-window-points` names the content-view size in AppKit points.

The JSON schema requires `schemaVersion`, `status`, `failure`, `device`, `os`, `scene`, `fixedTime`, `drawablePixels`, `renderScale`, `windowCount`, `productionKernels`, `featureMask`, `passCount`, `stepCounters`, `shadowSampleCounts`, `budgetOverflows`, `commandErrors`, `droppedDrawables`, `semaphoreTimeouts`, `capturePath`, and raw GPU samples when benchmarking.

Required captures use the reset camera and cover:

| Capture | Fixed state | Required review |
| --- | --- | --- |
| Shadow beauty and mismatch | `shadow-fixture`, time 0, features `shadows` | No detached or blocky shadows; mismatch image has zero marked pixels |
| Mixed primitive ID and steps | `mixed-fixture`, time 0, features `all` | Voxel, two SDFs, and Gaussian content appear with matching counters |
| Monsters | `hero`, times 0 and 1, features `sdf,lights,gaussian,shadows` | Six silhouettes move and remain grounded |
| Optics | `optics-fixture`, time 0, features `optics` and `none` | Reflection and refraction reveal different scene samples |
| Fog blocker | `fog-clear` and `fog-blocked`, time 0, features `gaussian,lights,shadows` | Sun and local-light smoke radiance both respond |
| Gaussian | `gaussian-fixture`, time 0, features `gaussian` and `none` | Gaussian contribution appears only when enabled |
| Smoke-cast surface shadow | `gaussian-fixture`, time 0, features `gaussian,lights,shadows` and `lights,shadows` | Voxel and SDF receivers darken only when the smoke segment intersects their light path |
| Fractal normals | `fractal-fixture`, time 0, features `sdf` | Continuous finite normals and less than 10 percent coverage |
| Hero final field | `hero`, time 0, features `all`, view `final`, reset camera, drawable scope | Colonnade, wet reflection, glass refraction, smooth sculpture, six creatures, lit smoke, emissive organs, fractal, slab shadows, and atmospheric fog all appear in one composition |
| Five evidence views | `hero`, time 0, features `all`, views `final`, `grid`, `pyramid`, `steps`, and `cost`, drawable scope | All five captures preserve the same camera and expose the documented data with distinct presentations |
| Explainer responsive states | `hero`, time 0, window widths 1280 and 1099 points, window scope | Expanded panel and collapsed rail stay inside one window; HUD does not overlap; source, current-Mac, and concept labels appear beside the relevant text |

A human reviewer records pass or fail for each visual row. Numeric probes remain the authority for traversal and math.

### M4 Max performance gate

The benchmark runs the packaged arm64 executable on a device whose reported chip name equals `Apple M4 Max`. It enables the full final scene, uses a fixed 1/120-second clock, sets render scale to 1.0, treats requested sizes as drawable pixels, excludes world construction and runtime shader compilation, warms 180 completed frames, and records 900 unsmoothed `gpuEndTime - gpuStartTime` samples. Run each resolution three times after thermal idle and apply the threshold to the worst p95:

- 1280×800: p95 at or below 8.33 ms.
- 2560×1600: p95 at or below 16.67 ms.
- Zero command-buffer errors, drawable acquisition failures, and in-flight semaphore timeouts.

Metal System Trace must show two steady-state compute passes, no per-frame CPU texture upload, and no steady-state `waitUntilCompleted`. Startup world construction and the final QA drain may wait for completion. The report includes all raw samples, percentile method, device, OS, feature mask, drawable pixels, and render scale.

Each benchmark JSON contains:

```json
{
  "schemaVersion": 1,
  "status": "pass",
  "device": "Apple M4 Max",
  "thermalStateBefore": "nominal",
  "thermalStateAfter": "nominal",
  "drawablePixels": [1280, 800],
  "renderScale": 1.0,
  "fixedStep": 0.008333333333333333,
  "warmupFrames": 180,
  "measuredFrames": 900,
  "percentileMethod": "nearest-rank",
  "gpuMilliseconds": [],
  "p95GPUms": 0.0,
  "commandErrors": 0,
  "droppedDrawables": 0,
  "semaphoreTimeouts": 0,
  "passCount": 2,
  "featureMask": "all"
}
```

A run is invalid unless both thermal states equal `nominal`, the raw array contains exactly 900 finite positive samples, `featureMask` equals `all`, and `passCount` equals 2. Nearest-rank p95 selects sorted sample index `ceil(0.95 × 900) - 1`. `scripts/benchmark.sh` stores all three reports per resolution and applies the threshold to their maximum `p95GPUms`.

Metal System Trace review writes `trace-review.json` with the trace SHA-256, reviewer, review time, `steadyStatePassCount == 2`, `perFrameCPUTextureUploads == 0`, `steadyStateWaitUntilCompleted == 0`, and `status`.

If the final scene misses a threshold, profile before reducing fidelity. The fixed loop budgets and screen-space composition are the first controls.

### macOS package gate

- Release Swift tests pass.
- Runtime source assembly succeeds from the packaged resources and exposes every named production kernel.
- `codesign --verify --deep --strict` accepts the ad hoc signed arm64 app. This gate proves local bundle integrity, not notarization or Gatekeeper distribution approval.
- The app bundle contains every shader source and `WhyRays.en.txt`; a resource test compares `WhyRays.en.txt` byte for byte with Appendix B.
- The bundle identifier remains `com.vseplet.microcube.metal`.
- The minimum system remains macOS 14.
- Launch produces one application process and one window.
- `scripts/capture-qa.sh` produces the capture matrix and validates each JSON status.
- `scripts/benchmark.sh` performs the fixed M4 Max runs and threshold checks.
- `scripts/verify-app.sh` checks plist values, arm64 architecture, signature, resources, required kernels, one process, and `windowCount == 1`.

`scripts/capture-qa.sh` writes `dist/evidence/visual-review.json`. Each of the eleven matrix rows contains `name`, a nonempty `captures` array, reviewer, reviewed-at timestamp, `pass` or `fail`, and notes. Each capture contains a relative PNG path and SHA-256. A review passes only when all eleven rows exist, every required state has a capture, current file hashes match, and every row result equals `pass`.

`scripts/verify-app.sh` extracts Appendix B by taking the block-quote lines under `### Passage 1`, `### Passage 2`, and `### Passage 3`, removing one leading `> ` or `>`, joining passages with two LF bytes, encoding UTF-8 without a BOM, and ending with one LF byte. It compares those bytes with packaged `WhyRays.en.txt`.

`scripts/verify-completion.sh` requires:

- every probe JSON listed above with `status == pass`;
- all release XCTest results passing;
- `visual-review.json` passing with matching hashes;
- three valid passing benchmark reports at each resolution;
- a passing `trace-review.json` with a matching trace hash;
- a passing `verify-app.sh` report;
- one packaged process and `windowCount == 1`.

It writes `dist/evidence/completion.json` with the SHA-256 of every input artifact. Only `completion.json.status == pass` authorizes changing the design status to complete or describing a required visual proof item as implemented.

## Failure behavior

`Renderer` uses a throwing initializer. `RendererError` records the failing allocation, resource, kernel, or pipeline and preserves the underlying Metal compiler diagnostic. `AppMain` catches it and shows the message in the existing window. QA mode records the same diagnostic in JSON and exits nonzero.

## File boundaries

- `SharedTypes.swift`: Swift ABI structs, option masks, evidence-view enum.
- `Package.swift`: retain the copied `Shaders` directory, add the `Resources` directory to `Bundle.module`, and declare the test-target resources needed by runtime-library and byte-identity tests.
- `Rendering/Renderer.swift`: Metal resources, frame scheduling, scene state, QA capture, metrics.
- `Rendering/SceneData.swift`: static instances, mixed-grid headers, reference lists, and packed materials.
- `Shaders/SceneTypes.metal`: shared Metal structs and constants.
- `Shaders/HybridTraversal.metal`: voxel, SDF, fractal, Gaussian, and optical queries.
- `Shaders/MicroCube.metal`: terrain, occupancy kernels, volume lighting, final ray kernel.
- `Rendering/ShaderSourceLoader.swift`: ordered runtime assembly of the three bundled Metal source fragments.
- `App/MetalInputView.swift`: key events and panel handoff.
- `App/AppMain.swift`: one window, HUD, viewport, callbacks.
- `App/ExplainerPanel.swift`: panel layout, English content, links, badges, and accessibility.
- `Resources/WhyRays.en.txt`: the Appendix B translation copied byte for byte.
- `Tests/`: ABI, option, scene-data, shader-probe, and QA-report tests.
- `scripts/`: app packaging, deterministic captures, and benchmark commands.

One agent owns each listed file or directory. The `SharedTypes.swift` and `SceneTypes.metal` owners use the layouts in this document as their shared authority. The `Package.swift` owner lands resource declarations before shader-loader, explainer-resource, or packaged-runtime tests run. Review agents remain read-only.

`Renderer.makeLibrary` uses `ShaderSourceLoader` to load `SceneTypes.metal`, `HybridTraversal.metal`, and `MicroCube.metal` as bundled UTF-8 resources, concatenate them in that order, and pass the combined source to `makeLibrary(source:options:)`. A package test confirms that all three resources exist and that their concatenated source exposes every required kernel.

## References

- User-supplied Iñigo Quilez link, `https://iquilezles.org/articles/raymarchingdf/`. It returned `Page not found` on 2026-08-30, so the panel labels it as a user-supplied link.
- Ken Silverman, Voxlap, `https://advsys.net/ken/voxlap.htm`.
- Graphics Programming Conference, Raytracing Voxels in Teardown and Beyond, `https://www.youtube.com/watch?v=IM1Dr98f3xU`.
- User-supplied post, `https://x.com/vseplet/status/2089768706847150248?s=20`.

## Appendix A: Russian source text

This appendix records the user's source text. The app displays the English translation in Appendix B.

### Passage 1

> Почему я использую трассировку лучей, а не классическую растеризацию полигонов?
>
> Начнем с того, что лучи тупо веселее) Но технических преимуществ с моей точки зрения ровно два: проще реализация сложных атмосферных эффектов, отражений, преломлений и прочего в один проход + широкие возможности по отрисовке вокселей, гладких поверхностей и сложных фрактальных форм (sdf)
>
> На примере тех же вокселей. Лучами я могу позволить отрисовывать их миллионами, а на полигонах приходится городить сложные алгоритмы по вычислению области видимых поверхностей, их триангуляции и так далее
>
> Согласен, преимущества в контексте разработки игр сомнительные ввиду узости их применения, но если хочется добиться какой-то нетипичной картинки — подход имеет место быть
>
> За простотой реализации же кроется большее кол-во вычислений на пиксель. Кароче, это тупо требовательно, потому добиться высокой скорости/большого разрешения картинки без серьезных оптимизаций прохода луча, комбинации способов трассировки для разных графических примитивов и оптимизации пространства — сложно
>
> И буквально еще лет 10-15 назад я бы даже не стал думать о том, чтобы делать какой-то игровой проект полностью с рендерингом на лучах. Ну а сегодня это вполне рабочий подход: процессоры стали мощнее, встроенная GPU круче, все больше компьютеров имеют объединенную память и даже mac становится интересным для разработки игр благодаря своим возможностям

### Passage 2

> Я поставил себе условие: если пост про трассировку лучей привлечёт кучу внимания — я займусь разработкой какой-нибудь игры на базе этой технологии
>
> Он взял, и собрал больше трех тысяч лайков, принес более 400 подписчиков и просто был добавлен в закладки более тысячи раз!
>
> Огромное вам спасибо, разработке игры быть
>
> В прошлом посте я рассказывал о гибриде разных методов бросания лучей для отрисовки в один проход вокселей, SDF, гауссин и так далее
>
> В этом посте я коротко поясню о том, как это работает (в приложенном видео анимация работы алгоритма) + дам необходимые ссылки ниже
>
> 1. Видимый мир
>
> В видео на демо все, что мы рисуем, состоит из двух вещей: воксели и sdf (гладкие формы, шары, скругленные тела и не только). Мир гибридный — кубики и гладкие фигуры живут вместе в одной сетке. И на первом шаге мы строим эту сетку, определяя в какой клетке какие воксели или фигуры находятся. Важно заметить, что одна фигура может занимать несколько клеток, а несколько фигур могут занять одну клетку
>
> 2. Пирамида
>
> Чтобы не проверять каждую клетку по отдельности (их миллионы), мы строим над сеткой пирамиду. Делим мир на более крупные ячейки и для каждой запоминаем всего одно: есть внутри хоть что-нибудь или там пусто. Потом объединяем ячейки по четыре в более крупные, и так уровень за уровнем. Получается "карта заполненности", где пустые области отваливаются целыми кусками, а в заполненных ячейках могут содержаться воксели и/или фигуры
>
> 3. Лучи
>
> Теперь пускаем луч. Луч идет по пирамиде сверху вниз: попал в крупную пустую ячейку — перепрыгнул ее целиком одним шагом, не тратя время. Попал в заполненную — спускаемся на уровень мельче и смотрим внимательнее. Дошли до вокселей — включаем ray casting. Дошли до гладкой фигуры — включаем ray marching, пока не приблизимся на минимальную необходимую дистанцию или пролетим мимо. Так луч быстро проскакивает пустоту и быстро находит воксель или фигуру, в которую вероятнее всего упрется
>
> Помимо вокселей и sdf сюда же могут идти отдельные модели с собственной воксельной сеткой, объемные гауссины, частицы и что душе угодно. В каждом отдельном случае используется необходимый способ бросания луча или комбинация несколькльких
>
> В демо на видео мне удалось в 60fps отрисовывать 1 073 741 824 цветных вокселя и около 100 простых sdf без использования GPU на обычном canvas 2d context (javascript)

### Passage 3

> Мне удалось нащупать сочетание разных методов бросания лучей, которое рисует в реальном времени воксели, объемные гауссианы и сложные гладкие поверхности (SDF) — все сразу, в одном кадре, с отражениями, преломлениями и освещением
>
> Программирую я с десяти лет, и любимой темой всегда была и остается компьютерная графика, особенно та часть, что связана с играми. В игровой индустрии я отработал какое-то небольшое кол-во лет и может быть чуть-чуть разбираюсь в разработке игр
>
> Последнюю неделю я обдумывал сценарий видео для ютуба об истории трассировки лучей и о том, как работают рейкастинг, реймарчинг, рейтрейсинг и прочее. Надо было освежить знания и попрактиковаться, но меня, как обычно, унесло в дебри и детали реализации
>
> Скорее всего, я не открыл Америку. Но картинка получается непривычная: объемный дым, который отбрасывает тень и сам освещается, лиминальные пространства, фракталы, довольно странные существа
>
> Самое интересное вылезло дальше. Когда весь мир обсчитывается лучами и полем расстояний, те же механизмы закрывают не только картинку. По полю считаются столкновения и направления сил, отдельного кода физики почти не понадобилось. Со звуком то же самое: лучи от источника обходят сцену так же, как световые, и дают отражения, задержки и поглощения по материалам
>
> Да, в упрощенном виде, но такого нет в подавляющем большинстве игр. Тот факт, что один механизм закрыл сразу три составляющие виртуального мира, поразил меня. В итоге простой рендер за несколько вечеров разросся до небольшого движка, пусть и демонстрационного
>
> Теперь мне важно понять, есть ли интерес к теме. Это не самый быстрый подход и не такой универсальный, как классические полигоны с аппаратной растеризацией, но что-то в этом есть)
>
> Кароче, сделай ретвит, поставь лукерк и оставь комментарий. Если этот пост соберет много внимания — я скорее всего займусь разработкой полноценного демо какой-нибудь сурвайвл песочницы на данной технологии

## Appendix B: English explainer copy

The app copies these passages into `WhyRays.en.txt`. This translation preserves the author's paragraph order, first-person voice, colloquial phrasing, and technical meaning.

### Passage 1

> Why do I use ray tracing instead of classic polygon rasterization?
>
> For starters, rays are just plain more fun) But from my point of view, there are exactly two technical advantages: complex atmospheric effects, reflections, refractions, and the rest are easier to implement in one pass, plus rays give you broad options for rendering voxels, smooth surfaces, and complex fractal forms (SDFs).
>
> Take voxels. With rays I can afford to render millions of them. With polygons you have to cobble together complex algorithms that find the visible surfaces, triangulate them, and so on.
>
> I agree, those advantages are questionable in game development because they apply to such a narrow set of cases. But if you want an unusual image, the approach has its place.
>
> Implementation may be simple, but it hides more computation per pixel. Basically, this stuff is plain demanding. High speed or high resolution is hard to reach without serious ray-traversal optimization, a mix of tracing methods for different graphics primitives, and spatial optimization.
>
> Even 10 or 15 years ago I would not have considered building a game project rendered entirely with rays. Today it is a workable approach. Processors have become more powerful, integrated GPUs have improved, more computers use unified memory, and even the Mac is starting to look interesting for game development because of what it can do.

### Passage 2

> I set myself a condition: if the ray-tracing post attracted a lot of attention, I would start developing some kind of game based on this technology.
>
> It went and collected more than three thousand likes, brought in more than 400 followers, and was bookmarked more than a thousand times!
>
> Thank you all so much. The game is happening.
>
> In the previous post I described a hybrid of different ray-casting methods that renders voxels, SDFs, Gaussians, and more in one pass.
>
> In this post I'll briefly explain how it works (the attached video animates the algorithm), then share the necessary links below.
>
> 1. The visible world
>
> Everything drawn in the video demo consists of two things: voxels and SDFs (smooth forms, spheres, rounded bodies, and more). The world is hybrid. Cubes and smooth shapes live together in the same grid. First we build that grid and determine which cells contain voxels or shapes. One shape can occupy several cells, and several shapes can occupy one cell.
>
> 2. The pyramid
>
> We avoid checking millions of individual cells by building a pyramid over the grid. We divide the world into larger cells and remember one thing for each cell: does it contain anything, or is it empty? Then we combine cells four at a time into larger ones, level by level. This produces an occupancy map. Empty regions disappear in large chunks, and occupied cells can contain voxels, shapes, or both.
>
> 3. The rays
>
> Now we cast a ray. It moves down through the pyramid. Hit a large empty cell, jump across the whole thing in one step without wasting time. Hit an occupied cell, descend one level and look closer. Reach voxels, switch on ray casting. Reach a smooth shape, switch on ray marching until we get within the required minimum distance or fly past it. This lets the ray cross empty space fast and find the voxel or shape it will most likely hit.
>
> The same structure can hold separate models with their own voxel grids, volumetric Gaussians, particles, or whatever else you feel like. Each case uses the required ray method or a combination of several methods.
>
> In the video demo I managed to render 1,073,741,824 colored voxels and around 100 simple SDFs at 60 fps without a GPU, using an ordinary JavaScript Canvas 2D context.

### Passage 3

> I managed to feel my way to a combination of ray methods that renders voxels, volumetric Gaussians, and complex smooth surfaces (SDFs) in real time, all together in one frame, with reflections, refractions, and lighting.
>
> I have been programming since I was ten, and computer graphics has always been my favorite subject, especially the part connected with games. I worked in the game industry for some small number of years and maybe know a tiny bit about making games.
>
> I spent the last week thinking through a script for a YouTube video about the history of ray tracing and how ray casting, ray marching, ray tracing, and the rest work. I needed to refresh my knowledge and practice. As usual, I got carried away into the weeds and implementation details.
>
> I probably haven't discovered anything new. But the image looks unusual: volumetric smoke that casts shadows and gets lit itself, liminal spaces, fractals, and some pretty strange creatures.
>
> The most interesting part surfaced later. When rays and a distance field evaluate the entire world, the same mechanisms can do more than draw the image. The field provides collisions and force directions, so I needed almost no separate physics code. Sound works in the same way. Rays from a source travel around the scene like light rays and provide reflections, delays, and material absorption.
>
> Yes, in a simplified form, but you won't find this in the vast majority of games. One mechanism covered three parts of the virtual world at once, and that blew me away. A simple renderer built over a few evenings grew into a small engine, even if it was only a demo.
>
> Now I need to understand whether anyone cares about the subject. This is not the fastest approach, and it is less universal than classic polygons with hardware rasterization, but there is something to it)
>
> Basically, repost it, hit like, and leave a comment. If the post gets enough attention, I will probably start developing a complete survival-sandbox demo based on this technology.
