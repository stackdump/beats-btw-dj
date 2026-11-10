#!/usr/bin/env bash
# Build the djrust engine (rust/ = the `djmobile` UniFFI crate, same surface as djandroid's) as
# static libs for macOS (arm64+x86_64), iOS device and iOS simulator, package them as
# rust/dist/djmobileFFI.xcframework and write the UniFFI Swift bindings into Sources/DJRust/.
#
# No Xcode needed: rustc ships the Apple std, lipo is in the CLT, and the XCFramework is
# assembled by hand (xcodebuild -create-xcframework is only a directory layout + Info.plist).
# The iOS slices link nothing until an app does (staticlib), so they build without an iOS SDK.
set -euo pipefail
cd "$(dirname "$0")/../rust"
SLICES=${SLICES:-"aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios"}
for t in $SLICES; do
  rustup target list --installed | grep -qx "$t" || rustup target add "$t"
  cargo build --release --lib --target "$t"
done
T=target; D=dist; X=$D/djmobileFFI.xcframework
rm -rf $D target/bindings target/universal; mkdir -p $D target/universal/{macos,ios-sim}
cargo run -q --release --bin uniffi-bindgen -- generate \
  --library $T/aarch64-apple-darwin/release/libdjmobile.a --language swift --out-dir target/bindings
lipo -create $T/aarch64-apple-darwin/release/libdjmobile.a $T/x86_64-apple-darwin/release/libdjmobile.a \
  -output target/universal/macos/libdjmobile.a
lipo -create $T/aarch64-apple-ios-sim/release/libdjmobile.a $T/x86_64-apple-ios/release/libdjmobile.a \
  -output target/universal/ios-sim/libdjmobile.a
slice() { # id lib archs platform [variant]
  mkdir -p "$X/$1/Headers"; cp "$2" "$X/$1/libdjmobile.a"
  cp target/bindings/djmobileFFI.h "$X/$1/Headers/"
  cp target/bindings/djmobileFFI.modulemap "$X/$1/Headers/module.modulemap"
  v=""; [ -n "${5:-}" ] && v="<key>SupportedPlatformVariant</key><string>$5</string>"
  printf '<dict><key>HeadersPath</key><string>Headers</string><key>LibraryIdentifier</key><string>%s</string><key>LibraryPath</key><string>libdjmobile.a</string><key>SupportedArchitectures</key><array>%s</array><key>SupportedPlatform</key><string>%s</string>%s</dict>' \
    "$1" "$(for a in $3; do printf '<string>%s</string>' $a; done)" "$4" "$v" >> $D/entries.xml
}
: > $D/entries.xml
slice macos-arm64_x86_64 target/universal/macos/libdjmobile.a "arm64 x86_64" macos
slice ios-arm64 $T/aarch64-apple-ios/release/libdjmobile.a "arm64" ios
slice ios-arm64_x86_64-simulator target/universal/ios-sim/libdjmobile.a "arm64 x86_64" ios simulator
{ echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>AvailableLibraries</key><array>'
  cat $D/entries.xml
  echo '</array><key>CFBundlePackageType</key><string>XFWK</string><key>XCFrameworkFormatVersion</key><string>1.0</string></dict></plist>'; } > $X/Info.plist
rm $D/entries.xml; plutil -lint $X/Info.plist
mkdir -p ../Sources/DJRust && cp target/bindings/djmobile.swift ../Sources/DJRust/djmobile.swift
du -sh $X; echo "xcframework: rust/dist/djmobileFFI.xcframework"
