# Task 9A report: hero voxel scale

## Signature review before test edits

- `SceneData.makeHero() throws -> SceneData` constructs the authored hero scene. `SceneData.build(sdfInstances:gaussians:lights:materials:) throws -> SceneData` validates bounds, caps, and leaf references.
- `SDFInstance.positionScale`, `Gaussian.localCenterSigma`, and `Light.positionRadius` are `SIMD4<Float>` values. Hero SDF kind `1` uses `positionScale.w` as radius and `parameters.x` as height.
- `Renderer.initialCameraPosition` was a private static `SIMD3<Float>`, so tests could not inspect reset-camera positioning. It is package-visible for the direct dolly assertion.
- The unscaled authored values were creature radius `3`, height `12`, light offset `7.2`, light radius `22`, Gaussian sigma `3.2`, Gaussian density `0.34`, and reset camera `SIMD3<Float>(256.5, 112.0, 256.5)`.

## TDD evidence

### RED

Command:

```sh
./scripts/test.sh --filter 'SceneDataTests/testHeroPresentationScale'
```

Output: compilation stopped at `SceneData.heroPresentationScale` and `SceneData.heroAnchor`, because the unscaled production scene exposed neither required authored value. The pending assertions specified radius `4.5`, height `18`, light offset `10.8`, light radius `33`, Gaussian sigma `4.8`, density `0.34 / 1.5`, and dolly camera `SIMD3<Float>(240.75, 117, 233.75)`.

### GREEN

Command:

```sh
./scripts/test.sh --filter 'SceneDataTests/testHeroPresentationScale'
```

Output: `Executed 2 tests, with 0 failures`.

The focused tests assert the presentation scale and anchor, every non-creature SDF center/radius/bounds, every creature radius/height/lower extent, six attached-light offsets and radii, Gaussian position/sigma/density, reset-camera dolly equation, world bounds, and existing scene caps.

## Authored values

- `SceneData.heroPresentationScale = 1.5`
- `SceneData.heroAnchor = SIMD3<Float>(288, 102, 302)`
- Sculpture, fractal, and glass centers and swept bounds scale around the anchor. Their radii change from `7, 7, 5` to `10.5, 10.5, 7.5`.
- Creature X/Z positions scale around the anchor. Radius changes from `3` to `4.5`; height changes from `12` to `18`; each Y center preserves `centerY - height * 0.5 - radius * 0.32`.
- Creature Y centers are `99.48, 98.48, 99.48, 98.48, 99.48, 98.48`. Their scaled bounds include the unchanged animation offsets and enlarged head.
- Attached lights use each new creature center, Y offset `10.8`, radius `33`, existing colors/intensity, and unchanged animation formula.
- Gaussian centers scale around the anchor. Sigma changes from `3.2` to `4.8`; density changes from `0.34` to `0.22666667` (`0.34 / 1.5`).
- Reset camera uses `heroAnchor + (SIMD3<Float>(256.5, 112, 256.5) - heroAnchor) * heroPresentationScale`, yielding `SIMD3<Float>(240.75, 117, 233.75)`. Yaw remains `0.6`; pitch remains `-0.18`.

## Release QA

Release build command:

```sh
./scripts/build-app.sh
```

The release app built successfully at `dist/MicroCube Metal.app`.

Fixed capture command used the release executable with `hero`, `all` features, time `1`, fixed step `1/120`, reset camera, `1280x800` window and drawable, scale `1`, and final view.

- Baseline capture: `/tmp/microcube-before-voxels.png`
  - SHA-256: `64884f048f35b721950e77f24cbd3ee5e10c6ed0368ed9e490151e7eb507cb3e`
- Fixed post-change capture: `/tmp/microcube-after-voxels.png`
  - SHA-256: `e234a3f985bf56332ba1382303138bd0ccb84ad433da900e7452ea51f9072f7d`
  - Report: `/tmp/microcube-post-scale-capture.json`

Visual review: terrain cells project at about two-thirds of the baseline size relative to the hero. The glass sphere, sculpture, fractal, and fog remain visible. The hero keeps close projected height. The scene tests verify all six creatures retain their lower extent and every light remains attached.

Fixed-capture runtime validity: `status=pass`, `failure=null`, device `Apple M4 Max`, `windowCount=1`, `passCount=2`, `featureMask=all`, `commandErrors=0`, `droppedDrawables=0`, `semaphoreTimeouts=0`, `budgetOverflows=1281`. The pre-change capture reported 2220 runtime overflows. Exact-shadow and fixed-budget GPU probe tests report zero failures.

## Benchmark

Command used the release executable with the same fixed 1280 by 800 hero configuration, 20 warmup frames, and 60 measured frames.

- Baseline p95: `5.71170833427459 ms`
- Allowed p95: `5.997293750988319 ms`
- Post-change p95: `5.8938750298693776 ms`
- Delta: `+3.19%`
- Result: pass, within the 5% limit.

Benchmark runtime validity: `status=pass`, `failure=null`, `windowCount=1`, `passCount=2`, `commandErrors=0`, `droppedDrawables=0`, `semaphoreTimeouts=0`, `budgetOverflows=1285`, thermal state `nominal` before and after. Report: `/tmp/microcube-post-scale-benchmark.json`.

## Test suite and review

