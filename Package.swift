// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vInput",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "vInput", targets: ["vInput"])
    ],
    // 临时使用本地路径依赖：执行 Task 2 时网络持续丢包，
    // swift package resolve 无法克隆完整仓库（见计划「风险 0」）。
    // vendor/WhisperKit 是 v1.1.0 的浅克隆。网络恢复后应改回
    // .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0")
    dependencies: [
        .package(path: "vendor/WhisperKit")
    ],
    targets: [
        .executableTarget(
            name: "vInput",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/vInput"
        ),
        .testTarget(
            name: "vInputTests",
            dependencies: ["vInput"],
            path: "Tests/vInputTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
