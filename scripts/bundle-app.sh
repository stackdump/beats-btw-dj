#!/bin/sh
# Wrap the SwiftPM DJApp executable in a minimal .app bundle (no Xcode needed).
# usage: scripts/bundle-app.sh <config: debug|release> <out-dir>
set -eu
config=${1:-debug}
out=${2:-build}
swift build -c "$config" --product DJApp >&2
bin=$(swift build -c "$config" --show-bin-path)
app="$out/DJApp.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/DJApp" "$app/Contents/MacOS/DJApp"
# Resources go in Contents/Resources (JogProfile.load checks Bundle.main first).
# SwiftPM's own .bundle is not copied: its accessor wants it at the .app root,
# which codesign rejects.
cp -R Sources/DJCore/Resources/profiles "$app/Contents/Resources/profiles"
cp -R Sources/DJCore/Resources/beats "$app/Contents/Resources/beats"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>DJApp</string>
  <key>CFBundleIdentifier</key><string>se.vevr.dj</string>
  <key>CFBundleName</key><string>dj-vevr-se</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
# Ad-hoc sign so Gatekeeper and TCC treat it as one stable app.
codesign --force --sign - "$app" >/dev/null
echo "$app"
