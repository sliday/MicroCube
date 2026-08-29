# MicroCube Metal Visual Proof Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship one native macOS window that renders the approved hybrid voxel, SDF, fractal, Gaussian, lighting, fog, reflection, and refraction scene and explains it in English.

**Architecture:** Keep the 512³ `r8Uint` voxel texture and add a 64³ mixed occupancy grid. One volume-light compute kernel updates active Gaussian cells, then one hybrid image kernel traverses both pyramids, selects the nearest solid hit, integrates volume, and spends at most one secondary ray. AppKit overlays the HUD and scrollable explainer inside the existing window.

**Tech Stack:** Swift 5.10, AppKit, MetalKit, Metal Shading Language, SwiftPM, XCTest, zsh release scripts.

**Spec:** `docs/superpowers/specs/2026-08-30-microcube-visual-proof-design.md`

## Global Constraints

- Keep one `NSWindow`, one `MTKView`, and no auxiliary capture or error windows.
- Keep the minimum deployment target at macOS 14 and the bundle identifier at `com.vseplet.microcube.metal`.
- Preserve the current 512³ 1-voxel terrain and exact mip-zero shadow confirmation.
- Use a 64³ mixed grid with mips 6 through 0; voxel occupancy uses mips 9 through 0.
- Run exactly two steady-state compute passes: `injectVolumeLighting`, then `raycastHybrid`.
- Enforce 16 SDFs, 48 Gaussians, 6 lights, 4,096 active volume cells, and every traversal budget from the spec.
- Keep collision, forces, and spatial audio labeled `CONCEPT`; do not implement those systems.
- Compile the three Metal fragments at runtime in `SceneTypes.metal`, `HybridTraversal.metal`, `MicroCube.metal` order.
- Keep Appendix B byte-identical to packaged `WhyRays.en.txt`; place disclosures outside the quoted text.
- Use `apply_patch` for edits and do not modify `AGENTS.md`.
- Use a failing test before each production behavior change.

## File Structure

- `Package.swift`: shader, explainer, and test resource declarations.
- `Sources/MicroCubeMetal/SharedTypes.swift`: CPU ABI, feature flags, evidence views, metrics.
- `Sources/MicroCubeMetal/Rendering/ShaderSourceLoader.swift`: ordered runtime Metal source assembly.
- `Sources/MicroCubeMetal/Rendering/SceneData.swift`: hero instances, cell bins, active-volume list, cap enforcement.
- `Sources/MicroCubeMetal/Rendering/Renderer.swift`: Metal resources, two-pass scheduling, counters, QA frame output.
- `Sources/MicroCubeMetal/Shaders/SceneTypes.metal`: MSL ABI and constants.
- `Sources/MicroCubeMetal/Shaders/HybridTraversal.metal`: voxel, SDF, fractal, Gaussian, shadow, and optical queries.
- `Sources/MicroCubeMetal/Shaders/MicroCube.metal`: terrain, pyramid, volume-light, and hybrid-image kernels.
- `Sources/MicroCubeMetal/App/MetalInputView.swift`: window-level shortcut handoff and renderer-only movement.
- `Sources/MicroCubeMetal/App/ExplainerPanel.swift`: scrollable English explainer, controls, badges, links, accessibility.
- `Sources/MicroCubeMetal/App/AppMain.swift`: single-window composition, View menu, HUD constraints, QA lifecycle.
- `Sources/MicroCubeMetal/App/QAMode.swift`: deterministic CLI parsing and JSON report models.
- `Sources/MicroCubeMetal/Resources/WhyRays.en.txt`: exact Appendix B copy.
- `Tests/MicroCubeMetalTests/MetalProbeHarness.swift`: production shader compilation and GPU fixture dispatch.
- `Tests/MicroCubeMetalTests/SceneABITests.swift`: Swift/MSL size and offset gates.
- `Tests/MicroCubeMetalTests/SceneDataTests.swift`: bins, caps, overflow, motion, active-volume halo.
- `Tests/MicroCubeMetalTests/ShaderSourceLoaderTests.swift`: source order, compilation, kernel inventory.
- `Tests/MicroCubeMetalTests/MixedTraversalTests.swift`: exact shadows, mixed hits, and budget counters.
- `Tests/MicroCubeMetalTests/SDFProbeTests.swift`: distance, normal, and fractal gates.
- `Tests/MicroCubeMetalTests/VolumeProbeTests.swift`: homogeneous and Gaussian integration, receive/cast shadow gates.
- `Tests/MicroCubeMetalTests/OpticsProbeTests.swift`: reflection, refraction, TIR, secondary depth.
- `Tests/MicroCubeMetalTests/UIStateTests.swift`: focus, shortcuts, responsive panel, accessibility, scale state.
- `Tests/MicroCubeMetalTests/QAModeTests.swift`: CLI, report schema, deterministic lifecycle.
- `scripts/capture-qa.sh`: eleven-row capture matrix and JSON validation.
- `scripts/benchmark.sh`: six fixed M4 Max benchmark runs and worst-p95 gate.
- `scripts/verify-app.sh`: package, signature, resources, kernels, process, and window checks.
- `scripts/verify-completion.sh`: hash-linked completion manifest.

---

### Task 1: Lock the Swift and Metal ABI

**Files:**
- Modify: `Sources/MicroCubeMetal/SharedTypes.swift`
- Create: `Sources/MicroCubeMetal/Shaders/SceneTypes.metal`
- Create: `Tests/MicroCubeMetalTests/SceneABITests.swift`

**Interfaces:**
- Consumes: existing 112-byte `FrameUniforms`.
- Produces: `SceneUniforms`, `CellHeader`, `SDFInstance`, `Gaussian`, `Light`, `Material`, `FrameCounters`, `RenderFeatures`, and `EvidenceView` with the exact layouts in the spec.

- [ ] **Step 1: Write the failing ABI tests**

