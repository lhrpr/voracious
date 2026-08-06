// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "voracious_video",
  platforms: [
    .macOS("10.15")
  ],
  products: [
    .library(name: "voracious-video", targets: ["voracious_video"])
  ],
  dependencies: [],
  targets: [
    // libmpv's client API headers, vendored. They are ISC-licensed precisely so
    // that wrappers outside the mpv tree can copy them, and copying is what
    // keeps this package buildable on a machine with no libmpv installed:
    // nothing here links against the library, it is resolved with dlsym at
    // runtime. See Sources/mpv_client_api/README.md.
    .target(name: "mpv_client_api"),
    .target(
      name: "voracious_video",
      dependencies: ["mpv_client_api"],
      linkerSettings: [
        .linkedFramework("OpenGL"),
        .linkedFramework("CoreVideo"),
        .linkedFramework("IOSurface"),
      ]
    ),
  ]
)
