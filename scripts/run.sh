#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
APP_BUNDLE=$("$SCRIPT_DIR/build-app.sh")

open "$APP_BUNDLE"
