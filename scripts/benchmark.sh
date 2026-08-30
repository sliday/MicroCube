#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_BUNDLE=${1:-"$PROJECT_DIR/dist/MicroCube Metal.app"}
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/MicroCubeMetal"
EVIDENCE_DIR="$PROJECT_DIR/dist/evidence"
device=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)

[[ "$device" == "Apple M4 Max" ]] || { print -u2 -- "Benchmark requires Apple M4 Max; found ${device:-unknown}."; exit 1; }
[[ -x "$EXECUTABLE" ]] || { print -u2 -- "Packaged executable is missing: $EXECUTABLE"; exit 1; }
command -v jq >/dev/null 2>&1 || { print -u2 -- "jq is required to validate benchmark reports."; exit 2; }
mkdir -p "$EVIDENCE_DIR"

validate_report() {
    local report_path=$1 size=$2
    jq -e --argjson pixels "[${size%x*}, ${size#*x}]" '
        .schemaVersion == 1 and .status == "pass" and .device == "Apple M4 Max" and
        .thermalStateBefore == "nominal" and .thermalStateAfter == "nominal" and
        .drawablePixels == $pixels and .renderScale == 1 and .fixedStep == (1 / 120) and
        .warmupFrames == 180 and .measuredFrames == 900 and .percentileMethod == "nearest-rank" and
        (.gpuMilliseconds | type == "array" and length == 900 and all(.[]; type == "number" and isfinite and . > 0)) and
        ((.gpuMilliseconds | sort | .[854]) as $p95 | $p95 == .p95GPUms) and
        .commandErrors == 0 and .droppedDrawables == 0 and .semaphoreTimeouts == 0 and
        .passCount == 2 and .featureMask == "all"
    ' "$report_path" >/dev/null
}

for size in 1280x800 2560x1600; do
    threshold=8.33
    [[ "$size" == "2560x1600" ]] && threshold=16.67
    reports=()
    for run in 1 2 3; do
        report="$EVIDENCE_DIR/benchmark-${size}-run${run}.json"
        "$EXECUTABLE" --qa-scene hero --qa-features all --qa-time 0 --qa-step 0.008333333333333333 --qa-camera reset --qa-window-points "$size" --qa-drawable "$size" --qa-scale 1 --qa-view final --benchmark --benchmark-warmup 180 --benchmark-samples 900 --qa-report "$report"
        validate_report "$report" "$size"
        reports+=("$report")
    done
    jq -s --argjson threshold "$threshold" 'map(.p95GPUms) | max <= $threshold' "${reports[@]}" >/dev/null || {
        print -u2 -- "Worst ${size} p95 exceeds ${threshold} ms."
        exit 1
    }
done
