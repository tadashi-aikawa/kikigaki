import Foundation

/// 同梱Skillを利用者のSkill置き場へリンクする。
/// Homebrewの `postflight_steps` はHOMEを差し替えたsandboxで走り、`~/.claude` の読み取りも禁じるため、
/// Caskからは張れない。利用者が自分の権限で実行するこのコマンドを唯一の導入経路にする。
struct SkillCommand: Sendable {
    enum Action: String, Sendable { case install, uninstall }
    enum Outcome: Equatable, Sendable { case linked, relinked, unchanged, skipped, removed, absent }
    enum Failure: Error, Equatable { case arguments, bundledSkillNotFound }

    /// 同梱先を指すリンクだけを自分が張ったものとみなす。cloneしたリポジトリへのリンクや
    /// 利用者が置いた実体は、黙って奪うと編集中の変更が効かなくなるため触らない。
    static let bundledMarker = "KIKIGAKI.app/Contents/Resources/skills/kikigaki"
    static let homes = [".claude/skills/kikigaki", ".codex/skills/kikigaki"]

    let action: Action

    init(_ arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "skill", let action = Action(rawValue: arguments[1]) else { throw Failure.arguments }
        self.action = action
    }

    /// `Contents/Helpers/kikigaki-cli` から見た `Contents/Resources/skills/kikigaki`。
    static func bundledSkill(executable: URL) throws -> URL {
        let helpers = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let skill = helpers.deletingLastPathComponent().appending(path: "Resources/skills/kikigaki")
        guard helpers.lastPathComponent == "Helpers", skill.path.hasSuffix(bundledMarker),
              FileManager.default.fileExists(atPath: skill.appending(path: "SKILL.md").path) else { throw Failure.bundledSkillNotFound }
        return skill
    }

    func execute(home: URL, source: URL) throws -> [(path: String, outcome: Outcome)] {
        let files = FileManager.default
        return try Self.homes.map { relative in
            let target = home.appending(path: relative)
            // 切れたリンクも「ある」と扱うため、参照先を辿らないattributesOfItemで確かめる。
            let existing = (try? files.attributesOfItem(atPath: target.path)) != nil
            let destination = try? files.destinationOfSymbolicLink(atPath: target.path)
            let ours = destination?.contains(Self.bundledMarker) == true
            switch action {
            case .install:
                if destination == source.path { return ("~/" + relative, .unchanged) }
                if existing && !ours { return ("~/" + relative, .skipped) }
                if existing { try files.removeItem(at: target) }
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.createSymbolicLink(atPath: target.path, withDestinationPath: source.path)
                return ("~/" + relative, existing ? .relinked : .linked)
            case .uninstall:
                guard existing else { return ("~/" + relative, .absent) }
                guard ours else { return ("~/" + relative, .skipped) }
                try files.removeItem(at: target)
                return ("~/" + relative, .removed)
            }
        }
    }

    static func message(_ outcome: Outcome) -> String {
        switch outcome {
        case .linked: "リンクしました"
        case .relinked: "リンクを張り直しました"
        case .unchanged: "リンク済みです"
        case .skipped: "同梱Skill以外のファイルがあるため触りませんでした"
        case .removed: "リンクを外しました"
        case .absent: "ありません"
        }
    }
}