```swift
func testSceneUniformsABI() {
    XCTAssertEqual(MemoryLayout<SceneUniforms>.size, 64)
    XCTAssertEqual(MemoryLayout<SceneUniforms>.stride, 64)
    XCTAssertEqual(MemoryLayout<SceneUniforms>.alignment, 16)
    XCTAssertEqual(MemoryLayout<SceneUniforms>.offset(of: \SceneUniforms.counts), 0)
    XCTAssertEqual(MemoryLayout<SceneUniforms>.offset(of: \SceneUniforms.grid), 16)
    XCTAssertEqual(MemoryLayout<SceneUniforms>.offset(of: \SceneUniforms.fog), 32)
    XCTAssertEqual(MemoryLayout<SceneUniforms>.offset(of: \SceneUniforms.budgets), 48)
}

func testSceneRecordSizes() {
    XCTAssertEqual(MemoryLayout<CellHeader>.size, 16)
    XCTAssertEqual(MemoryLayout<SDFInstance>.size, 96)
    XCTAssertEqual(MemoryLayout<Gaussian>.size, 48)
    XCTAssertEqual(MemoryLayout<Light>.size, 32)
    XCTAssertEqual(MemoryLayout<Material>.size, 64)
    XCTAssertEqual(MemoryLayout<FrameCounters>.size, 48)
}
```

- [ ] **Step 2: Run the ABI tests and confirm missing-type failures**

Run: `./scripts/test.sh --filter SceneABITests`

Expected: compilation fails because the scene ABI types do not exist.

- [ ] **Step 3: Add the Swift ABI**

```swift
struct SceneUniforms {
    var counts: SIMD4<UInt32>
    var grid: SIMD4<UInt32>
    var fog: SIMD4<Float>
    var budgets: SIMD4<UInt32>
}

struct CellHeader {
    var sdfOffset: UInt32
    var gaussianOffset: UInt32
    var packedCounts: UInt32
    var reserved: UInt32
}

struct SDFInstance {
    var sweptBoundsMin: SIMD4<Float>
    var sweptBoundsMax: SIMD4<Float>
    var positionScale: SIMD4<Float>
    var rotationQuaternion: SIMD4<Float>
    var parameters: SIMD4<Float>
    var metadata: SIMD4<UInt32>
}

struct Gaussian {
    var localCenterSigma: SIMD4<Float>
    var colorDensity: SIMD4<Float>
    var motionPhase: SIMD4<Float>
}

struct Light {
    var positionRadius: SIMD4<Float>
    var colorIntensity: SIMD4<Float>
}

struct Material {
    var baseColorRoughness: SIMD4<Float>
    var emissionMetalness: SIMD4<Float>
    var opticalAbsorptionIOR: SIMD4<Float>
    var transmissionAcoustic: SIMD4<Float>
}

struct FrameCounters {
    var values: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                 UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)
}

struct RenderFeatures: OptionSet {
    let rawValue: UInt32
    static let shadows = Self(rawValue: 1 << 0)
    static let lights = Self(rawValue: 1 << 1)
    static let optics = Self(rawValue: 1 << 2)
    static let sdf = Self(rawValue: 1 << 3)
    static let gaussian = Self(rawValue: 1 << 4)
    static let all: Self = [.shadows, .lights, .optics, .sdf, .gaussian]
}

enum EvidenceView: UInt32, CaseIterable {
    case final, grid, pyramid, steps, cost
}
```

- [ ] **Step 4: Mirror the ABI in `SceneTypes.metal`**

```metal
struct SceneUniforms { uint4 counts; uint4 grid; float4 fog; uint4 budgets; };
struct CellHeader { uint sdfOffset; uint gaussianOffset; uint packedCounts; uint reserved; };
struct SDFInstance {
    float4 sweptBoundsMin; float4 sweptBoundsMax; float4 positionScale;
    float4 rotationQuaternion; float4 parameters; uint4 metadata;
};
struct Gaussian { float4 localCenterSigma; float4 colorDensity; float4 motionPhase; };
struct Light { float4 positionRadius; float4 colorIntensity; };
struct Material {
    float4 baseColorRoughness; float4 emissionMetalness;
    float4 opticalAbsorptionIOR; float4 transmissionAcoustic;
};
struct FrameCounters {
    atomic_uint macroSkips, macroDescents, voxelSteps, sdfSamples, gaussianSamples;
    atomic_uint secondaryRays, surfaceSunShadows, surfaceLocalShadows;
    atomic_uint volumeSunShadows, volumeLocalShadows, budgetOverflows, reserved;
};
```

- [ ] **Step 5: Run all ABI tests**

Run: `./scripts/test.sh --filter SceneABITests`

Expected: all scene layout assertions pass.

- [ ] **Step 6: Commit the ABI checkpoint**

```bash
git add Package.swift Sources/MicroCubeMetal/SharedTypes.swift Sources/MicroCubeMetal/Shaders/SceneTypes.metal Tests/MicroCubeMetalTests/SceneABITests.swift
git commit -m "feat: define hybrid scene ABI"
```

### Task 2: Assemble Runtime Shader Sources

**Files:**
- Modify: `Package.swift`
- Create: `Sources/MicroCubeMetal/Rendering/ShaderSourceLoader.swift`
- Create: `Sources/MicroCubeMetal/Shaders/HybridTraversal.metal`
- Modify: `Sources/MicroCubeMetal/Shaders/MicroCube.metal`
- Modify: `Sources/MicroCubeMetal/Rendering/Renderer.swift`
- Create: `Tests/MicroCubeMetalTests/ShaderSourceLoaderTests.swift`

**Interfaces:**
- Consumes: three shader fragments from the executable target's `Bundle.module`.
- Produces: `ShaderSourceLoader.load(bundle:) throws -> String` and a production library with six named kernels.

- [ ] **Step 1: Write failing source-order and kernel-inventory tests**

```swift
func testSourceFragmentsLoadInDependencyOrder() throws {
    let loaded = try ShaderSourceLoader.load()
    XCTAssertLessThan(try XCTUnwrap(loaded.range(of: "struct SceneUniforms")?.lowerBound),
                      try XCTUnwrap(loaded.range(of: "traceOcclusionExact")?.lowerBound))
    XCTAssertLessThan(try XCTUnwrap(loaded.range(of: "traceOcclusionExact")?.lowerBound),
                      try XCTUnwrap(loaded.range(of: "kernel void raycastHybrid")?.lowerBound))
}

func testRuntimeLibraryExposesProductionKernels() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let library = try device.makeLibrary(source: ShaderSourceLoader.load(), options: nil)
    for name in ["generateTerrain", "reduceOccupancy", "buildMixedOccupancy",
                 "reduceMixedOccupancy", "injectVolumeLighting", "raycastHybrid"] {
        XCTAssertNotNil(library.makeFunction(name: name), name)
    }
}
```

