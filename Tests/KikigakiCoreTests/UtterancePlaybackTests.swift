import Foundation
import Testing

@testable import KikigakiCore

/// 発言ごとの音声再生の区間。仕様は docs/utterance-playback.md
@Suite struct UtterancePlaybackTests {
    @Test func 行の区間を前後へ広げる() {
        let value = Utterance(speaker: 1, start: 731, end: 734.2, text: "来週までに見積もりを出します")
        #expect(UtterancePlayback.range(for: value) == 730.5...734.7)
    }

    @Test func 会議の頭の行は0秒から流す() {
        let value = Utterance(speaker: 0, start: 0.2, end: 1.5, text: "はい")
        #expect(UtterancePlayback.range(for: value) == 0...2.0)
    }

    @Test func 手入力は流さない() throws {
        let typed = try Utterance(typedText: "メモ", at: 12, postedAt: Date())
        #expect(!UtterancePlayback.isPlayable(typed))
        #expect(UtterancePlayback.range(for: typed) == nil)
    }

    @Test func 話者なしの声の行も流す() {
        let value = Utterance(speaker: nil, start: 10, end: 11, text: "えー")
        #expect(UtterancePlayback.isPlayable(value))
    }

    @Test func フレームはファイルの長さで切る() throws {
        // 16kHzで10秒のファイル。末尾の行は前後を広げると長さを越える
        let frames = try #require(UtterancePlayback.frames(for: 9.0...10.7, sampleRate: 16000, length: 160_000))
        #expect(frames.start == 144_000)
        #expect(frames.count == 16_000)
    }

    @Test func 元のファイルの標本化周波数でフレームへ直す() throws {
        // 音声ファイルの書き起こしは元のファイルを流す。44.1kHzでも秒の位置は同じになる
        let frames = try #require(UtterancePlayback.frames(for: 1.0...2.0, sampleRate: 44100, length: 441_000))
        #expect(frames.start == 44100)
        #expect(frames.count == 44100)
    }

    @Test func ファイルより後ろの区間は流さない() {
        #expect(UtterancePlayback.frames(for: 12...13, sampleRate: 16000, length: 160_000) == nil)
        #expect(UtterancePlayback.frames(for: 0...1, sampleRate: 16000, length: 0) == nil)
    }
}
