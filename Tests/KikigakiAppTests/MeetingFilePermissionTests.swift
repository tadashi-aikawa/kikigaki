import AppKit
import AVFoundation
import Foundation
import KikigakiCore
import Testing
@testable import Kikigaki

@Suite struct MeetingFilePermissionTests {
    private func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }
    @Test func WAVは作成直後から0600で閉じた後も音声が読める() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try PrivateFileIO.createDirectory(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recording.wav")
        let writer = try WavWriter(url: url)
        #expect(try mode(url) == 0o600)
        try writer.write([Float](repeating: 0.1, count: 1600))
        writer.close()
        #expect(try mode(url) == 0o600)
        #expect(try AVAudioFile(forReading: url).length == 1600)
        #expect(throws: (any Error).self) { try WavWriter(url: url) }
        #expect(try AVAudioFile(forReading: url).length == 1600)
    }

    @Test func 添付は0700のフォルダと0600の画像で既存フォルダは変更しない() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try PrivateFileIO.createDirectory(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = root.appendingPathComponent("meeting.md")
        let image = try TypedImageDraft(data: AvatarStoreTests.png)
        let path = try #require(TypedImageDraft.save([image], beside: markdown).first)
        let file = URL(fileURLWithPath: path), directory = file.deletingLastPathComponent()
        #expect(try mode(directory) == 0o700)
        #expect(try mode(file) == 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let next = try #require(TypedImageDraft.save([image], beside: markdown).first)
        #expect(try mode(directory) == 0o755)
        #expect(try mode(URL(fileURLWithPath: next)) == 0o600)
    }
}