- [ ] **Step 2: Run and confirm the loader is missing**

Run: `./scripts/test.sh --filter ShaderSourceLoaderTests`

Expected: compilation fails on `ShaderSourceLoader`.

- [ ] **Step 3: Implement ordered assembly**

```swift
enum ShaderSourceLoader {
    enum LoaderError: Error { case missing(String) }
    static let fragments = ["SceneTypes", "HybridTraversal", "MicroCube"]

    static func load(bundle: Bundle = .module) throws -> String {
        try fragments.map { name in
            let url = bundle.url(forResource: name, withExtension: "metal", subdirectory: "Shaders")
                ?? bundle.url(forResource: name, withExtension: "metal")
            guard let url else { throw LoaderError.missing(name) }
            return try String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n")
    }
}
```

Keep the default argument inside the executable target so `.module` resolves its copied `Shaders` resources. Tests call `load()` without passing the test target's bundle.

- [ ] **Step 4: Split shared definitions and traversal helpers without local includes**

Move ABI declarations and constants to `SceneTypes.metal`, traversal functions to `HybridTraversal.metal`, and leave kernel entry points in `MicroCube.metal`. Keep `#include <metal_stdlib>` only at the top of `SceneTypes.metal`.

- [ ] **Step 5: Change `Renderer.makeLibrary` to compile assembled source**

```swift
let source = try ShaderSourceLoader.load()
let options = MTLCompileOptions()
if #available(macOS 15.0, *) { options.mathMode = .fast }
else { options.fastMathEnabled = true }
return try device.makeLibrary(source: source, options: options)
```

- [ ] **Step 6: Run loader tests and the full suite**

Run: `./scripts/test.sh --filter ShaderSourceLoaderTests`

Run: `./scripts/test.sh`

Expected: all tests pass and the exact-shadow and terrain-detail regressions remain green.

- [ ] **Step 7: Commit source assembly**

```bash
git add Package.swift Sources/MicroCubeMetal/Rendering/ShaderSourceLoader.swift Sources/MicroCubeMetal/Rendering/Renderer.swift Sources/MicroCubeMetal/Shaders Tests/MicroCubeMetalTests/ShaderSourceLoaderTests.swift
git commit -m "refactor: assemble runtime Metal sources"
```

### Task 3: Build Scene Data and Mixed Occupancy

**Files:**
- Create: `Sources/MicroCubeMetal/Rendering/SceneData.swift`
- Create: `Tests/MicroCubeMetalTests/SceneDataTests.swift`
- Modify: `Sources/MicroCubeMetal/Shaders/MicroCube.metal`
- Modify: `Sources/MicroCubeMetal/Rendering/Renderer.swift`

**Interfaces:**
- Consumes: ABI records from Task 1.
- Produces: `SceneData.makeHero() throws -> SceneData`, cell headers and references, `activeVolumeCells`, and mixed-grid mip kernels.

- [ ] **Step 1: Write failing binning, cap, packing, and halo tests**

```swift
func testPackedCountsUseLowSDFAndHighGaussianHalves() throws {
    let scene = try SceneData.makeHero()
    for header in scene.cellHeaders {
        XCTAssertEqual(Int(header.packedCounts & 0xffff), scene.sdfCount(for: header))
        XCTAssertEqual(Int(header.packedCounts >> 16), scene.gaussianCount(for: header))
        XCTAssertEqual(header.reserved, 0)
    }
}

func testActiveVolumeCellsIncludeOneCellHalo() throws {
    let scene = try SceneData.makeHero()
    XCTAssertLessThanOrEqual(scene.activeVolumeCells.count, 4_096)
    XCTAssertTrue(scene.containsRequiredGaussianHalo())
}

func testOverflowFailsInsteadOfTruncating() {
    XCTAssertThrowsError(try SceneData.build(fixtureWithSDFReferences: 65_536)) {
        XCTAssertEqual($0 as? SceneBuildError, .referenceCountOverflow(kind: "sdf", count: 65_536))
    }
}
```

- [ ] **Step 2: Run and confirm missing scene builder failures**

Run: `./scripts/test.sh --filter SceneDataTests`

Expected: compilation fails on `SceneData` and `SceneBuildError`.

- [ ] **Step 3: Implement cap-checked cell binning**

```swift
enum SceneBuildError: Error, Equatable {
    case capExceeded(name: String, count: Int, maximum: Int)
    case referenceCountOverflow(kind: String, count: Int)
}

struct SceneData {
    let cellHeaders: [CellHeader]
    let cellSDFRefs: [UInt32]
    let cellGaussianRefs: [UInt32]
    let sdfInstances: [SDFInstance]
    let gaussians: [Gaussian]
    let lights: [Light]
    let materials: [Material]
    let activeVolumeCells: [UInt32]

    static func linearIndex(x: Int, y: Int, z: Int) -> UInt32 {
        UInt32(x + 64 * (y + 64 * z))
    }
}
```

Build the cell lists in stable instance-ID order. Bin each swept bound into every intersected eight-unit cell, append a one-cell Gaussian halo, sort and deduplicate `activeVolumeCells`, then validate all caps before returning.

- [ ] **Step 4: Add mixed-grid construction kernels**