Commands run:

```sh
./scripts/test.sh --filter ShadowTraversalTests
./scripts/test.sh --filter MixedTraversalTests
./scripts/test.sh --filter VolumeProbeTests
./scripts/test.sh
```

- `ShadowTraversalTests`: 2 passed, including zero false and missed exact-shadow occlusions.
- `MixedTraversalTests`: 6 passed, including fixed traversal budgets.
- `VolumeProbeTests`: 4 passed.
- Full release suite: 92 passed, 0 failures.

Self-review: the change only updates hero scene authored data, reset camera position, and focused scene tests. It preserves the 512-cubed `r8Uint` texture, mip-zero shadow traversal, ray budgets, shaders, compute passes, texture formats, and release scripts. No traversal code changed. All SDF and Gaussian bounds remain inside the 512-unit world, and existing caps remain satisfied.

`git diff --check`: passed with no output.

## Fix round 1 diagnosis

The first post-change capture reduced terrain cells to the target scale, but anchor-scaling the creature X/Z centers moved the group onto a ridge. The enlarged creature heads and attached lights remained visible while their bodies fell behind terrain. The correction keeps the 1.5x form dimensions, light offsets/radii, Gaussian sigma/density, and 1.5x reset-camera distance. It restores authored hero, creature, and Gaussian centers, then expands each SDF swept bound around its own center. The focused RED test now also covers all eight Gaussians, explicit scene/leaf caps, and the 2/3 voxel and 1.0 hero projection equations.

### Fix round 1 RED

```sh
./scripts/test.sh --filter 'SceneDataTests/testHeroPresentationScale'
```

Output: 49 expected failures, including the anchor-scaled sculpture centers and all eight Gaussian centers. The failures established that the existing composition moved authored centers instead of retaining the hero placement.

The terrain-contact RED command was:

```sh
./scripts/test.sh --filter 'SceneDataTests/testHero'
```

The production-shader probe returned terrain heights `85, 88, 94, 78, 85, 96`. Five of six old lower extents failed the one-voxel contact limit: creature 0 `89.04` versus `85`, creature 2 `89.04` versus `94`, creature 3 `88.04` versus `78`, creature 4 `89.04` versus `85`, and creature 5 `88.04` versus `96`.

### Fix round 1 GREEN

```sh
./scripts/test.sh --filter 'SceneDataTests/testHero'
```

Output: `Executed 5 tests, with 0 failures`.

The final creature centers retain authored X/Z and use Y values `95.44, 98.44, 104.44, 88.44, 95.44, 106.44`. Their lower extents equal the production `terrainHeight` results within one voxel. The test compiles the production shader and calls `terrainHeight` on GPU; it does not duplicate the terrain formula in Swift. Attached light X/Z and Y remain derived from each corrected creature center.

The focused presentation tests now enumerate all eight Gaussian centers, assert sigma `4.8` and density `0.34 / 1.5` for each, assert the SDF/Gaussian/light/active-cell caps, assert the eight and sixteen reference-per-leaf limits, and numerically assert `baselineDistance / newDistance = 2 / 3` plus `1.5 / newDistance / (1 / baselineDistance) = 1.0` for the hero projection ratio.

## Fix round 1 visual and benchmark evidence

The release reset capture is `/tmp/microcube-after-voxels-round1-grounded.png`.

- SHA-256: `83a032585913a146f9200fde15e403faa4ed6dbf5717956dd02038f1cafc4881`
- QA report: `/tmp/microcube-post-scale-round1-grounded-capture.json`
- Runtime validity: `status=pass`, `failure=null`, `windowCount=1`, `passCount=2`, `featureMask=all`, `commandErrors=0`, `droppedDrawables=0`, `semaphoreTimeouts=0`, `budgetOverflows=1262`.

Visual review: the production-terrain probe confirms six grounded bodies and the capture no longer presents a terrain-driven separation between creature centers and attached lights. The terrain cells remain about two-thirds of the baseline relative to the enlarged hero. The group remains visually dense behind the glass sphere. I rejected pitch-only and small-orbit candidates because neither improved readability and both added composition changes without a measured benefit; the committed camera stays at the specified 1.5x-distance reset view.

Required regressions passed after the grounding correction:

```sh
./scripts/test.sh --filter ShadowTraversalTests
./scripts/test.sh --filter MixedTraversalTests
./scripts/test.sh --filter VolumeProbeTests
./scripts/test.sh
```

Results: `ShadowTraversalTests` 2 passed, `MixedTraversalTests` 6 passed, `VolumeProbeTests` 4 passed, full release suite 93 passed with 0 failures.

The first 20-warmup/60-sample run recorded `6.0812917072325945 ms`, over the `5.997293750988319 ms` gate. A repeat under the same fixed configuration recorded `5.57337497593835 ms`, which passes the gate and is `-2.42%` from the `5.71170833427459 ms` baseline. The passing report is `/tmp/microcube-post-scale-round1-grounded-benchmark-repeat.json`: `status=pass`, `failure=null`, `windowCount=1`, `passCount=2`, `commandErrors=0`, `droppedDrawables=0`, `semaphoreTimeouts=0`, `budgetOverflows=1249`, thermal state `nominal` before and after.

`git diff --check`: passed with no output after the fix-round changes.
