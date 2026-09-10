import Foundation
import KikigakiCore
import KikigakiAIIO

/// アプリ寿命の辞書。AIを使い始める前の人の指定も、回収controllerも同じstoreを使う。
@MainActor final class MinutesStores {
    private var stores: [UUID: MinutesStore] = [:]
    func store(meetingID: UUID, markdownURL: URL) throws -> MinutesStore {
        if let existing = stores[meetingID] {
            guard existing.markdownURL == markdownURL else { throw AIError.mismatch }
            return existing
        }
        let value = MinutesStore(meetingID: meetingID, outputDirectory: markdownURL.deletingLastPathComponent(), markdownURL: markdownURL)
        stores[meetingID] = value
        return value
    }
    func discard(_ meetingID: UUID) { stores[meetingID] = nil }
}

/// 人の指定と通知回収をawaitなしで直列化し、永続化できた状態だけを公開する。
/// UIに参照を渡す入口はMinutesStores。controllerに別の状態の写しを持たせない。
@MainActor final class MinutesStore {
    let meetingID: UUID
    let markdownURL: URL?
    private let storage: MinutesFileStore
    private(set) var state: MinutesState
    private(set) var warning: String?
    private(set) var hasPendingEvents = false
    private(set) var hasSaveFailure = false
    private(set) var hasUnseenMinutes = false
    var isVisible = false {
        didSet { if isVisible { hasUnseenMinutes = false } }
    }
    var onChange: (() -> Void)?
    private var pendingSelection: (path: String?, date: Date)?
    var needsRecovery: Bool { hasPendingEvents }
    /// 保存直前に競合を再現する検証用の注入点。通常の更新には処理を挟まない。
    var beforeSave: (() throws -> Void)?
    private struct Change: Equatable {
        let state: MinutesState
        let warning: String?
        let pending: Bool
        let failed: Bool
        let unseen: Bool
    }
    private var change: Change { .init(state: state, warning: warning, pending: hasPendingEvents, failed: hasSaveFailure, unseen: hasUnseenMinutes) }
    private func notify(after previous: Change) {
        if previous != change { onChange?() }
    }

    init(meetingID: UUID, outputDirectory: URL, markdownURL: URL? = nil) {
        self.meetingID = meetingID; self.markdownURL = markdownURL
        storage = MinutesFileStore(root: outputDirectory, meetingID: meetingID)
        state = MinutesState(meetingID: meetingID)
        do {
            let saved = try storage.read()
            try validatePaths(in: saved)
            state = saved
        }
        catch { warning = "議事録の設定を読めません。パスを指定し直すと退避して再作成します"; hasSaveFailure = true }
    }

    func validateTarget(_ path: String) throws {
        try MinutesPath.validate(path)
        if let markdownURL {
            let raw = markdownURL.deletingPathExtension().appendingPathExtension("raw.md")
            guard path != markdownURL.path, path != raw.path else { throw AIError.invalid("meeting markdown") }
        }
    }

    private func validatePaths(in value: MinutesState) throws {
        if let path = value.minutesPath { try validateTarget(path) }
        if let path = value.humanMinutesPath { try validateTarget(path) }
    }

    func select(_ path: String?, at date: Date = Date()) throws {
        if let path { try validateTarget(path) }
        guard date.timeIntervalSince1970.isFinite else { throw AIError.invalid("minutes date") }
        let previous = change
        defer { notify(after: previous) }
        pendingSelection = (path, date)
        do {
            // 壊れた正本の修復はこの明示操作だけ。通知からは呼ばない。
            if (try? storage.read()) == nil {
                state = try storage.repair(selecting: path, at: date)
            } else {
                _ = try update { try $0.select(path, at: date) }
            }
            pendingSelection = nil; hasSaveFailure = false; warning = nil; hasUnseenMinutes = false
        } catch {
            hasSaveFailure = true; warning = "議事録の設定を保存できません。再試行できます"
            throw error
        }
    }

    func retrySelection() {
        if let pendingSelection { try? select(pendingSelection.path, at: Date()) }
    }

    /// 既知の送信済みrequestだけを読む。resultより後に来ても会話の状態は変更しない。
    func scan(questions: [AIQuestion]) {
        let previous = change
        defer { notify(after: previous) }
        hasPendingEvents = false
        // 正本を読めない会議は回収登録に残さない。明示修復後に到達点から再評価する。
        guard let saved = try? storage.read(), (try? validatePaths(in: saved)) != nil else {
            hasSaveFailure = true
            warning = "議事録の設定を読めません。パスを指定し直すと退避して再作成します"
            return
        }
        var events: [(AIMinutesEvent, AIRequest)] = []
        for question in questions where question.sendAttemptedAt != nil {
            let request = question.request, name = question.request.id.uuidString + ".minutes.json"
            do {
                try request.envelope.validatePaths(outputDirectory: storage.files.root)
                let bytes = try storage.files.read(Array(storage.parts.dropLast()) + ["inbox", name], limit: AILimits.eventBytes)
                let event = try AIInbox.decodeMinutes(bytes, filename: name, for: request)
                events.append((event, request))
            } catch AIFileError.missing { continue }
            catch { hasPendingEvents = true; warning = "受信箱の議事録通知を検証できません" }
        }
        events.sort { $0.0.position < $1.0.position }
        do {
            var rejected = false
            let changed = try update { next in
                rejected = false
                for (event, request) in events {
                    // アプリだけが知る管理ファイルへの通知は、到達点だけを進める。
                    let allowed = (try? self.validateTarget(event.minutesPath)) != nil
                    let applied = try next.receive(event, for: request, changeTarget: allowed)
                    rejected = rejected || (applied && !allowed)
                }
            }
            if changed, state.targetSource == .ai, !isVisible { hasUnseenMinutes = true }
            if pendingSelection == nil { hasSaveFailure = false }
            if !needsRecovery && pendingSelection == nil { warning = rejected ? "会議の管理ファイルへの議事録通知を無視しました" : nil }
        } catch {
            hasPendingEvents = hasPendingEvents || !events.isEmpty
            hasSaveFailure = true
            warning = "議事録の設定を保存・復元できません。通知は受信箱に残っています"
        }
    }

    /// 保存直前の比較に失敗したら最新の正本へ操作を再適用する。
    /// 更新主体の直列化はMainActorで担い、別アプリプロセスとの排他は保証しない。
    @discardableResult
    private func update(_ operation: (inout MinutesState) throws -> Void) throws -> Bool {
        for _ in 0..<3 {
            let previous = try storage.read()
            var next = previous
            try operation(&next)
            try validatePaths(in: next)
            guard next != previous else {
                // 前回の置換後に親fsyncだけ失敗した場合も、耐久化を確認してから回収済みにする。
                if hasSaveFailure, previous.revision > 0 { try storage.files.syncDirectory(Array(storage.parts.dropLast())) }
                state = previous; return false
            }
            try next.advanceRevision()
            do {
                try beforeSave?()
                try storage.save(next, replacing: previous)
                let targetChanged = next.minutesPath != previous.minutesPath || next.targetChangedAt != previous.targetChangedAt
                state = next
                return targetChanged
            } catch AIError.conflict { continue }
        }
        throw AIError.conflict
    }
}
