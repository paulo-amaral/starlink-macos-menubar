// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StarPulse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StarPulse", targets: ["StarPulse"]),
    ],
    targets: [
        .target(name: "StarPulseCore", resources: [.copy("Resources/oui.json")]),
        .executableTarget(
            name: "StarPulse",
            dependencies: ["StarPulseCore"],
            exclude: ["Info.plist"],
            resources: [.copy("Resources/Fonts")]
        ),
        .testTarget(
            name: "StarPulseCoreTests",
            dependencies: ["StarPulseCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
