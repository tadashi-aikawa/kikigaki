import Foundation

/// 書き起こしウィンドウの会話を、選んだ相手の行だけに絞る。
/// 表示専用で、保存するMarkdown・コピー・AIへ渡す会話は変えない。AppKit型は持たず、
/// どの行を出し、どの行を「ほかの発言N件」の線へ畳むかだけを決める。
public enum TranscriptFilter {
    /// 絞り込める相手。
    public enum Subject: Hashable, Sendable {
        /// 声の行の話者枡。nilはどの話者区間にも当たらなかった行と、話者判別なしの「発言」。
        case speaker(Int?)
        case typed
        /// AIの宛先名。その宛先への送信の行と返事の行の両方が属する。
        case ai(String)
    }

    /// 出す行と畳む区間。添字は `layout` へ渡した行の並びのもの。
    public enum Entry: Equatable, Sendable {
        case row(Int)
        /// 畳んだ行の連なり。`rows` は畳んだ全行、`count` は線に出す件数で、相手のいない行は数えない。
        case gap(rows: [Int], count: Int)
    }

    public static func subject(for utterance: Utterance) -> Subject {
        utterance.kind == .typed ? .typed : .speaker(utterance.speaker)
    }

    public static func name(for subject: Subject, names: SpeakerNames) -> String {
        switch subject {
        case let .speaker(slot): return names.name(for: slot)
        case .typed: return "手入力"
        case let .ai(name): return name
        }
    }

    /// 選べる相手を、話者枡の順 → 話者なし → 手入力 → AIの宛先の初出順で返す。
    /// 選択中なのに会話から消えた相手 (統合された枡など) も、外せるよう末尾に残す。
    public static func subjects(utterances: [Utterance], aiNames: [String], selected: Set<Subject> = []) -> [Subject] {
        var result = Set(utterances.filter { $0.kind == .voice }.compactMap(\.speaker)).sorted().map { Subject.speaker($0) }
        if utterances.contains(where: { $0.kind == .voice && $0.speaker == nil }) { result.append(.speaker(nil)) }
        if utterances.contains(where: { $0.kind == .typed }) { result.append(.typed) }
        var seen = Set<String>()
        for name in aiNames where seen.insert(name).inserted { result.append(.ai(name)) }
        let present = Set(result)
        result += selected.filter { !present.contains($0) }.sorted(by: order)
        return result
    }

    /// - subjects: 各行の相手。nilは誰にも属さない行 (マイクの切替など) で、選んだ相手の行とはみなさない。
    /// - keys: 各行の同一性。開いた区間を更新をまたいで覚えるのに使う。
    /// - expanded: 線を押して開いた行。選んでいなくても出す。
    /// 何も選んでいなければ全行を出す。件数が0の区間は線を出さずに畳む。
    public static func layout<Key: Hashable>(subjects: [Subject?], keys: [Key], selected: Set<Subject>,
                                             expanded: Set<Key>) -> [Entry] {
        precondition(subjects.count == keys.count)
        guard !selected.isEmpty else { return subjects.indices.map { .row($0) } }
        var result: [Entry] = []
        var hidden: [Int] = []
        var count = 0
        func close() {
            if count > 0 { result.append(.gap(rows: hidden, count: count)) }
            hidden = []; count = 0
        }
        for index in subjects.indices {
            if expanded.contains(keys[index]) || subjects[index].map(selected.contains) == true {
                close()
                result.append(.row(index))
            } else {
                hidden.append(index)
                if subjects[index] != nil { count += 1 }
            }
        }
        close()
        return result
    }

    private static func order(_ left: Subject, _ right: Subject) -> Bool {
        func rank(_ subject: Subject) -> (Int, Int, String) {
            switch subject {
            case let .speaker(slot?): return (0, slot, "")
            case .speaker(nil): return (1, 0, "")
            case .typed: return (2, 0, "")
            case let .ai(name): return (3, 0, name)
            }
        }
        return rank(left) < rank(right)
    }
}
