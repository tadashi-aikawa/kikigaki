// swift-tools-version: 6.2
import PackageDescription
import Foundation

let package = Package(
    name: "ScreenCaptureProbe",
    platforms: [.macOS("26.0")],
    dependencies: [
        // UTSUSHIEと同じSDWebImage管理のBSD-3-Clauseパッケージ。Cソースから静的に同梱する。
        // 本体へ入れたときにビルドとmake-app.shへ収まるかを、この試作で先に確かめる。
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", exact: "1.6.0"),
    ],
    targets: [.executableTarget(
        name: "ScreenCaptureProbe",
        dependencies: [.product(name: "libwebp", package: "libwebp-Xcode")],
        swiftSettings: [.swiftLanguageMode(.v5)],
        linkerSettings: [.unsafeFlags([
            "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
            "-Xlinker", URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist").path,
        ])]
    )]
)
