#!/bin/zsh

set -u
set -o pipefail

SCRIPT_DIR=${0:A:h}
EVIDENCE_DIR=${1:-"$SCRIPT_DIR/../dist/evidence"}
EVIDENCE_DIR=${EVIDENCE_DIR:a}
REPORT_PATH=${2:-"$EVIDENCE_DIR/completion.json"}
failures=()

fail() {
    failures+=("$1")
}

hash_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

is_safe_evidence_path() {
    local relative_path=$1 root_path candidate_path resolved_path
    [[ -n "$relative_path" && "$relative_path" != /* ]] || return 1
    root_path=${EVIDENCE_DIR:A}
    candidate_path="$EVIDENCE_DIR/$relative_path"
    resolved_path=${candidate_path:A}
    [[ "$resolved_path" == "$root_path"/* ]]
}

require_passing_status() {
    local file_path=$1
    [[ -f "$file_path" ]] || { fail "Missing $(basename "$file_path")."; return; }
    jq -e '.status == "pass"' "$file_path" >/dev/null 2>&1 || fail "$(basename "$file_path") does not pass."
}

validate_probe() {
    local probe=$1 file_path="$EVIDENCE_DIR/$1.json"
    [[ -f "$file_path" ]] || { fail "Missing $probe.json."; return; }
    jq -s -e --arg probe "$probe" -f "$SCRIPT_DIR/validate-probe.jq" "$file_path" >/dev/null 2>&1 ||
        fail "$probe.json is not valid probe evidence."
}

validate_visual_review() {
    local review_path="$EVIDENCE_DIR/visual-review.json"
    local name capture_path expected actual report_path report_expected scene feature_mask fixed_time capture_file report_file
    local capture_spec view capture_scope window
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
    local required_captures=(
        "Shadow beauty and mismatch|captures/shadow-beauty-and-mismatch-beauty.png|shadow-fixture|shadows|0|final|drawable|1280x800"
        "Shadow beauty and mismatch|captures/shadow-beauty-and-mismatch-mismatch.png|shadow-fixture|shadows|0|shadow-mismatch|drawable|1280x800"
        "Mixed primitive ID and steps|captures/mixed-primitive-id-and-steps-primitive-id.png|mixed-fixture|all|0|primitive-id|drawable|1280x800"
        "Mixed primitive ID and steps|captures/mixed-primitive-id-and-steps-steps.png|mixed-fixture|all|0|steps|drawable|1280x800"
        "Monsters|captures/monsters-t0.png|hero|sdf,lights,gaussian,shadows|0|final|drawable|1280x800"
        "Monsters|captures/monsters-t1.png|hero|sdf,lights,gaussian,shadows|1|final|drawable|1280x800"
        "Optics|captures/optics-optics.png|optics-fixture|optics|0|final|drawable|1280x800"
        "Optics|captures/optics-none.png|optics-fixture|none|0|final|drawable|1280x800"
        "Fog blocker|captures/fog-blocker-clear.png|fog-clear|gaussian,lights,shadows|0|final|drawable|1280x800"
        "Fog blocker|captures/fog-blocker-blocked.png|fog-blocked|gaussian,lights,shadows|0|final|drawable|1280x800"
        "Gaussian|captures/gaussian-gaussian.png|gaussian-fixture|gaussian|0|final|drawable|1280x800"
        "Gaussian|captures/gaussian-none.png|gaussian-fixture|none|0|final|drawable|1280x800"
        "Smoke-cast surface shadow|captures/smoke-cast-surface-shadow-smoke.png|gaussian-fixture|gaussian,lights,shadows|0|final|drawable|1280x800"
        "Smoke-cast surface shadow|captures/smoke-cast-surface-shadow-clear.png|gaussian-fixture|lights,shadows|0|final|drawable|1280x800"
        "Fractal normals|captures/fractal-normals-normals.png|fractal-fixture|sdf|0|normals|drawable|1280x800"
        "Hero final field|captures/hero-final-field-final.png|hero|all|0|final|drawable|1280x800"
        "Five evidence views|captures/five-evidence-views-final.png|hero|all|0|final|drawable|1280x800"
        "Five evidence views|captures/five-evidence-views-grid.png|hero|all|0|grid|drawable|1280x800"
        "Five evidence views|captures/five-evidence-views-pyramid.png|hero|all|0|pyramid|drawable|1280x800"
        "Five evidence views|captures/five-evidence-views-steps.png|hero|all|0|steps|drawable|1280x800"
        "Five evidence views|captures/five-evidence-views-cost.png|hero|all|0|cost|drawable|1280x800"
        "Explainer responsive states|captures/explainer-responsive-states-expanded.png|hero|all|0|final|window|1280x800"
        "Explainer responsive states|captures/explainer-responsive-states-collapsed.png|hero|all|0|final|window|1099x800"
    )

    require_passing_status "$review_path"
    [[ -f "$review_path" ]] || return
    jq -e '
        (.rows | type == "array") and
        (.rows | length == 11) and
        ([.rows[].name] | unique | length == 11) and
        ([.rows[].captures[]] | length == 23) and
        ([.rows[].captures[].path] | unique | length == 23) and
        ([.rows[].captures[].reportPath] | unique | length == 23) and
        all(.rows[]; (.status == "pass") and (.reviewer as $reviewer | ($reviewer | type == "string" and test("\\S")) and (($reviewer | gsub("\\s"; "") | ascii_downcase) != "unreviewed")) and (.reviewedAt as $reviewedAt | ($reviewedAt | type == "string") and ($reviewedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and ((try ($reviewedAt | fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) catch "") == $reviewedAt)) and (.notes | type == "string") and (.captures | type == "array" and length > 0)) and
        all(.rows[].captures[];
            (.path | type == "string" and length > 0) and (.sha256 | type == "string" and length == 64) and
            (.reportPath == (.path | sub("\\.png$"; ".json"))) and (.reportSHA256 | type == "string" and length == 64) and
            (.scene | type == "string" and length > 0) and (.featureMask | type == "string" and length > 0) and
            (.fixedTime | type == "number") and (.view | type == "string" and length > 0) and
            (.captureScope == "drawable" or .captureScope == "window") and
            (.windowPoints | type == "array" and length == 2) and .drawablePixels == [1280, 800])
    ' "$review_path" >/dev/null 2>&1 || fail "visual-review.json has an invalid review matrix."
    for name in "${required_names[@]}"; do
        jq -e --arg name "$name" '.rows[] | select(.name == $name)' "$review_path" >/dev/null 2>&1 || fail "visual-review.json is missing $name."
    done
    for capture_spec in "${required_captures[@]}"; do
        IFS='|' read -r name capture_path scene feature_mask fixed_time view capture_scope window <<< "$capture_spec"
        jq -e --arg name "$name" --arg path "$capture_path" --arg scene "$scene" --arg featureMask "$feature_mask" \
            --argjson fixedTime "$fixed_time" --arg view "$view" --arg captureScope "$capture_scope" \
            --argjson windowPoints "[${window%x*}, ${window#*x}]" '
            [.rows[] | select(.name == $name) | .captures[] | select(
                .path == $path and .reportPath == ($path | sub("\\.png$"; ".json")) and .scene == $scene and .featureMask == $featureMask and .fixedTime == $fixedTime and
                .view == $view and .captureScope == $captureScope and .windowPoints == $windowPoints and
                .drawablePixels == [1280, 800]
            )] | length == 1
        ' "$review_path" >/dev/null 2>&1 || fail "visual-review.json capture matrix does not match $capture_path."
    done
    while IFS=$'\t' read -r capture_path expected report_path report_expected scene feature_mask fixed_time; do
        is_safe_evidence_path "$capture_path" || { fail "visual-review.json contains an invalid capture path."; continue; }
        is_safe_evidence_path "$report_path" || { fail "visual-review.json contains an invalid capture report path."; continue; }
        capture_file="$EVIDENCE_DIR/$capture_path"
        report_file="$EVIDENCE_DIR/$report_path"
        [[ -f "$capture_file" ]] || { fail "Missing reviewed capture $capture_path."; continue; }
        [[ -f "$report_file" ]] || { fail "Missing capture report $report_path."; continue; }
        actual=$(hash_file "$capture_file")
        [[ "$actual" == "$expected" ]] || fail "Stale reviewed capture $capture_path."
        actual=$(hash_file "$report_file")
        [[ "$actual" == "$report_expected" ]] || fail "Stale capture report $report_path."
        jq -e --arg capturePath "$capture_file" --arg scene "$scene" --arg featureMask "$feature_mask" --argjson fixedTime "$fixed_time" '
            .schemaVersion == 1 and .status == "pass" and .failure == null and
            (.device | type == "string" and length > 0) and (.os | type == "string" and length > 0) and
            .scene == $scene and .fixedTime == $fixedTime and .fixedStep == (1 / 120) and .drawablePixels == [1280, 800] and .renderScale == 1 and
            .windowCount == 1 and .productionKernels == ["generateTerrain", "reduceOccupancy", "buildMixedOccupancy", "reduceMixedOccupancy", "clearVolumeLighting", "injectVolumeLighting", "raycastHybrid"] and
            ((.featureMask | split(",") | sort) == ($featureMask | split(",") | sort)) and
            .passCount == 2 and (.stepCounters | type == "object") and (.shadowSampleCounts | type == "object") and
            (.budgetOverflows | type == "number" and isfinite and . >= 0 and floor == .) and .commandErrors == 0 and .droppedDrawables == 0 and
            .semaphoreTimeouts == 0 and .capturePath == $capturePath
        ' "$report_file" >/dev/null 2>&1 || fail "$report_path does not match its reviewed capture state."
    done < <(jq -r '.rows[].captures[] | [.path, .sha256, .reportPath, .reportSHA256, .scene, .featureMask, .fixedTime] | @tsv' "$review_path" 2>/dev/null)
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
            .schemaVersion == 1 and .failure == null and
            .device == "Apple M4 Max" and
            (.os | type == "string" and length > 0) and
            .scene == "hero" and .fixedTime == 0 and
            .thermalStateBefore == "nominal" and
            .thermalStateAfter == "nominal" and
            .drawablePixels == $pixels and
            .renderScale == 1 and
            .windowCount == 1 and
            .productionKernels == ["generateTerrain", "reduceOccupancy", "buildMixedOccupancy", "reduceMixedOccupancy", "clearVolumeLighting", "injectVolumeLighting", "raycastHybrid"] and
            .fixedStep == (1 / 120) and
            .warmupFrames == 180 and
            .measuredFrames == 900 and
            .percentileMethod == "nearest-rank" and
            (.gpuMilliseconds | type == "array" and length == 900 and all(.[]; type == "number" and isfinite and . > 0)) and
            ((.gpuMilliseconds | sort | .[854]) as $p95 | $p95 == .p95GPUms) and
            .commandErrors == 0 and .droppedDrawables == 0 and .semaphoreTimeouts == 0 and
            .passCount == 2 and .featureMask == "all" and (.budgetOverflows | type == "number" and isfinite and . >= 0 and floor == .)
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
        (.reviewer as $reviewer | ($reviewer | type == "string" and test("\\S")) and (($reviewer | gsub("\\s"; "") | ascii_downcase) != "unreviewed")) and
        (.reviewedAt as $reviewedAt | ($reviewedAt | type == "string") and ($reviewedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and ((try ($reviewedAt | fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) catch "") == $reviewedAt)) and
        (.tracePath | type == "string" and length > 0) and
        (.traceSHA256 | type == "string" and length == 64)
    ' "$review_path" >/dev/null 2>&1 || { fail "trace-review.json is invalid."; return; }
    trace_path=$(jq -r '.tracePath' "$review_path")
    expected=$(jq -r '.traceSHA256' "$review_path")
    is_safe_evidence_path "$trace_path" && [[ -f "$EVIDENCE_DIR/$trace_path" ]] || { fail "Trace artifact is missing."; return; }
    actual=$(hash_file "$EVIDENCE_DIR/$trace_path")
    [[ "$actual" == "$expected" ]] || fail "Trace hash does not match trace-review.json."
}

mkdir -p "${REPORT_PATH:h}"
if ! command -v jq >/dev/null 2>&1; then
    print -u2 -- "jq is required to verify release evidence."
    exit 2
fi

for probe in shadow mixed budgets sdf optics volume motion ui; do
    validate_probe "$probe"
done
require_passing_status "$EVIDENCE_DIR/xctest.json"
require_passing_status "$EVIDENCE_DIR/package-verification.json"
if [[ -f "$EVIDENCE_DIR/package-verification.json" ]]; then
    jq -e '.failure == null and .processCount == 1 and .windowCount == 1' "$EVIDENCE_DIR/package-verification.json" >/dev/null 2>&1 || fail "package-verification.json does not prove one process and one window."
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
