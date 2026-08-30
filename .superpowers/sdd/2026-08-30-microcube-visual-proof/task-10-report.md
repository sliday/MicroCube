# Task 10 Report: Release Tooling

## Scope

Implemented the release capture, benchmark, package-verification, and completion-verification scripts. Added arm64 packaging, release workflow documentation, and script contract tests.

## Interface checks before test edits

- `QAMode` accepts the documented QA capture and benchmark arguments. Benchmark defaults are 180 warmup frames and 900 measured frames.
- `QAFrameReport` uses schema version 1 and supplies `windowCount`, `productionKernels`, `passCount`, renderer error counts, thermal states, raw `gpuMilliseconds`, and nearest-rank `p95GPUms`.
- The report model lists `clearVolumeLighting` in addition to the package gate's six required kernels. The package verifier enforces the six named release kernels: `generateTerrain`, `reduceOccupancy`, `buildMixedOccupancy`, `reduceMixedOccupancy`, `injectVolumeLighting`, and `raycastHybrid`.
- SwiftPM copies shader and text resources into the app's nested SwiftPM resource bundle. Package verification searches the app resources recursively.

## TDD record

Added `ScriptContractTests` before implementing the four scripts.

RED command:

```sh
./scripts/test.sh --filter ScriptContractTests
```

The first sandboxed invocation could not execute SwiftPM's manifest sandbox. The permitted local-Xcode invocation reached the intended RED state: `verify-completion.sh` and `verify-app.sh` did not exist, zsh returned 127, and the expected completion/package reports were absent.

GREEN command:

```sh
./scripts/test.sh --filter ScriptContractTests
```

Result: 4 tests passed. The scripts execute against temporary fixture apps and evidence. They cover valid hash-linked completion evidence, stale PNG hashes, 899 benchmark samples, `windowCount == 2`, a missing production kernel, and a non-arm64 executable. The capture fixture runs all eleven rows and verifies the generated review manifest.

## Commands and results

```sh
zsh -n scripts/capture-qa.sh scripts/benchmark.sh scripts/verify-app.sh scripts/verify-completion.sh scripts/build-app.sh
./scripts/test.sh --filter ScriptContractTests
./scripts/test.sh
./scripts/build-app.sh
./scripts/verify-app.sh "dist/MicroCube Metal.app"
QA_REVIEWER="Pending human review" QA_REVIEW_STATUS=fail ./scripts/capture-qa.sh "dist/MicroCube Metal.app"
./scripts/benchmark.sh "dist/MicroCube Metal.app"
./scripts/verify-completion.sh
git diff --check
```

- Focused script contracts passed, 4 tests.
- Full release XCTest suite passed, 100 tests.
- `build-app.sh` produced a signed arm64 `dist/MicroCube Metal.app`.
- `verify-app.sh` passed the plist, arm64, code-signature, shader, Appendix B byte, and one-window QA checks.
- `capture-qa.sh` produced the eleven-row manifest and its capture PNG/report files. The run records `fail` pending human visual review.
- The M4 Max benchmark ran three times at each required resolution. Each report contains 900 positive raw samples, nominal thermal states, two passes, all features, and zero command, drawable, and semaphore errors.
- 1280x800 p95 results: 6.0566 ms, 6.4207 ms, 6.2368 ms. Worst: 6.4207 ms, below 8.33 ms.
- 2560x1600 p95 results: 5.7749 ms, 6.3531 ms, 6.3136 ms. Worst: 6.3531 ms, below 16.67 ms.
- `verify-completion.sh` wrote a failing completion report as designed. It blocks release completion because the eight probe JSON files, `xctest.json`, `trace-review.json`, and human-approved visual review do not exist yet.
- `git diff --check` passed.

## Concerns and handoff

Task 10 tooling is complete. Release completion stays blocked until the probe producer supplies its eight passing JSON reports, the release runner records `xctest.json`, a reviewer supplies `trace-review.json` with the trace hash, and a human changes the visual-review row results to `pass` after inspecting captures. The captured benchmark reports prove the numeric M4 Max performance gate for this run.
