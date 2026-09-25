// swift-tools-version: 6.0
import PackageDescription

// アプリと同じ FluidAudio 0.15.6 の Sortformer を、比較用CLIと同じ入力・計測で流す基準線。
// 0.17.4 と同じパッケージには置けない(SwiftPM は同じ依存の2版を1つのグラフへ入れられない)。
let package = Package(
    name: "Bench0156",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
    ],
    targets: [
        .executableTarget(
            name: "Bench0156",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