```metal
kernel void buildMixedOccupancy(
    texture3d<uint, access::read> voxels [[texture(0)]],
    texture3d<uint, access::write> mixed [[texture(1)]],
    device const CellHeader *headers [[buffer(0)]],
    device const uint *cellSDFRefs [[buffer(1)]],
    device const SDFInstance *sdfs [[buffer(2)]],
    uint3 gid [[thread_position_in_grid]]) {
    if (any(gid >= uint3(64))) return;
    uint index = gid.x + 64u * (gid.y + 64u * gid.z);
    CellHeader header = headers[index];
    uint flags = voxels.read(gid, 3).x != 0u ? 1u : 0u;
    flags |= (header.packedCounts & 0xffffu) != 0u ? 2u : 0u;
    flags |= (header.packedCounts >> 16u) != 0u ? 4u : 0u;
    uint sdfCount = header.packedCounts & 0xffffu;
    for (uint i = 0u; i < sdfCount; ++i) {
        uint4 metadata = sdfs[cellSDFRefs[header.sdfOffset + i]].metadata;
        flags |= (metadata.z & SDF_FLAG_EMISSIVE) != 0u ? 8u : 0u;
        flags |= metadata.x == SDF_KIND_FRACTAL ? 16u : 0u;
    }
    mixed.write(uint4(flags), gid);
}
```

Define `SDF_FLAG_EMISSIVE` and `SDF_KIND_FRACTAL` in `SceneTypes.metal`. `reduceMixedOccupancy` ORs the eight child flags for mips 1 through 6.

- [ ] **Step 5: Allocate and build the mixed texture during renderer initialization**

Create a 64³ seven-mip `r8Uint` texture, upload static scene buffers once, dispatch `buildMixedOccupancy`, then dispatch `reduceMixedOccupancy` for six levels.

- [ ] **Step 6: Run scene tests and full release tests**

Run: `./scripts/test.sh --filter SceneDataTests`

Run: `./scripts/test.sh`

Expected: all scene cap, packing, halo, and baseline tests pass.

- [ ] **Step 7: Commit scene data**

```bash
git add Sources/MicroCubeMetal/Rendering/SceneData.swift Sources/MicroCubeMetal/Rendering/Renderer.swift Sources/MicroCubeMetal/Shaders/MicroCube.metal Tests/MicroCubeMetalTests/SceneDataTests.swift
git commit -m "feat: build mixed scene occupancy"
```

### Task 4: Implement Exact Mixed Traversal, SDFs, and Fractal

**Files:**
- Create: `Tests/MicroCubeMetalTests/MetalProbeHarness.swift`
- Create: `Tests/MicroCubeMetalTests/MixedTraversalTests.swift`
- Create: `Tests/MicroCubeMetalTests/SDFProbeTests.swift`
- Modify: `Tests/MicroCubeMetalTests/ShadowTraversalTests.swift`
- Modify: `Sources/MicroCubeMetal/Shaders/HybridTraversal.metal`
- Modify: `Sources/MicroCubeMetal/Shaders/MicroCube.metal`

**Interfaces:**
- Consumes: voxel and mixed textures plus scene buffers.
- Produces: `traceOcclusionExact`, `traceMixedScene`, primitive distances, finite normals, and per-ray register counters.

- [ ] **Step 1: Extract the real-production Metal test harness**

```swift
enum MetalProbeHarness {
    static func makeLibrary(extraSource: String = "") throws -> (MTLDevice, MTLLibrary) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let source = try ShaderSourceLoader.load() + "\n" + extraSource
        return (device, try device.makeLibrary(source: source, options: nil))
    }
}
```

Refactor the existing shadow and terrain tests to use this harness without changing their assertions.

- [ ] **Step 2: Write failing exact-shadow and mixed-winner probes**

```swift
func testExactShadowFixtureHasNoFalseOrMissedOcclusions() throws {
    let report = try runShadowFixture()
    XCTAssertEqual(report.sampleCount, 10_380)
    XCTAssertEqual(report.legacyMismatch, 404)
    XCTAssertEqual(report.falseShadows, 0)
    XCTAssertEqual(report.missedShadows, 0)
    XCTAssertLessThanOrEqual(report.maxHitDistanceError, 0.002)
}

func testHybridWinnerMatchesBruteForce() throws {
    let report = try runMixedFixture()
    XCTAssertEqual(report.mixedLeafSDFRefs, 2)
    XCTAssertEqual(report.wrongNearestHits, 0)
    XCTAssertLessThanOrEqual(report.maxHitDistanceError, 0.002)
}
```

- [ ] **Step 3: Write failing analytic SDF and fractal probes**

```swift
func testAnalyticSDFDistancesAndNormals() throws {
    let report = try runSDFProbe()
    XCTAssertLessThanOrEqual(report.maxDistanceError, 0.0001)
    XCTAssertLessThanOrEqual(report.maxNormalAngleDegrees, 0.5)
    XCTAssertEqual(report.nonFiniteCount, 0)
}

func testFractalEstimatorStaysFiniteAndOutsideStepsStayPositive() throws {
    let report = try runFractalProbe()
    XCTAssertLessThanOrEqual(report.maxNormalLengthError, 0.001)
    XCTAssertEqual(report.nonFiniteCount, 0)
    XCTAssertEqual(report.negativeExteriorStepCount, 0)
}
```

- [ ] **Step 4: Run probes and confirm missing traversal behavior**

Run: `./scripts/test.sh --filter MixedTraversalTests`

Run: `./scripts/test.sh --filter SDFProbeTests`

Expected: tests fail because mixed traversal and SDF helpers do not exist.

- [ ] **Step 5: Implement bounded primitive functions**

```metal
inline float sdSphere(float3 p, float radius) { return length(p) - radius; }
inline float sdCapsule(float3 p, float3 a, float3 b, float radius) {
    float3 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0f, 1.0f);
    return length(pa - ba * h) - radius;
}
inline float smoothUnion(float a, float b, float k) {
    float h = saturate(0.5f + 0.5f * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0f - h);
}
```

Add the eight-iteration bounded fractal estimator and central-difference normals. Return a positive conservative distance for exterior fractal samples.

- [ ] **Step 6: Implement exact hierarchical occlusion**

`traceOcclusionExact` uses mips only for empty skips, descends occupied nodes to mip zero, applies a normal-facing origin bias plus explicit `tMin` and `tMax`, advances cell exits with `nextafter`, and uses X-before-Y-before-Z ties. Preserve the passing off-ray-neighbor regression.

- [ ] **Step 7: Implement one-evaluation-per-instance mixed traversal**

