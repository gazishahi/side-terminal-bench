// swift-tools-version: 6.0
import PackageDescription

// End-to-end terminal benchmark: four setups in real windows, same PTY, font, size and workloads.
// A SwiftTerm stock view (CoreText, main thread) · B SwiftTerm off main + Alloy renderer
// C libghostty-vt + Alloy renderer · D full libghostty (Ghostty's own renderer)
let package = Package(
    name: "TermBench",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0")],
    targets: [
        .target(name: "Harness", path: "Sources/Harness"),
        .executableTarget(name: "TermBenchST", dependencies: ["Harness", "SwiftTerm"], path: "Sources/TermBenchST"),
        .executableTarget(name: "TermBenchGV", dependencies: ["Harness", "GhosttyVt"], path: "Sources/TermBenchGV"),
        .executableTarget(name: "TermBenchGK", dependencies: ["Harness", "GhosttyKit"], path: "Sources/TermBenchGK",
                          linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Carbon"), .linkedFramework("Metal"),
                                           .linkedFramework("QuartzCore"), .linkedFramework("CoreText"), .linkedFramework("IOSurface"),
                                           .linkedFramework("CoreVideo"), .linkedFramework("UniformTypeIdentifiers")]),
        .binaryTarget(name: "GhosttyVt", path: "GhosttyVt.xcframework"),
        .binaryTarget(name: "GhosttyKit", path: "GhosttyKit.xcframework"),
    ],
    swiftLanguageModes: [.v5]
)
