#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")
OUTPUT_DIR="$PROJECT_DIR/dist"
APP_DIR="$OUTPUT_DIR/MouseGesture.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$PROJECT_DIR"
if [ "${MOUSEGESTURE_DISABLE_SWIFTPM_SANDBOX:-0}" = "1" ]; then
    swift build -c release --product MouseGesture --disable-sandbox
    BIN_DIR=$(swift build -c release --show-bin-path --disable-sandbox)
else
    swift build -c release --product MouseGesture
    BIN_DIR=$(swift build -c release --show-bin-path)
fi

if [ -d "$APP_DIR" ]; then
    rm -rf -- "$APP_DIR"
fi

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/MouseGesture" "$CONTENTS_DIR/MacOS/MouseGesture"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/MouseGesture.icns" "$CONTENTS_DIR/Resources/"
cp "$PROJECT_DIR/Resources/MenuBarIcon.png" "$CONTENTS_DIR/Resources/"
cp "$PROJECT_DIR/Resources/MenuBarIcon@2x.png" "$CONTENTS_DIR/Resources/"

# A stable identity keeps the Accessibility grant across rebuilds; an ad-hoc
# signature changes with every build and macOS treats it as a new app.
DEFAULT_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')
CODESIGN_IDENTITY=${MOUSEGESTURE_CODESIGN_IDENTITY:-${DEFAULT_IDENTITY:--}}
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
