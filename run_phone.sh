#!/bin/bash
# Spectrum device deploy helper.
#
# Builds, installs, and launches Spectrum on the connected iPhone in one
# step. Any extra arguments are forwarded to the app's launch-arg parser
# (`-mode`, `-source`, `-testfile`, `-autoplay`, `-tuning`, `-bpm`,
# `-pitchlog`, `-bpmlog`, `-gain`, …).
#
# Usage:
#   ./run_phone.sh                                          # plain launch
#   ./run_phone.sh -mode surface+ -source music             # surface waterfall + music source
#   ./run_phone.sh -autoplay "Missing" -bpm                 # play library track + BPM overlay
#   ./run_phone.sh -tuning -pitchlog                        # tuner with verbose pitch logging
#   ./run_phone.sh -testfile pink_tone.wav -mode bars       # bundled test file
#
# Requires the iPhone to be connected, unlocked, and trusted. Env vars
# (APPLE_TEAM_ID, IPHONE_UDID, IPHONE_BUILD_ID) come from
# ~/appledev/setupenv.sh — source it from your shell profile if you
# haven't already.

set -euo pipefail

: "${APPLE_TEAM_ID:?set APPLE_TEAM_ID in ~/appledev/setupenv.sh}"
: "${IPHONE_UDID:?set IPHONE_UDID in ~/appledev/setupenv.sh}"
: "${IPHONE_BUILD_ID:?set IPHONE_BUILD_ID in ~/appledev/setupenv.sh}"

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_ID="com.pwilliams.Spectrum"

echo "▶ Building for device (team ${APPLE_TEAM_ID})..."
# Use `id=` destination + -allowProvisioningUpdates + DEVELOPMENT_TEAM —
# the bare `name="Paul's iPhone 16 Pro"` form silently produces an unsigned
# .app on this project, which then fails to install with "No code signature
# found".
xcodebuild -project "$PROJECT_DIR/Spectrum.xcodeproj" \
    -scheme Spectrum \
    -destination "id=$IPHONE_BUILD_ID" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    build 2>&1 | tail -3

APP=$(find ~/Library/Developer/Xcode/DerivedData/Spectrum-*/Build/Products/Debug-iphoneos -name Spectrum.app -type d | head -1)
if [ -z "$APP" ]; then
    echo "✗ Could not find built app under DerivedData."
    exit 1
fi

echo "▶ Installing ${APP}"
xcrun devicectl device install app --device "$IPHONE_UDID" "$APP" 2>&1 \
    | grep -E "App installed|ERROR|error" | head -3

echo "▶ Launching"
if [ "$#" -gt 0 ]; then
    echo "  args: $*"
    xcrun devicectl device process launch --device "$IPHONE_UDID" "$BUNDLE_ID" -- "$@" 2>&1 \
        | grep -E "Launched|ERROR|error" | head -3
else
    xcrun devicectl device process launch --device "$IPHONE_UDID" "$BUNDLE_ID" 2>&1 \
        | grep -E "Launched|ERROR|error" | head -3
fi

echo "✓ Done."
