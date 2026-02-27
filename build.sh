#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="VoiceInput"
BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CERT_NAME="VoiceInput Dev"

echo "Building $APP_NAME..."

# Clean previous build
rm -rf "$BUILD_DIR"

# Create .app bundle structure
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy Info.plist and app icon
cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/"
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/"
fi

# Compile Swift files
swiftc -O \
    -framework Cocoa \
    -framework AVFoundation \
    -framework Carbon \
    -module-name VoiceInput \
    "$SCRIPT_DIR/VoiceInput/"*.swift \
    -o "$APP_DIR/Contents/MacOS/$APP_NAME"

# Code signing (preserves TCC permissions across rebuilds)
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    codesign --force --sign "$CERT_NAME" "$APP_DIR"
    echo ""
    echo "✅ Build complete (signed with \"$CERT_NAME\"): $APP_DIR"
else
    echo ""
    echo "⚠️  Build complete (unsigned): $APP_DIR"
    echo "   Run ./setup-signing.sh first to create a signing certificate."
    echo "   Without signing, macOS will reset permissions on each rebuild."
fi

# Install to /Applications
INSTALL_DIR="/Applications/$APP_NAME.app"
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
fi
cp -r "$APP_DIR" /Applications/
echo "   Installed to /Applications/$APP_NAME.app"

echo ""
echo "To run: open /Applications/$APP_NAME.app"
