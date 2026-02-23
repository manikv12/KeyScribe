#!/bin/bash

set -euo pipefail

APP_NAME="KeyScribe"
APP_EXECUTABLE="$APP_NAME"
APP_BUNDLE_ID="com.keyscribe.KeyScribe"
APP_DIR="dist/${APP_NAME}.app"
INSTALL_DIR="/Applications/${APP_NAME}.app"
DMG_ROOT="dist/dmg-root"
DMG_FINAL="dist/${APP_NAME}.dmg"
DMG_VOLUME_NAME="${APP_NAME} Installer"

INSTALL_APP=false
NO_DMG=false

for arg in "$@"; do
    case "$arg" in
        --install)
            INSTALL_APP=true
            ;;
        --no-dmg)
            NO_DMG=true
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: ./build.sh [--install] [--no-dmg]"
            exit 1
            ;;
    esac
done

echo "Building ${APP_NAME} (Release)..."
if [ ! -d "Vendor/Whisper/whisper.xcframework" ]; then
    echo "whisper.xcframework not found, downloading framework..."
    Scripts/update-whisper-framework.sh
fi
swift build -c release

echo "Creating macOS App Bundle at ${APP_DIR}..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

echo "Copying executable..."
cp ".build/release/${APP_EXECUTABLE}" "$APP_DIR/Contents/MacOS/"
chmod +x "$APP_DIR/Contents/MacOS/${APP_EXECUTABLE}"

echo "Embedding whisper framework..."
WHISPER_MACOS_FRAMEWORK="$(find Vendor/Whisper/whisper.xcframework -maxdepth 2 -type d -name whisper.framework | grep 'macos-' | head -n 1 || true)"
if [ -z "$WHISPER_MACOS_FRAMEWORK" ]; then
    echo "Failed to locate macOS whisper.framework inside Vendor/Whisper/whisper.xcframework"
    exit 1
fi
cp -R "$WHISPER_MACOS_FRAMEWORK" "$APP_DIR/Contents/MacOS/"

echo "Copying Info.plist and resources..."
cp Resources/Info.plist "$APP_DIR/Contents/"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/"

echo "Applying code signature..."
if [ -n "${DEVELOPER_ID:-}" ]; then
    echo "  Signing with Developer ID: $DEVELOPER_ID"
    codesign --force --deep --options runtime --entitlements Resources/KeyScribe.entitlements --sign "Developer ID Application: $DEVELOPER_ID" "$APP_DIR"
else
    echo "  No DEVELOPER_ID set — using ad-hoc signature."
    echo "  (Set DEVELOPER_ID env var for distribution-ready signing)"
    codesign --force --deep --sign - "$APP_DIR"
fi

if [ "$NO_DMG" = false ]; then
    echo "Creating professional drag-and-drop DMG at ${DMG_FINAL}..."
    rm -f "$DMG_FINAL"

    # Use create-dmg to build a professional-looking installer with an arrow background
    # and correct icon positions
    npx -y create-dmg "$APP_DIR" dist/ --overwrite --no-version-in-filename --icon-size 128
fi

if [ "$INSTALL_APP" = true ]; then
    echo "Installing to /Applications..."
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
    sleep 1
    rm -rf "$INSTALL_DIR"
    cp -R "$APP_DIR" "$INSTALL_DIR"

    echo "Resetting Accessibility permission..."
    sudo tccutil reset Accessibility "$APP_BUNDLE_ID" || echo "  (sudo failed — run manually: sudo tccutil reset Accessibility ${APP_BUNDLE_ID})"

    echo ""
    echo "Build complete! Installed to ${INSTALL_DIR}"
    echo "Run with: open ${INSTALL_DIR}"
    if [ "$NO_DMG" = false ]; then
        echo "Drag-and-drop installer created at: ${DMG_FINAL}"
    fi
    echo "Then re-grant Accessibility access in System Settings -> Privacy & Security -> Accessibility"
else
    echo ""
    echo "Build complete! App bundle at: ${APP_DIR}"
    if [ "$NO_DMG" = false ]; then
        echo "Drag-and-drop installer ready at: ${DMG_FINAL}"
        echo "Open installer with: open ${DMG_FINAL}"
    fi
    echo "Run app directly with: open ${APP_DIR}"
    echo "To install to /Applications, run: ./build.sh --install"
fi
