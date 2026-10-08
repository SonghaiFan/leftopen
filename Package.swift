// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LeftOpen",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LeftOpenCore", targets: ["LeftOpenCore"]),
        .executable(name: "LeftOpenApp", targets: ["LeftOpenApp"]),
        .executable(name: "leftopen", targets: ["LeftOpenCLI"]),
    ],
    targets: [
        .target(name: "LeftOpenCore", path: "Sources/LeftOpenCore"),
        .executableTarget(name: "LeftOpenApp", dependencies: ["LeftOpenCore"], path: "Sources/LeftOpenApp",
                          resources: [.copy("Resources/FranklinSignature.svg"), .copy("Resources/GitHubMark.svg"),
                                      .copy("Resources/DoorClose.aiff"), .copy("Resources/DoorOpen.aiff")]),
        .executableTarget(name: "LeftOpenCLI", dependencies: ["LeftOpenCore"], path: "Sources/LeftOpenCLI"),
        .testTarget(name: "LeftOpenAppTests", dependencies: ["LeftOpenApp"], path: "Tests/LeftOpenAppTests"),
        .testTarget(name: "LeftOpenCoreTests", dependencies: ["LeftOpenCore"], path: "Tests/LeftOpenCoreTests"),
    ]
)
