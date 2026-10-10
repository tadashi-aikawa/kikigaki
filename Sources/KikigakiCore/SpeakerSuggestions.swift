import Foundation

/// 名前の出どころと検索を共有する。永続的な履歴は持たず、開くたびに会議ファイルから導く。
public enum SpeakerSuggestions {
    public struct Candidate: Equatable, Sendable {
        public let name: String
        public let isParticipant: Bool
        public let avatar: String?
        public let usedBySlot: Int?
        public var isSelectable: Bool { usedBySlot == nil }
    }

    public static func participants(at url: URL?, key: String = ResolvedConfig.defaultParticipantsKey) -> [String] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return participants(in: text, key: key)
    }

    /// frontmatterの文字列リストだけを読む。YAMLのオブジェクト・タグ・アンカーは名前にしない。
    /// キーは行頭の完全一致で探す。入れ子のキーと引用符付きのキーは読まない。
    public static func participants(in markdown: String, key name: String = ResolvedConfig.defaultParticipantsKey) -> [String] {
        let label = name + ":"
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else { return [] }
        let header = Array(lines[1..<end])
        guard let key = header.firstIndex(where: { $0.hasPrefix(label) }) else { return [] }
        let value = String(header[key].dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        var raw: [String] = []
        if value.hasPrefix("[") {
            let flow = ([value] + Array(header.dropFirst(key + 1))).joined(separator: "\n")
            guard let values = flowValues(flow) else { return [] }
            raw = values
        } else {
            guard value.isEmpty || value.hasPrefix("#") else { return [] }
            for line in header.dropFirst(key + 1) {
                let item = line.trimmingCharacters(in: .whitespaces)
                if item.isEmpty || item.hasPrefix("#") { continue }
                guard item.hasPrefix("- ") || item == "-" else { break }
                raw.append(String(item.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
        }
        var seen = Set<String>()
        var result: [String] = []
        for item in raw {
            guard let name = scalar(item) else { return [] }
            if !name.isEmpty, seen.insert(name).inserted { result.append(name) }
        }
        return result
    }

    /// 直近30会議の先頭だけを読む。ファイルの更新時刻は改名で変わるので会議名の日時順を使う。
    public static func frequentNames(in directory: URL?, excluding current: URL?) -> [String] {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let pattern = #"^\d{4}-\d{2}-\d{2}_\d{4}(?:_([2-9]|[1-9]\d+))?\.md$"#
        let meetings = files.filter {
            $0.standardizedFileURL != current?.standardizedFileURL
                && $0.lastPathComponent.range(of: pattern, options: .regularExpression) != nil
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { left, right in
            let lhs = left.deletingPathExtension().lastPathComponent
            let rhs = right.deletingPathExtension().lastPathComponent
            if lhs.prefix(15) != rhs.prefix(15) { return lhs.prefix(15) > rhs.prefix(15) }
            return (Int(lhs.dropFirst(16)) ?? 1) > (Int(rhs.dropFirst(16)) ?? 1)
        }
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var meetingCount = 0
        for url in meetings {
            guard meetingCount < 30 else { break }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let data = try? handle.read(upToCount: 64 * 1024)
            try? handle.close()
            guard let data else { continue }
            let header = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            guard header.first?.hasPrefix("# KIKIGAKI ") == true else { continue }
            let metadata = header.prefix(while: { !$0.hasPrefix("## ") })
            if let line = metadata.first(where: { $0.hasPrefix("- 話者: ") }) {
                for name in names(inSpeakerLine: line) {
                    counts[name, default: 0] += 1
                    if firstSeen[name] == nil { firstSeen[name] = meetingCount }
                }
            }
            meetingCount += 1
        }
        return counts.keys.sorted {
            if counts[$0] != counts[$1] { return counts[$0, default: 0] > counts[$1, default: 0] }
            if firstSeen[$0] != firstSeen[$1] { return firstSeen[$0, default: 0] < firstSeen[$1, default: 0] }
            return $0 < $1
        }
    }

    public static func names(inSpeakerLine line: String) -> Set<String> {
        let text = String(line.hasPrefix("- 話者: ") ? line.dropFirst("- 話者: ".count) : line[...])
        let regex = try! NSRegularExpression(pattern: #"(?:^|, )([A-H]|[1-9][0-9]*)="#)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let source = text as NSString
        let knownDefaults = (0..<SpeakerNames.slotCount).map { SpeakerNames.defaultName(for: $0) }
        var result = Set<String>()
        for (index, match) in matches.enumerated() {
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : source.length
            let name = source.substring(with: NSRange(location: start, length: end - start))
            let number = name.hasPrefix("話者") ? Int(name.dropFirst(2)) : nil
            let isDefault = knownDefaults.contains(name) || number.map {
                $0 > SpeakerNames.slotCount && name == SpeakerNames.defaultName(for: $0 - 1)
            } == true
            if !name.isEmpty && !isDefault { result.insert(name) }
        }
        return result
    }

    public static func candidates(participants: [String], frequent: [String], speakers: [KikigakiConfig.Speaker],
                                  names: SpeakerNames, excluding slot: Int) -> [Candidate] {
        var rank: [String: Int] = [:]
        for (index, name) in frequent.enumerated() where rank[name] == nil { rank[name] = index }
        let sortedParticipants = participants.enumerated().sorted {
            let lhs = rank[$0.element] ?? Int.max, rhs = rank[$1.element] ?? Int.max
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
        let participantSet = Set(participants)
        var avatars: [String: String] = [:]
        for speaker in speakers { avatars[speaker.name] = speaker.avatar }
        let used = (0..<SpeakerNames.slotCount).filter { $0 != slot }.compactMap { names.customName(for: $0) }
        var seen = Set<String>()
        let all = (sortedParticipants + frequent + speakers.map(\.name) + used).compactMap { name -> Candidate? in
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return Candidate(name: name, isParticipant: participantSet.contains(name), avatar: avatars[name],
                             usedBySlot: names.otherSlot(using: name, excluding: slot))
        }
        return all.filter(\.isSelectable) + all.filter { !$0.isSelectable }
    }

    public static func filtered(_ candidates: [Candidate], query: String) -> [Candidate] {
        guard !query.isEmpty else { return candidates }
        let matches = candidates.compactMap { candidate -> (Candidate, Bool)? in
            guard let range = candidate.name.range(of: query, options: .caseInsensitive) else { return nil }
            return (candidate, range.lowerBound == candidate.name.startIndex)
        }
        return matches.filter { $0.1 }.map(\.0) + matches.filter { !$0.1 }.map(\.0)
    }

    /// 完全一致は大小文字も含めた一致。絞り込みの大小無視とは分ける。
    public static func exactMatch(in candidates: [Candidate], query: String) -> Candidate? {
        candidates.first { $0.isSelectable && $0.name == query }
    }

    public static func matchRanges(in name: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        var ranges: [NSRange] = []
        var start = name.startIndex
        while start < name.endIndex, let match = name.range(of: query, options: .caseInsensitive, range: start..<name.endIndex) {
            ranges.append(NSRange(match, in: name)); start = match.upperBound
        }
        return ranges
    }

    private static func scalar(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\"") {
            guard let end = quotedEnd(value, quote: "\"") else { return nil }
            let tail = value[end...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard tail.isEmpty || tail.hasPrefix("#") else { return nil }
            return doubleQuoted(String(value[value.index(after: value.startIndex)..<value.index(before: end)]))
        }
        if value.hasPrefix("'") {
            guard let end = quotedEnd(value, quote: "'") else { return nil }
            let tail = value[end...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard tail.isEmpty || tail.hasPrefix("#") else { return nil }
            return String(value[value.index(after: value.startIndex)..<value.index(before: end)])
                .replacingOccurrences(of: "''", with: "'")
        }
        guard !value.hasPrefix("[") && !value.hasPrefix("{") && !value.hasPrefix("&")
            && !value.hasPrefix("*") && !value.hasPrefix("!") && !value.hasPrefix("|") && !value.hasPrefix(">")
            && !value.contains(": ") else { return nil }
        let end = value.range(of: #"\s+#"#, options: .regularExpression)?.lowerBound ?? value.endIndex
        let plain = String(value[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.hasPrefix("#") || ["null", "Null", "NULL", "~"].contains(plain) ? "" : plain
    }

    private static func doubleQuoted(_ text: String) -> String? {
        let escapes: [Character: String] = ["0": "\0", "a": "\u{7}", "b": "\u{8}", "t": "\t", "n": "\n",
            "v": "\u{B}", "f": "\u{C}", "r": "\r", "e": "\u{1B}", " ": " ", "\"": "\"", "/": "/", "\\": "\\",
            "N": "\u{85}", "_": "\u{A0}", "L": "\u{2028}", "P": "\u{2029}"]
        var result = "", index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]; index = text.index(after: index)
            if ch == "\n" {
                result += " "
                while index < text.endIndex && text[index].isWhitespace { index = text.index(after: index) }
                continue
            }
            guard ch == "\\" else { result.append(ch); continue }
            guard index < text.endIndex else { return nil }
            let escape = text[index]; index = text.index(after: index)
            if let decoded = escapes[escape] { result += decoded }
            else if let digits = [Character("x"): 2, "u": 4, "U": 8][escape] {
                guard let end = text.index(index, offsetBy: digits, limitedBy: text.endIndex),
                      let code = UInt32(text[index..<end], radix: 16), let scalar = UnicodeScalar(code) else { return nil }
                result.unicodeScalars.append(scalar); index = end
            } else if escape == "\n" {
                while index < text.endIndex && text[index].isWhitespace { index = text.index(after: index) }
            } else { return nil }
        }
        return result
    }

    private static func quotedEnd(_ text: String, quote: Character) -> String.Index? {
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let ch = text[index]; index = text.index(after: index)
            if ch == "\\" && quote == "\"" {
                guard index < text.endIndex else { return nil }
                index = text.index(after: index)
            } else if ch == quote {
                if quote == "'", index < text.endIndex, text[index] == "'" { index = text.index(after: index) }
                else { return index }
            }
        }
        return nil
    }

    private static func flowValues(_ text: String) -> [String]? {
        var index = text.index(after: text.startIndex)
        var raw = ""
        var values: [String] = []
        while index < text.endIndex {
            let ch = text[index]
            if (ch == "\"" || ch == "'") && raw.allSatisfy(\.isWhitespace) {
                let tail = String(text[index...])
                guard let end = quotedEnd(tail, quote: ch) else { return nil }
                raw += tail[..<end]
                index = text.index(index, offsetBy: tail.distance(from: tail.startIndex, to: end))
                continue
            }
            if ch == "#" && (raw.isEmpty || raw.last?.isWhitespace == true) {
                while index < text.endIndex && text[index] != "\n" { index = text.index(after: index) }
                raw += " "
                continue
            }
            if ch == "," || ch == "]" {
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { values.append(value) }
                if ch == "]" { return values }
                raw = ""
            } else { raw.append(ch) }
            index = text.index(after: index)
        }
        return nil
    }
}
