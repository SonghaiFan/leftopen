// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LeftOpen",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LeftOpenCore", targets: ["LeftOpenCore"]),
        .executable(name: "LeftOpenApp", targets: ["LeftOpenApp"]),
    ],
    targets: [
        .target(name: "LeftOpenCore", path: "Sources/LeftOpenCore"),
        .executableTarget(name: "LeftOpenApp", dependencies: ["LeftOpenCore"], path: "Sources/LeftOpenApp"),
        .testTarget(name: "LeftOpenCoreTests", dependencies: ["LeftOpenCore"], path: "Tests/LeftOpenCoreTests"),
    ]
)
