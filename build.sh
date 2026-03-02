#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Vox"
BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CERT_NAME="Vox Dev"

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

# Copy built-in Action definitions
if [ -d "$SCRIPT_DIR/Vox/Resources/Actions" ]; then
    mkdir -p "$APP_DIR/Contents/Resources/Actions"
    cp "$SCRIPT_DIR/Vox/Resources/Actions/"*.md "$APP_DIR/Contents/Resources/Actions/"
fi

# Compile Swift files (including subdirectories)
SWIFT_FILES=$(find "$SCRIPT_DIR/Vox" -name "*.swift" -type f)
swiftc -O \
    -framework Cocoa \
    -framework AVFoundation \
    -framework Carbon \
    -module-name Vox \
    $SWIFT_FILES \
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
    # Clear stale TCC entry before replacing binary — prevents accessibility permission
    # from appearing "granted" but silently not working after update
    tccutil reset Accessibility com.justin.vox 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
fi
cp -r "$APP_DIR" /Applications/
echo "   Installed to /Applications/$APP_NAME.app"

echo ""
echo "To run: open /Applications/$APP_NAME.app"
