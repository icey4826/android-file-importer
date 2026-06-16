// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AndroidFileImporter",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "AndroidFileImporter", targets: ["AndroidFileImporter"]),
    ],
    targets: [
        .target(
            name: "CMTPBridge",
            path: "Sources/CMTPBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-IVendor/include", "-IVendor/include/libmtp", "-IVendor/include/libusb-1.0"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-LVendor/lib"]),
                .linkedLibrary("mtp"),
                .linkedLibrary("usb-1.0"),
            ]
        ),
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
