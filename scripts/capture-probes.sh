#!/bin/zsh

set -u
set -o pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
EVIDENCE_DIR=${1:-"$PROJECT_DIR/dist/evidence"}
TEST_RUNNER=${MICROCUBE_TEST_RUNNER:-"$SCRIPT_DIR/test.sh"}
TEST_LOG=$(mktemp "${TMPDIR:-/tmp}/microcube-xctest.XXXXXX")
trap 'rm -f "$TEST_LOG"' EXIT

command -v jq >/dev/null 2>&1 || { print -u2 -- "jq is required to record probe evidence."; exit 2; }
mkdir -p "$EVIDENCE_DIR"
for probe in shadow mixed budgets sdf optics volume motion ui; do
    rm -f "$EVIDENCE_DIR/$probe.json"
done
rm -f "$EVIDENCE_DIR/xctest.json"
MICROCUBE_EVIDENCE_DIR="$EVIDENCE_DIR" "$TEST_RUNNER" > "$TEST_LOG" 2>&1
test_exit=$?
cat "$TEST_LOG"
if (( test_exit == 0 )); then
    jq -n '{schemaVersion: 1, status: "pass", failure: null}' > "$EVIDENCE_DIR/xctest.json"
else
    jq -n --arg failure "XCTest exited with code $test_exit." '{schemaVersion: 1, status: "fail", failure: $failure}' > "$EVIDENCE_DIR/xctest.json"
fi
collector_exit=$test_exit
if (( test_exit == 0 )); then
    for probe in shadow mixed budgets sdf optics volume motion ui; do
        if [[ ! -f "$EVIDENCE_DIR/$probe.json" ]]; then
            print -u2 -- "Missing current probe evidence: $probe.json"
            collector_exit=1
        elif ! jq -s -e --arg probe "$probe" -f "$SCRIPT_DIR/validate-probe.jq" "$EVIDENCE_DIR/$probe.json" >/dev/null 2>&1; then
            print -u2 -- "Invalid current probe evidence: $probe.json"
            collector_exit=1
        fi
    done
fi
exit "$collector_exit"
