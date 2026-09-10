import Foundation
import KikigakiCore

/// 議事録のmanifest相当情報だけを扱う。本文には触れない。
/// アプリの単一MainActor storeから呼び、古い写しの保存は比較検証で拒否する。
public struct MinutesFileStore: Sendable {
    public let files: AIFileStore
    public let meetingID: UUID
    public var parts: [String] { [".kikigaki-context", meetingID.uuidString, "ai", "minutes.json"] }
    public init(root: URL, meetingID: UUID) { files = AIFileStore(root: root, allowsMissingParents: true); self.meetingID = meetingID }

    public func read() throws -> MinutesState {
        guard let bytes = try bytes() else { return MinutesState(meetingID: meetingID) }
        return try decode(bytes)
    }

    public func save(_ next: MinutesState, replacing previous: MinutesState) throws {
        try next.validate(); try previous.validate()
        guard next.meetingID == meetingID, previous.meetingID == meetingID,
              previous.revision < Int.max, next.revision == previous.revision + 1 else { throw AIError.mismatch }
        // revisionだけでなく内容も比較し、外部編集でrevisionが増えていない場合も潰さない。
        guard try read() == previous else { throw AIError.conflict }
        try files.write(AIJSON.encode(next), to: parts)
    }

    /// 人が明示的に指定したときだけ壊れた正本を退避する。
    /// 退避の排他公開とfsyncを終えてから置換し、失敗時も元のバイト列を失わない。
    public func repair(selecting path: String?, at date: Date) throws -> MinutesState {
        let previous = try bytes()
        if let previous, (try? decode(previous)) != nil { throw AIError.conflict }
        var next = MinutesState(meetingID: meetingID)
        try next.select(path, at: date); try next.advanceRevision()
        if let previous {
            let formatter = ISO8601DateFormatter()
            let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
            let backup = Array(parts.dropLast()) + ["minutes.json.broken-\(stamp)-\(UUID().uuidString)"]
            try files.write(previous, to: backup, replacing: false)
        }
        guard try bytes() == previous else { throw AIError.conflict }
        try files.write(AIJSON.encode(next), to: parts)
        return next
    }

    private func decode(_ bytes: Data) throws -> MinutesState {
        let state = try AIJSON.decode(MinutesState.self, from: bytes)
        guard state.meetingID == meetingID else { throw AIError.mismatch }
        return state
    }

    private func bytes() throws -> Data? {
        // 未使用の会議では親階層もまだ無い。リンクや権限不正を「無い」へ読み替えない。
        do { return try files.read(parts) }
        catch AIFileError.missing { return nil }
    }
}
