// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sirpi",
    platforms: [.macOS("27.0")],
    dependencies: [
        // In-process inference on Apple silicon (Qwen3.5 / Gated DeltaNet supported natively).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "Sirpi",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/Sirpi",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
