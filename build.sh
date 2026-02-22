#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

echo "Building KeyScribe..."
swift build

echo "Creating macOS App Bundle..."
mkdir -p KeyScribe.app/Contents/MacOS
mkdir -p KeyScribe.app/Contents/Resources

echo "Copying executable..."
cp .build/debug/KeyScribe KeyScribe.app/Contents/MacOS/
chmod +x KeyScribe.app/Contents/MacOS/KeyScribe


echo "Copying Info.plist..."
cp Resources/Info.plist KeyScribe.app/Contents/

echo "Build complete! You can run the app with: open KeyScribe.app"
