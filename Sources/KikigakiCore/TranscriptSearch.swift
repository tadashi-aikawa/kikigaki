import Foundation

/// 表示文字列の位置を返す。大小・全半角だけを同一視し、かな種や漢字への変換はしない。
public enum TranscriptSearch {
    public static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: query, options: [.caseInsensitive, .widthInsensitive], range: start..<text.endIndex) {
            guard !range.isEmpty else { break }
            result.append(range)
            start = range.upperBound
        }
        return result
    }
}
