// swiftc Sources/KikigakiCore/{Transcript,WordBoundaries,SpeechTail,Aligner}.swift scripts/alignment-audit.swift -o /tmp/alignment-audit
// /tmp/alignment-audit <KIKIGAKI_DEBUG_PHRASESのログ>
import Foundation

@main struct AlignmentAudit {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "audit", code: 1, userInfo: [NSLocalizedDescriptionKey: "診断ログのパスを1つ指定してください"])
        }
        let log = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let segmentRE = try NSRegularExpression(pattern: #"\[segment\] (\d+) ([\d.]+)-([\d.]+)"#)
        let tokenRE = try NSRegularExpression(pattern: #"(.*?)\[(\?|\d+)→(\?|\d+) ([\d.]+)-([\d.]+)\]"#)
        var segments: [SpeakerSegment] = []
        var tokens: [TimedToken] = []
        var baseline: [Int?] = []
        var phraseID = 0
        func field(_ match: NSTextCheckingResult, _ group: Int, _ line: String) -> String {
            String(line[Range(match.range(at: group), in: line)!])
        }
        for line in log.components(separatedBy: .newlines) {
            if let m = segmentRE.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                segments.append(.init(speaker: Int(field(m, 1, line))!, start: Double(field(m, 2, line))!, end: Double(field(m, 3, line))!))
            }
            guard let header = line.range(of: "[phrase id="),
                  let end = line[header.upperBound...].range(of: "] ") else { continue }
            let text = String(line[end.upperBound...])
            // ログには元phraseIdを含むが、phraseRangesは句点・無音で再分割するため同じ値を保持する。
            phraseID = Int(line[header.upperBound..<end.lowerBound])!
            let matches = tokenRE.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard !matches.isEmpty else { throw NSError(domain: "audit", code: 2) }
            for (index, m) in matches.enumerated() {
                var piece = field(m, 1, text)
                if index > 0, piece.first == " " { piece.removeFirst() }
                tokens.append(.init(text: piece, phraseId: phraseID, start: Double(field(m, 4, text))!, end: Double(field(m, 5, text))!))
                baseline.append(Int(field(m, 3, text)))
            }
        }
        guard !tokens.isEmpty, !segments.isEmpty else { throw NSError(domain: "audit", code: 3) }
        let updated = Aligner.speakers(for: tokens, segments: segments)
        let old = Aligner.utterances(tokens: tokens, speakers: baseline)
        let new = Aligner.utterances(tokens: tokens, speakers: updated)
        print("tokens=\(tokens.count) segments=\(segments.count) lines=\(old.count)→\(new.count) unknown=\(old.filter { $0.speaker == nil }.count)→\(new.filter { $0.speaker == nil }.count)")
        for i in tokens.indices where baseline[i] != updated[i] {
            print(String(format: "%.2f-%.2f", tokens[i].start, tokens[i].end),
                  "\(baseline[i].map(String.init) ?? "?")→\(updated[i].map(String.init) ?? "?")", tokens[i].text)
        }
        print("--- utterances ---")
        for u in new {
            print(String(format: "%.2f-%.2f", u.start, u.end), u.speaker.map(String.init) ?? "?", u.text)
        }
    }
}