Intersect `sweptBounds`, evaluate only in the leaf containing `tSweptEnter`, intersect current animated bounds, and march once through `min(currentBoundsExit, nearestVoxelT)`. Enforce 24 smooth, 32 creature, 48 fractal, 8 fractal-iteration, and 4,096 DDA limits.

- [ ] **Step 8: Run all traversal probes**

Run: `./scripts/test.sh --filter MixedTraversalTests`

Run: `./scripts/test.sh --filter SDFProbeTests`

Run: `./scripts/test.sh --filter ShadowTraversalTests`

Expected: all exact-shadow, mixed-winner, SDF, and fractal probes pass.

- [ ] **Step 9: Commit mixed traversal**

```bash
git add Sources/MicroCubeMetal/Shaders Tests/MicroCubeMetalTests
git commit -m "feat: trace voxels SDFs and fractal"
```

### Task 5: Add Creatures, Animated Lights, and Gaussian Volume Lighting

**Files:**
- Modify: `Sources/MicroCubeMetal/Rendering/SceneData.swift`
- Modify: `Sources/MicroCubeMetal/Rendering/Renderer.swift`
- Modify: `Sources/MicroCubeMetal/Shaders/HybridTraversal.metal`
- Modify: `Sources/MicroCubeMetal/Shaders/MicroCube.metal`
- Create: `Tests/MicroCubeMetalTests/VolumeProbeTests.swift`
- Modify: `Tests/MicroCubeMetalTests/SceneDataTests.swift`

**Interfaces:**
- Consumes: six swept SDF creatures, six lights, 48-or-fewer Gaussians, and active volume indices.
- Produces: deterministic animation, `rgba16Float` incident-light texture, Gaussian integration, and receive/cast smoke shadows.

- [ ] **Step 1: Write failing deterministic motion tests**

```swift
func testHeroHasSixCreaturesAndSixLights() throws {
    let scene = try SceneData.makeHero()
    XCTAssertEqual(scene.creatureCount, 6)
    XCTAssertEqual(scene.lights.count, 6)
}

func testMotionProbeIsRepeatableAndChangesAtOneSecond() throws {
    let first = try runMotionProbe(time: 0)
    let repeatFrame = try runMotionProbe(time: 0)
    let oneSecond = try runMotionProbe(time: 1)
    XCTAssertEqual(first.transformBytes, repeatFrame.transformBytes)
    XCTAssertEqual(first.lightBytes, repeatFrame.lightBytes)
    XCTAssertNotEqual(first.transformBytes, oneSecond.transformBytes)
    XCTAssertNotEqual(first.lightBytes, oneSecond.lightBytes)
}
```

- [ ] **Step 2: Write failing volume integration and shadow tests**

```swift
func testVolumeIntegrationMatchesAnalyticReferences() throws {
    let report = try runVolumeProbe()
    XCTAssertLessThanOrEqual(report.maxHomogeneousRelativeError, 0.02)
    XCTAssertLessThanOrEqual(report.maxGaussianRelativeError, 0.02)
    XCTAssertEqual(report.nonFiniteCount, 0)
}

func testSmokeReceivesAndCastsSunAndLocalShadows() throws {
    let report = try runVolumeShadowProbe()
    XCTAssertLessThan(report.sunShadowRadianceRatio, 0.35)
    XCTAssertLessThan(report.localShadowRadianceRatio, 0.35)
    XCTAssertLessThan(report.smokeSunReceiverRatio, 1.0)
    XCTAssertLessThan(report.smokeLocalReceiverRatio, 1.0)
}
```

- [ ] **Step 3: Run tests and confirm missing motion and volume behavior**

Run: `./scripts/test.sh --filter SceneDataTests`

Run: `./scripts/test.sh --filter VolumeProbeTests`

Expected: the new motion and volume assertions fail.

- [ ] **Step 4: Author the six creature and light paths**

Use stable IDs 0 through 5. Keep instance and light buffers static. Derive position and organ-light radius in Metal from frame time and fixed sine phases in `motionPhase`, and expose the same transform function to the motion probe. Keep all current bounds inside the authored swept bounds and inside the center or left-center reset composition. Do not rebuild or upload the mixed grid per frame.

- [ ] **Step 5: Implement analytic Gaussian density and transmittance**

```metal
inline float gaussianDensity(float3 p, constant Gaussian &g) {
    float3 d = p - g.localCenterSigma.xyz;
    float sigma = max(g.localCenterSigma.w, 0.001f);
    return g.colorDensity.w * exp(-0.5f * dot(d, d) / (sigma * sigma));
}
```

Integrate density only within referenced bounds. Use analytic optical depth for shadow transmittance and bounded numeric integration for camera scattering.

- [ ] **Step 6: Implement `injectVolumeLighting` over the active list**

Decode `x + 64 * (y + 64 * z)`, evaluate sun plus all six lights into RGB, store sun transmittance in alpha, and evaluate exact sun plus one strongest-local shadow. Write evaluated lighting into halo cells so trilinear samples stay continuous.

- [ ] **Step 7: Bind volume resources and dispatch before `raycastHybrid`**

Allocate 64³ `rgba16Float`, clear it once to `(0,0,0,1)`, bind `activeVolumeCells`, dispatch one thread per active index, then issue the image pass in the same command buffer.

- [ ] **Step 8: Run motion, volume, and full tests**

Run: `./scripts/test.sh --filter SceneDataTests`

Run: `./scripts/test.sh --filter VolumeProbeTests`

Run: `./scripts/test.sh`

Expected: deterministic motion and both smoke-shadow directions pass.

- [ ] **Step 9: Commit animated volume lighting**

```bash
git add Sources/MicroCubeMetal/Rendering Sources/MicroCubeMetal/Shaders Tests/MicroCubeMetalTests
git commit -m "feat: light animated Gaussian creatures"
```

### Task 6: Add Reflection and Refraction

**Files:**
- Modify: `Sources/MicroCubeMetal/Shaders/HybridTraversal.metal`
- Modify: `Sources/MicroCubeMetal/Shaders/MicroCube.metal`
- Create: `Tests/MicroCubeMetalTests/OpticsProbeTests.swift`

