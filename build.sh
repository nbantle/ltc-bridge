#!/bin/zsh
# Builds LTC Bridge.app (universal: Apple Silicon + Intel, macOS 13+) and runs the self-test.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/LTC Bridge.app"
VERSION="1.9.1"
SOURCES=(Sources/Core/*.swift Sources/App/*.swift)

mkdir -p build
echo "Running self-test…"
swiftc -O -swift-version 5 Sources/Core/*.swift Sources/App/AudioInput.swift Sources/App/MIDIOutput.swift Sources/App/ArtNetOutput.swift \
    Tests/main.swift -o build/selftest 2>/dev/null
./build/selftest | tail -1

echo "Building app…"
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos13.0" \
        "${SOURCES[@]}" -o "build/LTCBridge-$arch" 2>/dev/null
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create build/LTCBridge-arm64 build/LTCBridge-x86_64 -output "$APP/Contents/MacOS/LTC Bridge"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LTC Bridge</string>
    <key>CFBundleDisplayName</key><string>LTC Bridge</string>
    <key>CFBundleIdentifier</key><string>com.nbantle.ltcbridge</string>
    <key>CFBundleExecutable</key><string>LTC Bridge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>LTC Bridge listens to an audio input to read linear timecode.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
rm -f build/LTCBridge-arm64 build/LTCBridge-x86_64
echo "Built: $APP"
