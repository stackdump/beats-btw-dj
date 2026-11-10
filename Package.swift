// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The Rust engine (rust/, built by scripts/build-rust-xcframework.sh) is optional: the package
// grows the DJRust target, the djrust-smoke tool and the DJ_RUST flag only when
// rust/dist/djmobileFFI.xcframework exists, so a plain `swift build` still builds the Swift app.
let rustXCFramework = "rust/dist/djmobileFFI.xcframework"
let hasRust = FileManager.default.fileExists(
  atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(rustXCFramework).path)
let rustTargets: [Target] =
  hasRust
  ? [
    .binaryTarget(name: "djmobileFFI", path: rustXCFramework),
    // UniFFI's generated Swift (Sources/DJRust/djmobile.swift) + the RustEngine face.
    .target(
      name: "DJRust", dependencies: ["djmobileFFI"],
      swiftSettings: [.swiftLanguageMode(.v5)],
      // a static lib doesn't carry its frameworks: cpal's CoreAudio backend needs these
      linkerSettings: [
        .linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio"),
        .linkedFramework("CoreFoundation"),
      ]),
    .executableTarget(name: "djrust-smoke", dependencies: ["DJRust"]),
  ] : []
let rustDep: [Target.Dependency] = hasRust ? ["DJRust"] : []
let rustFlag: [SwiftSetting] = hasRust ? [.define("DJ_RUST")] : []

let package = Package(
  name: "dj-vevr-se",
  // macOS 15 is also what makes swift-testing's macros compile.
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "DJCore", targets: ["DJCore"]),
    .executable(name: "djctl", targets: ["djctl"]),
    .executable(name: "DJApp", targets: ["DJApp"]),
  ] + (hasRust ? [.executable(name: "djrust-smoke", targets: ["djrust-smoke"])] : []),
  targets: [
    // Device profiles, jog parsing, CoreMIDI input. No UI, no audio graph yet.
    .target(
      name: "DJCore",
      resources: [
        .copy("Resources/profiles"), .copy("Resources/beats"), .copy("Resources/voices"),
        .copy("Resources/stingers"),
      ]
    ),
    // CLI: ports / monitor — the Swift twin of the Go tool, for hardware checks.
    .executableTarget(name: "djctl", dependencies: ["DJCore"]),
    // Visual components (waveform, platter, net view, timeline, pad mirror, device map).
    // SwiftUI lives here; DJCore must never import it.
    .target(name: "DJViews", dependencies: ["DJCore"] + rustDep, swiftSettings: rustFlag),
    // SwiftUI app. `make app` wraps it in a .app bundle.
    .executableTarget(
      name: "DJApp", dependencies: ["DJCore", "DJViews"] + rustDep, swiftSettings: rustFlag),
    .testTarget(
      name: "DJCoreTests", dependencies: ["DJCore"],
      resources: [.copy("Fixtures")]),
    .testTarget(name: "DJViewsTests", dependencies: ["DJViews", "DJCore"]),
  ] + rustTargets
)