**Interfaces:**
- Consumes: analytic sphere glass object, wet reflective material, one-secondary-ray budget.
- Produces: two-interface Snell refraction, Beer absorption, Fresnel sky reflection, and bounded reflection.

- [ ] **Step 1: Write failing optical math and recursion tests**

```swift
func testOpticalDirectionsMatchAnalyticReferences() throws {
    let report = try runOpticsProbe()
    XCTAssertLessThanOrEqual(report.maxReflectionDirectionError, 0.0001)
    XCTAssertLessThanOrEqual(report.maxRefractionDirectionError, 0.0001)
    XCTAssertEqual(report.tirFailureCount, 0)
}

func testSecondaryHitsDoNotSpawnOpticalRays() throws {
    XCTAssertEqual(try runOpticsProbe().recursiveSecondaryRayCount, 0)
}
```

- [ ] **Step 2: Run and confirm optics failures**

Run: `./scripts/test.sh --filter OpticsProbeTests`

Expected: probes fail because optical scene paths do not exist.

- [ ] **Step 3: Implement the analytic glass sphere path**

Compute entry and exit intersections and normals, apply `refract` at air-to-glass and glass-to-air interfaces, switch to reflection on total internal reflection, and multiply transmission by `exp(-absorption * distanceInside)`.

- [ ] **Step 4: Implement the single secondary trace budget**

Reflective pixels spend the one ray on reflection. Glass pixels spend it after sphere exit. Secondary hits receive ambient plus unshadowed sun and local diffuse and cannot cast shadow or optical rays.

- [ ] **Step 5: Run optics and full tests**

Run: `./scripts/test.sh --filter OpticsProbeTests`

Run: `./scripts/test.sh`

Expected: all optical thresholds and prior traversal tests pass.

- [ ] **Step 6: Commit optics**

```bash
git add Sources/MicroCubeMetal/Shaders Tests/MicroCubeMetalTests/OpticsProbeTests.swift
git commit -m "feat: add bounded reflection and refraction"
```

### Task 7: Integrate Evidence Views, Counters, HUD, and Adaptive Scale

**Files:**
- Modify: `Sources/MicroCubeMetal/SharedTypes.swift`
- Modify: `Sources/MicroCubeMetal/Rendering/Renderer.swift`
- Modify: `Sources/MicroCubeMetal/Shaders/MicroCube.metal`
- Create: `Tests/MicroCubeMetalTests/UIStateTests.swift`
- Modify: `Sources/MicroCubeMetal/App/MetalInputView.swift`
- Modify: `Sources/MicroCubeMetal/App/AppMain.swift`

**Interfaces:**
- Consumes: `EvidenceView`, `RenderFeatures`, `FrameCounters`.
- Produces: keys 1 through 5, G/K/L/O/X/P/H controls, triple-buffered counters, HUD state, and deterministic scale controller.

- [ ] **Step 1: Write failing renderer-state tests**

```swift
func testEvidenceKeysOnlyChangeEvidenceView() {
    var state = RenderState()
    state.apply(.evidence(.pyramid))
    XCTAssertEqual(state.evidenceView, .pyramid)
    XCTAssertEqual(state.features, .all)
}

func testAdaptiveScaleMovesWithinBoundsAndFixedModeDoesNotMove() {
    var adaptive = RenderScaleController(scale: 0.70, mode: .adaptive)
    adaptive.record(gpuMilliseconds: 12)
    XCTAssertLessThan(adaptive.scale, 0.70)
    XCTAssertGreaterThanOrEqual(adaptive.scale, 0.35)
    var fixed = RenderScaleController(scale: 1.0, mode: .fixed)
    for _ in 0..<900 { fixed.record(gpuMilliseconds: 30) }
    XCTAssertEqual(fixed.scale, 1.0)
}
```

- [ ] **Step 2: Run and confirm missing state-controller failures**

Run: `./scripts/test.sh --filter UIStateTests`

Expected: tests fail on missing render state and scale controller.

- [ ] **Step 3: Implement render state and input actions**

Define `RenderAction` cases for five views, five feature toggles, pause, HUD, explainer, fullscreen, reset, and Escape. Ignore Command, Control, and Option modified renderer shortcuts.

- [ ] **Step 4: Triple-buffer frame counters**

Allocate three 48-byte buffers. Clear a slot only after its prior command buffer completes. Enable atomic aggregation only for `steps`, `cost`, and probes. Require every SIMD lane to reach each `simd_sum`, with out-of-viewport lanes contributing zero.

- [ ] **Step 5: Implement five shader presentations**

`final` shades the completed image. `grid` colors mixed leaf flags. `pyramid` shows mixed mip 6 to 0 and voxel mip 9 to 0. `steps` colors thread-local method counts. `cost` maps thread-local total work and overlays measured GPU time in the HUD.

- [ ] **Step 6: Update HUD claims and layout callback**

```text
SCENE 1/5 · FINAL FIELD · 2 COMPUTE PASSES · {LIVE FPS} · {LIVE GPU MS} · {DRAWABLE}
MIXED 64³ MIP 6→0 · VOXELS 512³ MIP 9→0 · VOXEL DDA + SDF RM + GAUSSIAN
```

Omit step totals when aggregation is disabled. Expose a HUD trailing-anchor callback for the explainer panel.

- [ ] **Step 7: Run state, input, and full tests**

Run: `./scripts/test.sh --filter UIStateTests`

Run: `./scripts/test.sh --filter InputStateTests`

Run: `./scripts/test.sh`

Expected: state isolation, scale bounds, shortcut filtering, and all prior tests pass.

- [ ] **Step 8: Commit evidence controls**

```bash
git add Sources/MicroCubeMetal Tests/MicroCubeMetalTests/UIStateTests.swift
git commit -m "feat: expose hybrid evidence views"
```

### Task 8: Build the English Explainer Inside the Existing Window

