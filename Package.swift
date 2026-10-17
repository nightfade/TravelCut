// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TravelCut",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TravelCutCore", targets: ["TravelCutCore"]),
        .executable(name: "TravelCut", targets: ["TravelCutApp"]),
        .executable(name: "travelcut-cli", targets: ["TravelCutCLI"]),
        .executable(name: "travelcut-selftest", targets: ["TravelCutSelfTest"]),
    ],
    targets: [
        .target(
            name: "TravelCutCore",
            resources: [.copy("Resources")],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreML"),
                .linkedFramework("SoundAnalysis"),
            ]
        ),
        .executableTarget(
            name: "TravelCutApp",
            dependencies: ["TravelCutCore"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]
        ),
        .executableTarget(name: "TravelCutCLI", dependencies: ["TravelCutCore"]),
        .executableTarget(name: "TravelCutSelfTest", dependencies: ["TravelCutCore"]),
    ],
    swiftLanguageModes: [.v5]
)
