// swift-tools-version:6.0
import Foundation
import PackageDescription

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path

let package = Package(
    name: "MacVR",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "macvr", targets: ["macvr"]),
        .executable(name: "MacVRApp", targets: ["MacVRApp"]),
        .executable(name: "macvr-broker", targets: ["macvr-broker"]),
        .executable(name: "macvr-webhelper", targets: ["macvr-webhelper"]),
    ],
    targets: [
        .target(name: "MacVRCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "macvr", dependencies: ["MacVRCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "MacVRApp", dependencies: ["MacVRCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "CMacVRXR",
            cSettings: [.unsafeFlags(["-I\(repo)/third_party/openxr-sdk/include", "-I\(repo)/build/openxr-sdk/include",
                                      "-I/usr/local/include"])],
            linkerSettings: [.unsafeFlags(["-L/usr/local/lib", "-lvulkan", "-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"])]
        ),
        .executableTarget(name: "macvr-broker", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "macvr-webhelper", dependencies: ["CMacVRXR"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MacVRCoreTests", dependencies: ["MacVRCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