**Files:**
- Modify: `Package.swift`
- Create: `Sources/MicroCubeMetal/App/ExplainerPanel.swift`
- Modify: `Sources/MicroCubeMetal/App/AppMain.swift`
- Modify: `Sources/MicroCubeMetal/App/MetalInputView.swift`
- Create: `Sources/MicroCubeMetal/Resources/WhyRays.en.txt`
- Modify: `Tests/MicroCubeMetalTests/UIStateTests.swift`
- Create: `Tests/MicroCubeMetalTests/ExplainerResourceTests.swift`

**Interfaces:**
- Consumes: Appendix B copy, evidence-view and feature actions.
- Produces: right-side scrollable panel, collapsed rail, native links, View commands, accessibility labels, and source disclosures.

- [ ] **Step 1: Write failing resource-identity and responsive-layout tests**

```swift
func testPackagedEnglishCopyMatchesSpecExtraction() throws {
    XCTAssertEqual(try ExplainerCopy.packagedBytes(), try ExplainerCopy.specAppendixBytes())
}

func testPanelLayoutBreakpointAndHUDClearance() {
    XCTAssertEqual(ExplainerLayout.state(windowWidth: 1099), .collapsed)
    XCTAssertEqual(ExplainerLayout.state(windowWidth: 1100), .expanded(width: 424))
    XCTAssertEqual(ExplainerLayout.hudClearance, 16)
}
```

- [ ] **Step 2: Run and confirm missing explainer failures**

Run: `./scripts/test.sh --filter ExplainerResourceTests`

Run: `./scripts/test.sh --filter UIStateTests`

Expected: resource and layout types are missing.

- [ ] **Step 3: Copy Appendix B byte-for-byte into `WhyRays.en.txt`**

Use UTF-8 without BOM, two LF bytes between passages, and one final LF. Add `Resources` to the executable target.

- [ ] **Step 4: Implement the interactive `NSVisualEffectView` panel**

Build one `NSScrollView` with headings `IN THIS MAC DEMO`, `FROM THE AUTHOR'S POSTS`, `CONCEPT FOR THIS MAC DEMO`, and `AUTHOR'S SOURCES`. Add focusable evidence buttons, 13-point-or-larger body copy, native link controls, and a close button labeled `Close Why Rays explainer`.

- [ ] **Step 5: Add persistent disclosures outside quoted text**

Use `SOURCE QUOTE · ORIGINAL AUTHOR'S DEMO`, `SOURCE CLAIM · NOT A RESULT FROM THIS MAC APP`, `CURRENT MAC APP · 1 HYBRID IMAGE KERNEL + 1 VOLUME LIGHT KERNEL`, and `CONCEPT IN THIS MAC DEMO · NO PHYSICS OR AUDIO SYSTEM RUNS HERE` in the locations defined by the spec.

- [ ] **Step 6: Wire focus, menus, and window-level commands**

`I`, Escape, nonmovement renderer shortcuts, close, and View-menu explainer/HUD commands work while panel controls own focus. WASD/QE and mouse look run only while the `MTKView` owns focus and capture. The collapsed rail is a focusable button labeled `Open Why Rays explainer`.

- [ ] **Step 7: Add contrast, motion, and VoiceOver behavior**

Increase overlay opacity under Increased Contrast. Freeze creature and light motion under Reduce Motion while allowing manual camera movement. Announce evidence and toggle state changes through accessibility notifications.

- [ ] **Step 8: Run explainer and full tests**

Run: `./scripts/test.sh --filter ExplainerResourceTests`

Run: `./scripts/test.sh --filter UIStateTests`

Run: `./scripts/test.sh`

Expected: byte identity, breakpoint, focus, label, and shortcut tests pass.

- [ ] **Step 9: Commit the explainer**

```bash
git add Package.swift Sources/MicroCubeMetal/App Sources/MicroCubeMetal/Resources Tests/MicroCubeMetalTests
git commit -m "feat: add in-window English explainer"
```

### Task 9: Add Deterministic QA Mode and JSON Probes

**Files:**
- Create: `Sources/MicroCubeMetal/App/QAMode.swift`
- Modify: `Sources/MicroCubeMetal/App/AppMain.swift`
- Modify: `Sources/MicroCubeMetal/Rendering/Renderer.swift`
- Create: `Tests/MicroCubeMetalTests/QAModeTests.swift`
- Modify: `Tests/MicroCubeMetalTests/MixedTraversalTests.swift`
- Modify: `Tests/MicroCubeMetalTests/SDFProbeTests.swift`
- Modify: `Tests/MicroCubeMetalTests/VolumeProbeTests.swift`
- Modify: `Tests/MicroCubeMetalTests/OpticsProbeTests.swift`

**Interfaces:**
- Consumes: exact CLI contract and probe metrics from the spec.
- Produces: one-window deterministic execution, PNG capture, versioned probe and frame JSON, and nonzero failure exit.

- [ ] **Step 1: Write failing CLI and report-schema tests**

```swift
func testParsesDeterministicCaptureArguments() throws {
    let mode = try QAMode.parse([
        "--qa-scene", "hero", "--qa-time", "1", "--qa-step", "0.008333333333333333",
        "--qa-camera", "reset", "--qa-window-points", "1280x800",
        "--qa-drawable", "1280x800", "--qa-scale", "1", "--qa-view", "final",
        "--qa-frames", "1", "--qa-capture-scope", "drawable",
        "--qa-capture", "/tmp/hero.png", "--qa-report", "/tmp/hero.json"
    ])
    XCTAssertEqual(mode.scene, .hero)
    XCTAssertEqual(mode.drawablePixels, SIMD2(1280, 800))
    XCTAssertEqual(mode.renderScale, 1)
}
```

- [ ] **Step 2: Run and confirm missing QA parser failures**

Run: `./scripts/test.sh --filter QAModeTests`

Expected: compilation fails on `QAMode`.

- [ ] **Step 3: Implement strict argument parsing**

Support every `--qa-*` and `--benchmark-*` option from the spec. Reject missing values, unknown scenes, invalid sizes, scales outside 0.35 through 1.0, and nonpositive frame counts with a readable `QAError`.

- [ ] **Step 4: Implement one-window QA lifecycle**

