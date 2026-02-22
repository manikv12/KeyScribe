// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeyScribe",
    platforms: [
        .macOS("13.0")
    ],
    products: [
        .executable(name: "KeyScribe", targets: ["KeyScribe"])
    ],
    targets: [
        .executableTarget(
            name: "KeyScribe",
            path: "Sources/KeyScribe",
            resources: [.process("../../Resources")]
        )
    ]
)
