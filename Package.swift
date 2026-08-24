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
    //
    // MLX 用 exact 而非 from：MLXLLM / MLXLMCommon 的 API 在小版本间变动过
    // （ChatSession 是较新引入的），锁死版本避免 swift package update
    // 悄悄改变行为。
    //
    // 该依赖及其传递依赖（mlx-swift、swift-transformers、GzipSwift）在本机
    // 网络下无法直接克隆——git 报 "HTTP/2 stream was not closed cleanly"，
    // mlx-swift 的两万多个对象拉到一半必断。解法是用 HTTP/1.1 预先克隆到
    // ~/Library/Application Support/vInput/spm-mirrors/，再经 SPM 的本地
    // 镜像机制接上（配置在 .swiftpm/configuration/mirrors.json）。
    // 这样不必改动本文件里的 URL，也不必碰全局 git 配置。
    // 重建方法见 docs/dev-dependencies.md。
    dependencies: [
        .package(path: "vendor/WhisperKit"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", exact: "2.29.1"),
    ],
    targets: [
        .executableTarget(
            name: "vInputBench",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/vInputBench"
        ),
        .executableTarget(
            name: "vInput",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ],
            path: "Sources/vInput",
            // tokenizer 随 app 分发（2.8 MB）：`.copy` 保留目录结构，运行时经
            // `Bundle.module` 找到 `Tokenizers/openai/whisper-large-v3/`。
            // 理由见 `BundledTokenizer` 的类型注释。
            resources: [.copy("Resources/Tokenizers")]
        ),
        .testTarget(
            name: "vInputTests",
            dependencies: ["vInput"],
            path: "Tests/vInputTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
