// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Celsius",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Celsius", targets: ["Celsius"]),
        .executable(name: "daikin-diagnose", targets: ["DaikinDiagnostics"]),
    ],
    targets: [
        .target(name: "CelsiusCore"),
        .executableTarget(name: "Celsius", dependencies: ["CelsiusCore"]),
        .executableTarget(name: "DaikinDiagnostics", dependencies: ["CelsiusCore"]),
        .testTarget(
            name: "CelsiusCoreTests",
            dependencies: ["CelsiusCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
