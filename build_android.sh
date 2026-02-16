#!/bin/bash

# Build Mellon Chat Android App Bundle (AAB) for Google Play Store upload
# Usage: ./build_android.sh

set -e

# Set up Java environment
export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
export PATH="$JAVA_HOME/bin:$PATH"

# Use FVM if available
if command -v fvm &> /dev/null; then
    FLUTTER="fvm flutter"
else
    FLUTTER="flutter"
fi

echo "Building Mellon Chat Android App Bundle..."
$FLUTTER build appbundle

AAB_PATH="build/app/outputs/bundle/release/app-release.aab"

if [ -f "$AAB_PATH" ]; then
    echo ""
    echo "Build completed successfully!"
    echo "AAB location: $AAB_PATH"
    echo ""
    echo "Upload this file to Google Play Console:"
    echo "  https://play.google.com/console"
else
    echo "Build failed - AAB file not found"
    exit 1
fi
