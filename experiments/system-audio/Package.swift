// swift-tools-version: 6.0
import PackageDescription
import Foundation

let package = Package(
    name: "SystemAudioProbe",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(
        name: "SystemAudioProbe",
        linkerSettings: [.unsafeFlags([
            "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
            "-Xlinker", URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist").path,
        ])]
    )],
    swiftLanguageModes: [.v5]
)
