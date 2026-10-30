// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Varbor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "varbor", targets: ["varbor"]),
        .executable(name: "VarborApp", targets: ["VarborApp"]),
    ],
    targets: [
        .target(name: "VarborCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "varbor", dependencies: ["VarborCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "VarborApp", dependencies: ["VarborCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "VarborCoreTests", dependencies: ["VarborCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
