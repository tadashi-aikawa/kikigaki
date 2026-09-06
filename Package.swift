// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kikigaki",
    // SpeechTranscriber(Speech framework の新API)が macOS 26 以降のため
    platforms: [.macOS("26.0")],
    dependencies: [
        // Command Line Tools のみの環境には Swift Testing の内部モジュールが同梱されないため依存で供給
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "0.12.0"),
        // 設定ファイル(~/.config/kikigaki/config.toml)のパース用
        .package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.6.0"),
        // 話者判別(Sortformer)のためだけに使う。文字起こしは Apple SpeechTranscriber
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
    ],
    targets: [
        // ロジック層(Foundation + NaturalLanguage + TOMLKit。ユニットテストの主戦場)
        .target(
            name: "KikigakiCore",
            dependencies: ["TOMLKit"],
            path: "Sources/KikigakiCore"
        ),
        // 実行ターゲット(メニューバー常駐アプリ)。
        // FluidAudio・Speech・AVFoundation の非 Sendable な型を音声スレッドと MainActor の間で
        // 受け渡すため Swift 5 言語モードにする(Swift 6 モードでは実体のないコンパイルエラーが
        // 大量に出る。プロトも同じ設定で動作確認済み)。純粋ロジックは Core 側で Swift 6 モード
        .executableTarget(
            name: "Kikigaki",
            dependencies: [
                "KikigakiCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Kikigaki",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KikigakiAppTests",
            dependencies: ["Kikigaki", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/KikigakiAppTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KikigakiCoreTests",
            dependencies: [
                "KikigakiCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/KikigakiCoreTests"
        ),
    ]
)
