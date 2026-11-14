#!/usr/bin/env bash
# Build the djrust engine for Apple platforms from djandroid's own UniFFI crate (`djmobile`,
# stackdump/djandroid-vevr-se rust/) — the same crate and the same `Player` surface the Android
# app drives, never a fork. Packages static libs for macOS (arm64+x86_64), iOS device and iOS
# simulator as rust/dist/djmobileFFI.xcframework and writes the UniFFI Swift bindings to
# Sources/DJRust/djmobile.swift.
#
# Sources: a read-only snapshot (`git archive`, nothing written to those repos) of each sibling
# checkout at the rev pinned in rust/PINS, laid out as the crate's path deps expect:
#   rust/upstream/{djandroid-vevr-se/rust, djrust-vevr-se, djrust, windwheel}
# `UPDATE=1` re-pins every repo to its origin/main (after a fetch) and rewrites rust/PINS.
#
# djandroid's crate is `cdylib + lib`; `cargo rustc --crate-type staticlib` gives the .a without
# touching its Cargo.toml. No Xcode needed: rustc ships the Apple std, lipo is in the CLT, and the
# XCFramework is a directory + Info.plist assembled by hand.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WS="${DJ_WORKSPACE:-$(dirname "$ROOT")}"
R="$ROOT/rust"; U="$R/upstream"; PIN="$R/PINS"
REPOS="djandroid-vevr-se djrust-vevr-se djrust windwheel"

if [ "${UPDATE:-0}" = 1 ] || [ ! -f "$PIN" ]; then
  : > "$PIN.new"
  for r in $REPOS; do
    git -C "$WS/$r" fetch -q origin
    echo "$r $(git -C "$WS/$r" rev-parse origin/main)" >> "$PIN.new"
  done
  mv "$PIN.new" "$PIN"
fi

# snapshot (re-extracted only when the pin changes)
mkdir -p "$U"
while read -r r rev; do
  [ "$(cat "$U/.$r.rev" 2>/dev/null)" = "$rev" ] && continue
  rm -rf "${U:?}/$r"; mkdir -p "$U/$r"
  git -C "$WS/$r" archive "$rev" | tar -x -C "$U/$r"
  echo "$rev" > "$U/.$r.rev"; echo "snapshot $r @ ${rev:0:7}"
done < "$PIN"

CRATE="$U/djandroid-vevr-se/rust"
export CARGO_TARGET_DIR="$R/target"
T="$CARGO_TARGET_DIR"; D="$R/dist"; X="$D/djmobileFFI.xcframework"
SLICES=${SLICES:-"aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios"}
cd "$CRATE"
for t in $SLICES; do
  rustup target list --installed | grep -qx "$t" || rustup target add "$t"
  cargo rustc --locked --release --lib --target "$t" --crate-type staticlib
done
rm -rf "$D" "$T/bindings" "$T/universal"; mkdir -p "$D" "$T/universal/macos" "$T/universal/ios-sim"
cargo run --locked -q --release --bin uniffi-bindgen -- generate \
  --library "$T/aarch64-apple-darwin/release/libdjmobile.a" --language swift --out-dir "$T/bindings"
lipo -create "$T/aarch64-apple-darwin/release/libdjmobile.a" "$T/x86_64-apple-darwin/release/libdjmobile.a" \
  -output "$T/universal/macos/libdjmobile.a"
lipo -create "$T/aarch64-apple-ios-sim/release/libdjmobile.a" "$T/x86_64-apple-ios/release/libdjmobile.a" \
  -output "$T/universal/ios-sim/libdjmobile.a"
slice() { # id lib archs platform [variant]
  mkdir -p "$X/$1/Headers"; cp "$2" "$X/$1/libdjmobile.a"
  cp "$T/bindings/djmobileFFI.h" "$X/$1/Headers/"
  cp "$T/bindings/djmobileFFI.modulemap" "$X/$1/Headers/module.modulemap"
  v=""; [ -n "${5:-}" ] && v="<key>SupportedPlatformVariant</key><string>$5</string>"
  printf '<dict><key>HeadersPath</key><string>Headers</string><key>LibraryIdentifier</key><string>%s</string><key>LibraryPath</key><string>libdjmobile.a</string><key>SupportedArchitectures</key><array>%s</array><key>SupportedPlatform</key><string>%s</string>%s</dict>' \
    "$1" "$(for a in $3; do printf '<string>%s</string>' $a; done)" "$4" "$v" >> "$D/entries.xml"
}
: > "$D/entries.xml"
slice macos-arm64_x86_64 "$T/universal/macos/libdjmobile.a" "arm64 x86_64" macos
slice ios-arm64 "$T/aarch64-apple-ios/release/libdjmobile.a" "arm64" ios
slice ios-arm64_x86_64-simulator "$T/universal/ios-sim/libdjmobile.a" "arm64 x86_64" ios simulator
{ echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>AvailableLibraries</key><array>'
  cat "$D/entries.xml"
  echo '</array><key>CFBundlePackageType</key><string>XFWK</string><key>XCFrameworkFormatVersion</key><string>1.0</string></dict></plist>'; } > "$X/Info.plist"
rm "$D/entries.xml"; plutil -lint "$X/Info.plist"
mkdir -p "$ROOT/Sources/DJRust" && cp "$T/bindings/djmobile.swift" "$ROOT/Sources/DJRust/djmobile.swift"
du -sh "$X"; echo "xcframework: rust/dist/djmobileFFI.xcframework (pins: rust/PINS)"
