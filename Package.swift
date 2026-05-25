// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "kawpow-mac",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "kawpow-mac",
            path: "Sources/kawpow-mac",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
