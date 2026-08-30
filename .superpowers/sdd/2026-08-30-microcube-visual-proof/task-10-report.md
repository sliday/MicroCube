# Task 10 Report: Release Tooling

## Scope

Hardened the capture, benchmark, package, and completion gates around the deterministic QA report contract. The scripts now verify the exact 23-capture matrix, report and artifact hashes, evidence-path containment, seven production kernels, arm64 signing, one launched process, one window, bounded process cleanup, and finite nonnegative integer overflow counters.

## Interface checks before test edits

- `QAMode` accepts the capture and benchmark arguments used by the scripts. Benchmark defaults remain 180 warmup frames and 900 measured frames.
- `QAFrameReport` schema version 1 supplies the required device, OS, scene, clock, drawable, kernel, pass, counter, error, thermal, sample, and p95 fields.
- The production kernel list contains `generateTerrain`, `reduceOccupancy`, `buildMixedOccupancy`, `reduceMixedOccupancy`, `clearVolumeLighting`, `injectVolumeLighting`, and `raycastHybrid`.
- `budgetOverflows` is a `UInt32` frame counter. Frame reports may contain a nonzero count; the dedicated `budgets` probe remains the zero-overflow release authority.

## TDD record

Added counter regressions for `-1` and `1.5` across capture, benchmark, package, and completion verification before changing the scripts.

RED command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter NegativeAndFractionalBudgetOverflow
```

Result: 4 tests failed with 12 assertions because all four script paths accepted both invalid counters.

GREEN command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter NegativeAndFractionalBudgetOverflow
```

Result: 4 tests passed after each jq gate required `type == "number" and isfinite and . >= 0 and floor == .`.

## Commands and results

```sh
zsh -n scripts/build-app.sh scripts/capture-qa.sh scripts/benchmark.sh scripts/capture-gpu.sh scripts/verify-app.sh scripts/verify-completion.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ScriptContractTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-app.sh
./scripts/verify-app.sh "dist/MicroCube Metal.app" /tmp/microcube-live-report.rtqv47
git diff --check
```

- Shell syntax and `git diff --check` passed.
- All 35 release-script contract tests passed.
- All 131 tests passed with zero failures.
- `build-app.sh` produced a signed arm64 `dist/MicroCube Metal.app`.
- Live package verification passed with `status: pass`, `failure: null`, `processCount: 1`, and `windowCount: 1`.
- Zombie diagnostics exposed an AppKit close-time over-release in the multi-window UI tests. `window.isReleasedWhenClosed = false` now matches `AppDelegate`'s strong window ownership; all 24 UI tests and the full suite pass.
- Package, evidence, and test reviewers reported no Critical, Important, or Minor findings.

## Handoff

Task 10 release tooling is complete. `/tmp/microcube-live-report.rtqv47` retains the latest package-verification report. Capture and benchmark frame counters remain observational; `budgets.json` owns the zero-overflow decision.
