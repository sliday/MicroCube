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
    local report_status=$1 failure=$2 window_count=$3
    mkdir -p "${REPORT_PATH:h}"
    jq -n --arg app "$APP_BUNDLE" --arg status "$report_status" --arg failure "$failure" --argjson windowCount "$window_count" \
        '{app: $app, status: $status, failure: (if $failure == "" then null else $failure end), windowCount: $windowCount}' > "$REPORT_PATH"
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
for kernel in generateTerrain reduceOccupancy buildMixedOccupancy reduceMixedOccupancy injectVolumeLighting raycastHybrid; do
    find "$APP_BUNDLE/Contents/Resources" -type f -name '*.metal' -exec grep -l "kernel void $kernel" {} + 2>/dev/null | grep -q . || fail "Production kernel $kernel is missing."
done
expected=$(mktemp "${TMPDIR:-/tmp}/microcube-appendix.XXXXXX")
trap 'rm -f "$expected"' EXIT
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

window_count=0
qa_report=$(mktemp "${TMPDIR:-/tmp}/microcube-package-qa.XXXXXX")
if (( ${#failures[@]} == 0 )); then
    "$executable" --qa-scene hero --qa-features all --qa-time 0 --qa-step 0.008333333333333333 --qa-camera reset --qa-window-points 1280x800 --qa-drawable 1280x800 --qa-scale 1 --qa-view final --qa-frames 1 --qa-capture-scope drawable --qa-report "$qa_report" >/dev/null 2>&1
    launch_status=$?
    if (( launch_status != 0 )) || [[ ! -f "$qa_report" ]]; then
        fail "Packaged QA launch failed."
    else
        window_count=$(jq -r '.windowCount // 0' "$qa_report")
        jq -e '.status == "pass" and .windowCount == 1 and .passCount == 2 and (.productionKernels | type == "array")' "$qa_report" >/dev/null 2>&1 || fail "Packaged QA report does not prove one window and two passes."
    fi
fi
rm -f "$qa_report"
if (( ${#failures[@]} == 0 )); then
    write_report pass "" "$window_count"
    print -r -- "$REPORT_PATH"
    exit 0
fi
failure=$(IFS=' '; print -r -- "${failures[*]}")
write_report fail "$failure" "$window_count"
print -u2 -- "$failure"
exit 1