Create the normal `NSWindow` and `MTKView`, disable adaptive state and wall-clock motion, render fixed frames, copy the drawable before presentation or capture the existing content view after AppKit layout, write JSON, call `NSApplication.stop`, wake the event loop, and call `exit(status)` only after `application.run()` returns.

- [ ] **Step 5: Emit exact probe envelopes**

```swift
struct ProbeEnvelope<Metrics: Codable>: Codable {
    let schemaVersion: Int
    let probe: String
    let fixtureVersion: Int
    let status: String
    let failure: String?
    let device: String
    let metrics: Metrics
}
```

Use the exact metric names and thresholds from the spec for `shadow`, `mixed`, `budgets`, `sdf`, `optics`, `volume`, `motion`, and `ui`.

- [ ] **Step 6: Make renderer failures observable**

Change `Renderer` to a throwing initializer. `RendererError` carries allocation, resource, kernel, pipeline, or compiler diagnostics. `AppMain` displays the same message in the existing window; QA writes it and exits nonzero.

- [ ] **Step 7: Run QA, probe, and full tests**

Run: `./scripts/test.sh --filter QAModeTests`

Run: `./scripts/test.sh --filter ProbeTests`

Run: `./scripts/test.sh`

Expected: parser rejection, JSON field, deterministic time, and all GPU probes pass.

- [ ] **Step 8: Commit deterministic QA**

```bash
git add Sources/MicroCubeMetal/App/QAMode.swift Sources/MicroCubeMetal/App/AppMain.swift Sources/MicroCubeMetal/Rendering/Renderer.swift Tests/MicroCubeMetalTests
git commit -m "feat: add deterministic one-window QA"
```

### Task 10: Add Capture, Benchmark, Package, and Completion Scripts

**Files:**
- Create: `scripts/capture-qa.sh`
- Create: `scripts/benchmark.sh`
- Create: `scripts/verify-app.sh`
- Create: `scripts/verify-completion.sh`
- Modify: `scripts/build-app.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: packaged QA CLI and JSON schemas.
- Produces: eleven-row visual manifest, six benchmark reports, trace review, package report, and hash-linked completion report.

- [ ] **Step 1: Write script contract tests in `QAModeTests`**

Run each verifier against a temporary fixture bundle and assert exit 0 for valid evidence and nonzero for a stale PNG hash, missing kernel, wrong architecture, invalid benchmark sample count, or window count other than one.

- [ ] **Step 2: Run and confirm missing-script failures**

Run: `./scripts/test.sh --filter ScriptContractTests`

Expected: tests fail because the four scripts do not exist.

- [ ] **Step 3: Implement `capture-qa.sh`**

Run all eleven matrix rows with fixed scene, time, view, feature mask, size, and capture scope. Validate each frame JSON, calculate `shasum -a 256`, and write `dist/evidence/visual-review.json` with a nonempty capture array per row.

- [ ] **Step 4: Implement `benchmark.sh`**

Require `Apple M4 Max` and nominal thermal state. Run 1280×800 and 2560×1600 three times each with 180 warmup and 900 measured frames. Validate 900 positive finite samples, nearest-rank p95, two passes, all features, zero command errors, zero drawable failures, and zero semaphore timeouts.

- [ ] **Step 5: Implement `verify-app.sh`**

Verify plist values, macOS 14 minimum, arm64 executable, `codesign --verify --deep --strict`, all three shader sources, `WhyRays.en.txt`, six kernels, one process, and `windowCount == 1`. Extract Appendix B with the exact LF rules before comparing bytes.

- [ ] **Step 6: Implement `verify-completion.sh`**

Require every probe report, all eleven reviewed capture rows with matching hashes, six valid benchmark reports, a matching Metal trace review, release XCTest success, and package verification. Write `completion.json` with every input SHA-256 and set `status` to `pass` only when all gates pass.

- [ ] **Step 7: Run script tests and build the package**

Run: `./scripts/test.sh --filter ScriptContractTests`

Run: `./scripts/build-app.sh`

Run: `./scripts/verify-app.sh "dist/MicroCube Metal.app"`

Expected: tests pass and package verification returns exit 0.

- [ ] **Step 8: Commit release tooling**

```bash
git add scripts README.md Tests/MicroCubeMetalTests
git commit -m "test: verify visual proof release"
```

### Task 11: Run the Final Visual and Performance Gate

**Files:**
- Modify only when a failing gate identifies a specific defect in its owning file.
- Produce: `dist/evidence/**`

**Interfaces:**
- Consumes: packaged app and all QA scripts.
- Produces: current captures, benchmark reports, trace review, visual review, package report, and `completion.json`.

- [ ] **Step 1: Run the full release suite**

Run: `./scripts/test.sh`

Expected: every XCTest and GPU probe passes with zero failures.

- [ ] **Step 2: Build and verify the signed arm64 app**

Run: `./scripts/build-app.sh`

Run: `./scripts/verify-app.sh "dist/MicroCube Metal.app"`

Expected: runtime source compilation, resources, signature, architecture, process, and one-window checks pass.

- [ ] **Step 3: Generate the eleven capture rows**

Run: `./scripts/capture-qa.sh`

Inspect each current PNG. Record reviewer, timestamp, pass or fail, and notes in `visual-review.json`. Re-run the script after any visual fix so hashes match current files.

- [ ] **Step 4: Record the M4 Max benchmarks**

Run: `./scripts/benchmark.sh`

Expected: worst of three p95 values is at most 8.33 ms at 1280×800 and at most 16.67 ms at 2560×1600, with all validity fields passing.

- [ ] **Step 5: Record Metal System Trace evidence**

Capture the steady-state full-feature benchmark, hash the trace, and write `trace-review.json` with two compute passes, zero per-frame CPU texture uploads, and zero steady-state `waitUntilCompleted` calls.

- [ ] **Step 6: Produce the completion manifest**

Run: `./scripts/verify-completion.sh`

Expected: `dist/evidence/completion.json` contains `"status": "pass"` and current hashes for every required artifact.

- [ ] **Step 7: Commit source and documentation corrections only**

Do not commit `dist/evidence` unless the repository policy changes. Commit any gate-driven source or README correction with the narrowest matching message, then rerun Steps 1 through 6.
