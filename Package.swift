// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeyScribe",
    platforms: [
        .macOS("13.3")
    ],
    products: [
        .executable(name: "KeyScribe", targets: ["KeyScribe"])
    ],
    targets: [
        .executableTarget(
            name: "KeyScribe",
            dependencies: [
                "whisper"
            ],
            path: "Sources/KeyScribe",
            resources: [.process("../../Resources")]
        ),
        .binaryTarget(
            name: "whisper",
            path: "Vendor/Whisper/whisper.xcframework"
        )
    ]
)
