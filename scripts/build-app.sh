#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_NAME="MicroCube Metal"
EXECUTABLE_NAME="MicroCubeMetal"
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

swift build --package-path "$PROJECT_DIR" -c release --arch arm64 >&2
BIN_DIR=$(swift build --package-path "$PROJECT_DIR" -c release --arch arm64 --show-bin-path)

mkdir -p "$DIST_DIR"
STAGING_DIR=$(mktemp -d "$DIST_DIR/.microcube-app.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT

STAGING_APP="$STAGING_DIR/$APP_NAME.app"
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
install -m 755 "$BIN_DIR/$EXECUTABLE_NAME" "$STAGING_APP/Contents/MacOS/$EXECUTABLE_NAME"
install -m 644 "$SCRIPT_DIR/Info.plist" "$STAGING_APP/Contents/Info.plist"

for bundle in "$BIN_DIR"/*.bundle(N); do
    ditto "$bundle" "$STAGING_APP/Contents/Resources/${bundle:t}"
done

for metallib in "$BIN_DIR"/*.metallib(N); do
    install -m 644 "$metallib" "$STAGING_APP/Contents/Resources/${metallib:t}"
done

if command -v codesign >/dev/null 2>&1 && [[ ${SKIP_CODESIGN:-0} != 1 ]]; then
    codesign --force --sign - --timestamp=none "$STAGING_APP"
fi

if [[ -e "$APP_BUNDLE" ]]; then
    rm -rf "$APP_BUNDLE"
fi
mv "$STAGING_APP" "$APP_BUNDLE"

print -r -- "$APP_BUNDLE"
