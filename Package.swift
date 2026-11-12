// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "stew",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "stew", targets: ["stew"]),
        .library(name: "StewLink", targets: ["StewLink", "StewCore"]),
    ],
    targets: [
        .target(name: "StewCore"),
        .target(name: "StewLink", dependencies: ["StewCore"]),
        .executableTarget(
            name: "stew",
            dependencies: ["StewCore", "StewLink"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("AppKit"), .linkedFramework("AudioToolbox")]
        ),
        .testTarget(name: "StewCoreTests", dependencies: ["StewCore"]),
        .testTarget(name: "StewLinkTests", dependencies: ["StewLink", "StewCore"]),
        // A stand-in iPhone for Tests/phone/run.sh: pairs, decrypts recorded pushes, answers.
        .executableTarget(name: "stew-test-phone", dependencies: ["StewLink", "StewCore"], path: "Tests/TestPhone"),
    ]
)
