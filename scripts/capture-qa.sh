#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_BUNDLE=${1:-"$PROJECT_DIR/dist/MicroCube Metal.app"}
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/MicroCubeMetal"
EVIDENCE_DIR=${MICROCUBE_EVIDENCE_DIR:-"$PROJECT_DIR/dist/evidence"}
CAPTURE_DIR="$EVIDENCE_DIR/captures"
ROW_DIR=$(mktemp -d "${TMPDIR:-/tmp}/microcube-captures.XXXXXX")
REVIEWER=${QA_REVIEWER:-unreviewed}
REVIEWED_AT=${QA_REVIEWED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
REVIEW_STATUS=${QA_REVIEW_STATUS:-fail}
REVIEW_NOTES=${QA_REVIEW_NOTES:-"Capture generated. A human reviewer must approve this row."}
trap 'rm -rf "$ROW_DIR"' EXIT

[[ -x "$EXECUTABLE" ]] || { print -u2 -- "Packaged executable is missing: $EXECUTABLE"; exit 1; }
command -v jq >/dev/null 2>&1 || { print -u2 -- "jq is required to create the visual review."; exit 2; }
[[ "$REVIEW_STATUS" == pass || "$REVIEW_STATUS" == fail ]] || { print -u2 -- "QA_REVIEW_STATUS must be pass or fail."; exit 2; }
mkdir -p "$CAPTURE_DIR"

capture() {
    local row=$1 scene=$2 features=$3 time=$4 view=$5 scope=$6 window=$7 label=$8
    local stem=$(print -r -- "$row" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-$//')${label:+-$label}
    local png="$CAPTURE_DIR/$stem.png"
    local report="$CAPTURE_DIR/$stem.json"
    "$EXECUTABLE" --qa-scene "$scene" --qa-features "$features" --qa-time "$time" --qa-step 0.008333333333333333 --qa-camera reset --qa-window-points "$window" --qa-drawable 1280x800 --qa-scale 1 --qa-view "$view" --qa-frames 1 --qa-capture-scope "$scope" --qa-capture "$png" --qa-report "$report"
    jq -e --arg png "$png" '
        .schemaVersion == 1 and .status == "pass" and .failure == null and .windowCount == 1 and
        .passCount == 2 and .commandErrors == 0 and .droppedDrawables == 0 and .semaphoreTimeouts == 0 and
        .capturePath == $png
    ' "$report" >/dev/null
    [[ -s "$png" ]] || { print -u2 -- "Capture is empty: $png"; exit 1; }
    jq -n --arg path "captures/${png:t}" --arg sha256 "$(shasum -a 256 "$png" | awk '{print $1}')" '{path: $path, sha256: $sha256}' >> "$ROW_DIR/$row.jsonl"
}

capture "Shadow beauty and mismatch" shadow-fixture shadows 0 final drawable 1280x800 beauty
capture "Shadow beauty and mismatch" shadow-fixture shadows 0 shadow-mismatch drawable 1280x800 mismatch
capture "Mixed primitive ID and steps" mixed-fixture all 0 primitive-id drawable 1280x800 primitive-id
capture "Mixed primitive ID and steps" mixed-fixture all 0 steps drawable 1280x800 steps
capture "Monsters" hero sdf,lights,gaussian,shadows 0 final drawable 1280x800 t0
capture "Monsters" hero sdf,lights,gaussian,shadows 1 final drawable 1280x800 t1
capture "Optics" optics-fixture optics 0 final drawable 1280x800 optics
capture "Optics" optics-fixture none 0 final drawable 1280x800 none
capture "Fog blocker" fog-clear gaussian,lights,shadows 0 final drawable 1280x800 clear
capture "Fog blocker" fog-blocked gaussian,lights,shadows 0 final drawable 1280x800 blocked
capture "Gaussian" gaussian-fixture gaussian 0 final drawable 1280x800 gaussian
capture "Gaussian" gaussian-fixture none 0 final drawable 1280x800 none
capture "Smoke-cast surface shadow" gaussian-fixture gaussian,lights,shadows 0 final drawable 1280x800 smoke
capture "Smoke-cast surface shadow" gaussian-fixture lights,shadows 0 final drawable 1280x800 clear
capture "Fractal normals" fractal-fixture sdf 0 normals drawable 1280x800 normals
capture "Hero final field" hero all 0 final drawable 1280x800 final
for view in final grid pyramid steps cost; do
    capture "Five evidence views" hero all 0 "$view" drawable 1280x800 "$view"
done
capture "Explainer responsive states" hero all 0 final window 1280x800 expanded
capture "Explainer responsive states" hero all 0 final window 1099x800 collapsed

rows=()
for row in "Shadow beauty and mismatch" "Mixed primitive ID and steps" Monsters Optics "Fog blocker" Gaussian "Smoke-cast surface shadow" "Fractal normals" "Hero final field" "Five evidence views" "Explainer responsive states"; do
    captures=$(jq -s '.' "$ROW_DIR/$row.jsonl")
    rows+=("$(jq -n --arg name "$row" --arg reviewer "$REVIEWER" --arg reviewedAt "$REVIEWED_AT" --arg status "$REVIEW_STATUS" --arg notes "$REVIEW_NOTES" --argjson captures "$captures" '{name: $name, captures: $captures, reviewer: $reviewer, reviewedAt: $reviewedAt, status: $status, notes: $notes}')")
done
jq -n --arg status "$REVIEW_STATUS" --argjson rows "[$(IFS=,; print -r -- "${rows[*]}")]" '{status: $status, rows: $rows}' > "$EVIDENCE_DIR/visual-review.json"
print -r -- "$EVIDENCE_DIR/visual-review.json"
