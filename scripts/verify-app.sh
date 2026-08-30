#!/bin/zsh

set -u
set -o pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_BUNDLE=${1:-"$PROJECT_DIR/dist/MicroCube Metal.app"}
REPORT_PATH=${2:-"$PROJECT_DIR/dist/evidence/package-verification.json"}
failures=()

fail() {
    failures+=("$1")
}

write_report() {
    local report_status=$1 failure=$2 process_count=$3 window_count=$4
    mkdir -p "${REPORT_PATH:h}"
    jq -n --arg app "$APP_BUNDLE" --arg status "$report_status" --arg failure "$failure" --argjson processCount "$process_count" --argjson windowCount "$window_count" \
        '{app: $app, status: $status, failure: (if $failure == "" then null else $failure end), processCount: $processCount, windowCount: $windowCount}' > "$REPORT_PATH"
}

if ! command -v jq >/dev/null 2>&1; then
    print -u2 -- "jq is required to verify the app bundle."
    exit 2
fi

executable="$APP_BUNDLE/Contents/MacOS/MicroCubeMetal"
plist="$APP_BUNDLE/Contents/Info.plist"
if [[ ! -d "$APP_BUNDLE" ]]; then
    fail "App bundle does not exist."
elif [[ ! -f "$plist" ]]; then
    fail "Info.plist is missing."
else
    [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null) == "com.vseplet.microcube.metal" ]] || fail "Bundle identifier is invalid."
    [[ $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null) == "14.0" ]] || fail "Minimum system version is invalid."
    [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null) == "MicroCubeMetal" ]] || fail "Bundle executable is invalid."
fi
if [[ ! -x "$executable" ]]; then
    fail "MicroCubeMetal executable is missing."
elif ! lipo -archs "$executable" 2>/dev/null | tr ' ' '\n' | grep -qx 'arm64'; then
    fail "MicroCubeMetal is not an arm64 executable."
fi
codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1 || fail "codesign verification failed."

for source in SceneTypes.metal HybridTraversal.metal MicroCube.metal; do
    find "$APP_BUNDLE/Contents/Resources" -type f -name "$source" -print -quit 2>/dev/null | grep -q . || fail "$source is missing from bundle resources."
done
copy_path=$(find "$APP_BUNDLE/Contents/Resources" -type f -name WhyRays.en.txt -print -quit 2>/dev/null)
[[ -n "$copy_path" ]] || fail "WhyRays.en.txt is missing from bundle resources."
for kernel in generateTerrain reduceOccupancy buildMixedOccupancy reduceMixedOccupancy clearVolumeLighting injectVolumeLighting raycastHybrid; do
    find "$APP_BUNDLE/Contents/Resources" -type f -name '*.metal' -exec grep -l "kernel void $kernel" {} + 2>/dev/null | grep -q . || fail "Production kernel $kernel is missing."
done
expected=$(mktemp "${TMPDIR:-/tmp}/microcube-appendix.XXXXXX")
qa_report=$(mktemp "${TMPDIR:-/tmp}/microcube-package-qa.XXXXXX")
launch_pid=""
cleanup() {
    local stop_pid grace_count=0 grace_polls
    if [[ -n "$launch_pid" ]]; then
        stop_pid=$launch_pid
        kill "$stop_pid" >/dev/null 2>&1
        grace_polls=${MICROCUBE_VERIFY_TERM_GRACE_POLLS:-100}
        [[ "$grace_polls" == <-> && "$grace_polls" -gt 0 ]] || grace_polls=100
        while kill -0 "$stop_pid" >/dev/null 2>&1 && (( grace_count < grace_polls )); do
            (( grace_count++ ))
            sleep 0.01
        done
        kill -KILL "$stop_pid" >/dev/null 2>&1
        wait "$stop_pid" >/dev/null 2>&1
    fi
    rm -f "$expected" "$qa_report"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
awk '
    function emit(    first,last,idx) {
        first = 1
        last = count
        while (first <= last && lines[first] == "") first++
        while (last >= first && lines[last] == "") last--
        if (first > last) return
        if (emitted++) print ""
        for (idx = first; idx <= last; idx++) print lines[idx]
    }
    /^## Appendix B: English explainer copy$/ { appendix = 1; next }
    appendix && /^## / { appendix = 0 }
    appendix && /^### Passage [123]$/ {
        emit()
        delete lines
        count = 0
        passage = 1
        next
    }
    appendix && passage && /^>/ {
        line = $0
        sub(/^> ?/, "", line)
        lines[++count] = line
    }
    END { emit() }
