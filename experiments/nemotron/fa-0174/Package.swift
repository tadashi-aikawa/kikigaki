// swift-tools-version: 6.0
import PackageDescription

// FluidAudio 0.17.4 で Sortformer(依存更新だけの差分)・Nemotron 3 Diarization・Nemotron 3.5 ASR を流す。
// Apple Speech も同じCLIから同じ入力で流し、文字起こしの比較相手にする。
let package = Package(
    name: "Bench0174",
    // SpeechTranscriber が macOS 26 以降のため
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
    ],
    targets: [
        .executableTarget(
            name: "Bench0174",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
