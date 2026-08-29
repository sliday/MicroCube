#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}

if ! xcrun --find xctest >/dev/null 2>&1; then
    if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        print -u2 -- "XCTest is unavailable. Install Xcode or set DEVELOPER_DIR to an Xcode developer directory."
        exit 1
    fi
fi

exec swift test --package-path "$PROJECT_DIR" -c release "$@"
