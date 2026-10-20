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
cp -R Sources/DJCore/Resources/voices "$app/Contents/Resources/voices"
cp -R Sources/DJCore/Resources/stingers "$app/Contents/Resources/stingers"

# Build id, read back by BuildInfo: the commit, "-dirty" with tracked changes; "unknown"
# outside a git checkout.
build=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ "$build" != unknown ] && [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  build="$build-dirty"
fi
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# App icon: assets/AppIcon.png (scripts/make-icon.swift draws it) -> AppIcon.icns.
icon_src=assets/AppIcon.png
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$icon_src" --out "$iconset/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s * 2))" "$((s * 2))" "$icon_src" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>DJApp</string>
  <key>CFBundleIdentifier</key><string>se.vevr.dj</string>
  <key>CFBundleName</key><string>dj-vevr-se</string>
  <key>CFBundleDisplayName</key><string>dj-vevr-se</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>DJBuildDate</key><string>$built</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
# Ad-hoc sign so Gatekeeper and TCC treat it as one stable app.
codesign --force --sign - "$app" >/dev/null
echo "$app"
