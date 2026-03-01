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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "KeyScribe",
            dependencies: [
                "whisper",
                .product(name: "Sparkle", package: "Sparkle")
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
