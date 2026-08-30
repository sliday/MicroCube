#!/bin/zsh

set -u
set -o pipefail

SCRIPT_DIR=${0:A:h}
EVIDENCE_DIR=${1:-"$SCRIPT_DIR/../dist/evidence"}
REPORT_PATH=${2:-"$EVIDENCE_DIR/completion.json"}
failures=()

fail() {
    failures+=("$1")
}

hash_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

require_passing_status() {
    local file_path=$1
    [[ -f "$file_path" ]] || { fail "Missing $(basename "$file_path")."; return; }
    jq -e '.status == "pass"' "$file_path" >/dev/null 2>&1 || fail "$(basename "$file_path") does not pass."
}

validate_visual_review() {
    local review_path="$EVIDENCE_DIR/visual-review.json"
    local name capture_path expected actual
    local required_names=(
        "Shadow beauty and mismatch"
        "Mixed primitive ID and steps"
        "Monsters"
        "Optics"
        "Fog blocker"
        "Gaussian"
        "Smoke-cast surface shadow"
        "Fractal normals"
        "Hero final field"
        "Five evidence views"
        "Explainer responsive states"
    )

    require_passing_status "$review_path"
    [[ -f "$review_path" ]] || return
    jq -e '
        (.rows | type == "array") and
        (.rows | length == 11) and
        ([.rows[].name] | unique | length == 11) and
        all(.rows[]; (.status == "pass") and (.reviewer | type == "string" and length > 0) and (.reviewedAt | type == "string" and length > 0) and (.notes | type == "string") and (.captures | type == "array" and length > 0))
    ' "$review_path" >/dev/null 2>&1 || fail "visual-review.json has an invalid review matrix."
    for name in "${required_names[@]}"; do
        jq -e --arg name "$name" '.rows[] | select(.name == $name)' "$review_path" >/dev/null 2>&1 || fail "visual-review.json is missing $name."
    done
    while IFS=$'\t' read -r capture_path expected; do
        [[ -n "$capture_path" && "$capture_path" != /* ]] || { fail "visual-review.json contains an invalid capture path."; continue; }
        [[ -f "$EVIDENCE_DIR/$capture_path" ]] || { fail "Missing reviewed capture $capture_path."; continue; }
        actual=$(hash_file "$EVIDENCE_DIR/$capture_path")
        [[ "$actual" == "$expected" ]] || fail "Stale reviewed capture $capture_path."
    done < <(jq -r '.rows[].captures[] | [.path, .sha256] | @tsv' "$review_path" 2>/dev/null)
}

validate_benchmark() {
    local size=$1 threshold=$2 run report_path
    local reports=()
    for run in 1 2 3; do
        report_path="$EVIDENCE_DIR/benchmark-${size}-run${run}.json"
        reports+=("$report_path")
        require_passing_status "$report_path"
        [[ -f "$report_path" ]] || continue
        jq -e --argjson pixels "[${size%x*}, ${size#*x}]" '
            .schemaVersion == 1 and
            .device == "Apple M4 Max" and
            .thermalStateBefore == "nominal" and
            .thermalStateAfter == "nominal" and
            .drawablePixels == $pixels and
            .renderScale == 1 and
            .fixedStep == (1 / 120) and
            .warmupFrames == 180 and
            .measuredFrames == 900 and
            .percentileMethod == "nearest-rank" and
            (.gpuMilliseconds | type == "array" and length == 900 and all(.[]; type == "number" and isfinite and . > 0)) and
            ((.gpuMilliseconds | sort | .[854]) as $p95 | $p95 == .p95GPUms) and
            .commandErrors == 0 and .droppedDrawables == 0 and .semaphoreTimeouts == 0 and
            .passCount == 2 and .featureMask == "all"
        ' "$report_path" >/dev/null 2>&1 || fail "$(basename "$report_path") is not a valid M4 Max benchmark report."
    done
    jq -s --argjson threshold "$threshold" 'length == 3 and (map(.p95GPUms) | max <= $threshold)' "${reports[@]}" >/dev/null 2>&1 || fail "${size} benchmark p95 exceeds ${threshold} ms."
}

validate_trace_review() {
    local review_path="$EVIDENCE_DIR/trace-review.json" trace_path expected actual
    require_passing_status "$review_path"
    [[ -f "$review_path" ]] || return
    jq -e '
        .steadyStatePassCount == 2 and
        .perFrameCPUTextureUploads == 0 and
        .steadyStateWaitUntilCompleted == 0 and
        (.tracePath | type == "string" and length > 0) and
        (.traceSHA256 | type == "string" and length == 64)
    ' "$review_path" >/dev/null 2>&1 || { fail "trace-review.json is invalid."; return; }
    trace_path=$(jq -r '.tracePath' "$review_path")
    expected=$(jq -r '.traceSHA256' "$review_path")
    [[ "$trace_path" != /* && -f "$EVIDENCE_DIR/$trace_path" ]] || { fail "Trace artifact is missing."; return; }
    actual=$(hash_file "$EVIDENCE_DIR/$trace_path")
    [[ "$actual" == "$expected" ]] || fail "Trace hash does not match trace-review.json."
}

mkdir -p "${REPORT_PATH:h}"
if ! command -v jq >/dev/null 2>&1; then
    print -u2 -- "jq is required to verify release evidence."
    exit 2
fi

for probe in shadow mixed budgets sdf optics volume motion ui; do
    require_passing_status "$EVIDENCE_DIR/$probe.json"
done
require_passing_status "$EVIDENCE_DIR/xctest.json"
require_passing_status "$EVIDENCE_DIR/package-verification.json"
if [[ -f "$EVIDENCE_DIR/package-verification.json" ]]; then
    jq -e '.windowCount == 1' "$EVIDENCE_DIR/package-verification.json" >/dev/null 2>&1 || fail "package-verification.json does not prove one window."
fi
validate_visual_review
validate_benchmark "1280x800" 8.33
validate_benchmark "2560x1600" 16.67
validate_trace_review

input_paths=()
while IFS= read -r file_path; do
    [[ "$file_path" != "$REPORT_PATH" ]] && input_paths+=("$file_path")
done < <(find "$EVIDENCE_DIR" -type f -print | LC_ALL=C sort)
inputs='{}'
for file_path in "${input_paths[@]}"; do
    relative=${file_path#$EVIDENCE_DIR/}
    inputs=$(jq --arg path "$relative" --arg hash "$(hash_file "$file_path")" '. + {($path): $hash}' <<<"$inputs")
done
if (( ${#failures[@]} == 0 )); then
    jq -n --argjson inputs "$inputs" '{status: "pass", failure: null, inputs: $inputs}' > "$REPORT_PATH"
    print -r -- "$REPORT_PATH"
    exit 0
fi
failure=$(IFS=' '; print -r -- "${failures[*]}")
jq -n --arg failure "$failure" --argjson inputs "$inputs" '{status: "fail", failure: $failure, inputs: $inputs}' > "$REPORT_PATH"
print -u2 -- "$failure"
exit 1
