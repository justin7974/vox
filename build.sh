#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="VoiceInput"
BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."

# Clean previous build
rm -rf "$BUILD_DIR"

# Create .app bundle structure
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/"

# Compile Swift files
swiftc -O \
    -framework Cocoa \
    -framework AVFoundation \
    -framework Carbon \
    -module-name VoiceInput \
    "$SCRIPT_DIR/VoiceInput/"*.swift \
    -o "$APP_DIR/Contents/MacOS/$APP_NAME"

echo ""
echo "✅ Build complete: $APP_DIR"
echo ""
echo "To run:     open $APP_DIR"
echo "To install: cp -r $APP_DIR ~/Applications/"
