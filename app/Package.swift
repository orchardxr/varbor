// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacVR",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "macvr", targets: ["macvr"]),
        .executable(name: "MacVRApp", targets: ["MacVRApp"]),
    ],
    targets: [
        .target(name: "MacVRCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "macvr", dependencies: ["MacVRCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "MacVRApp", dependencies: ["MacVRCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MacVRCoreTests", dependencies: ["MacVRCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
