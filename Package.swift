// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AndroidFileImporter",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "AndroidFileImporter", targets: ["AndroidFileImporter"]),
    ],
    targets: [
        .executableTarget(
            name: "AndroidFileImporter",
            dependencies: [],
            path: "Sources/AndroidFileImporter",
            exclude: ["NativeMTPClient.swift"],
            swiftSettings: [.unsafeFlags(["-strict-concurrency=minimal"])]
        ),
        .testTarget(
            name: "AndroidFileImporterTests",
            dependencies: ["AndroidFileImporter"],
            path: "Tests/AndroidFileImporterTests"
        ),
    ]
)
