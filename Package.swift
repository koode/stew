// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "stew",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "stew", targets: ["stew"]),
    ],
    targets: [
        .target(name: "StewCore"),
        .executableTarget(
            name: "stew",
            dependencies: ["StewCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("AppKit"), .linkedFramework("AudioToolbox")]
        ),
        .testTarget(name: "StewCoreTests", dependencies: ["StewCore"]),
    ]
)