' "$PROJECT_DIR/docs/superpowers/specs/2026-08-30-microcube-visual-proof-design.md" > "$expected"
[[ -n "$copy_path" && -f "$copy_path" ]] && cmp -s "$expected" "$copy_path" || fail "WhyRays.en.txt does not match Appendix B."

process_count=0
window_count=0
if (( ${#failures[@]} == 0 )); then
    baseline_pids=(${(f)"$(pgrep -x MicroCubeMetal 2>/dev/null)"})
    if (( ${#baseline_pids[@]} > 0 )); then
        fail "Another MicroCubeMetal process is already running."
    else
        "$executable" --qa-scene hero --qa-features all --qa-time 0 --qa-step 0.008333333333333333 --qa-camera reset --qa-window-points 1280x800 --qa-drawable 1280x800 --qa-scale 1 --qa-view final --qa-frames 120 --qa-capture-scope drawable --qa-report "$qa_report" >/dev/null 2>&1 &
        launch_pid=$!
        launch_status=0
        process_observed=0
        process_violation=0
        poll_count=0
        max_polls=${MICROCUBE_VERIFY_MAX_POLLS:-3000}
        [[ "$max_polls" == <-> && "$max_polls" -gt 0 ]] || max_polls=3000
        while kill -0 "$launch_pid" >/dev/null 2>&1 && (( poll_count < max_polls )); do
            observed_pids=(${(f)"$(pgrep -x MicroCubeMetal 2>/dev/null)"})
            observed_count=${#observed_pids[@]}
            if (( observed_count > 0 )); then
                launch_seen=0
                (( observed_count > process_count )) && process_count=$observed_count
                for pid in "${observed_pids[@]}"; do
                    [[ "$pid" == "$launch_pid" ]] && launch_seen=1
                done
                if (( observed_count == 1 && launch_seen == 1 )); then
                    process_observed=1
                else
                    process_violation=1
                fi
            fi
            (( poll_count++ ))
            sleep 0.01
        done
        if kill -0 "$launch_pid" >/dev/null 2>&1; then
            fail "Packaged QA launch timed out."
            kill "$launch_pid" >/dev/null 2>&1
            grace_count=0
            grace_polls=${MICROCUBE_VERIFY_TERM_GRACE_POLLS:-100}
            [[ "$grace_polls" == <-> && "$grace_polls" -gt 0 ]] || grace_polls=100
            while kill -0 "$launch_pid" >/dev/null 2>&1 && (( grace_count < grace_polls )); do
                (( grace_count++ ))
                sleep 0.01
            done
            kill -KILL "$launch_pid" >/dev/null 2>&1
        fi
        wait "$launch_pid" || launch_status=$?
        launch_pid=""
        surviving_pids=(${(f)"$(pgrep -x MicroCubeMetal 2>/dev/null)"})
        if (( ${#surviving_pids[@]} > 0 )); then
            fail "Packaged QA launch left a surviving application process."
        fi
        (( process_observed == 1 && process_violation == 0 && process_count == 1 )) || fail "Packaged QA launch did not prove one application process."
        if (( launch_status != 0 )) || [[ ! -f "$qa_report" ]]; then
            fail "Packaged QA launch failed."
        else
            window_count=$(jq -r '.windowCount // 0' "$qa_report")
            jq -e '
                .schemaVersion == 1 and .status == "pass" and .failure == null and
                (.device | type == "string" and length > 0) and (.os | type == "string" and length > 0) and
                .scene == "hero" and .fixedTime == 0 and .fixedStep == (1 / 120) and
                .drawablePixels == [1280, 800] and .renderScale == 1 and .windowCount == 1 and
                .productionKernels == ["generateTerrain", "reduceOccupancy", "buildMixedOccupancy", "reduceMixedOccupancy", "clearVolumeLighting", "injectVolumeLighting", "raycastHybrid"] and
                .featureMask == "all" and .passCount == 2 and (.stepCounters | type == "object") and
                (.shadowSampleCounts | type == "object") and (.budgetOverflows | type == "number" and isfinite and . >= 0 and floor == .) and
                .commandErrors == 0 and .droppedDrawables == 0 and .semaphoreTimeouts == 0
            ' "$qa_report" >/dev/null 2>&1 || fail "Packaged QA report does not prove one window and two passes."
        fi
    fi
fi
if (( ${#failures[@]} == 0 )); then
    write_report pass "" "$process_count" "$window_count"
    print -r -- "$REPORT_PATH"
    exit 0
fi
failure=$(IFS=' '; print -r -- "${failures[*]}")
write_report fail "$failure" "$process_count" "$window_count"
print -u2 -- "$failure"
exit 1
