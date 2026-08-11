// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vInput",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "vInput", targets: ["vInput"])
    ],
    targets: [
        .executableTarget(
            name: "vInput",
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
