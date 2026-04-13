// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskLens",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DiskLens",
            path: "Sources/DiskLens",
            resources: [
                .process("Resources/Logos")
            ]
        )
    ]
)
