import Foundation

/// 議事録がObsidianのVault内にあるかを判定し、本文のwikilinkをObsidianで開くURIを組む。
///
/// Vaultの目印は `.obsidian` ディレクトリ1つだけにする。Obsidianが実際に開いているVaultの一覧は
/// アプリ外から確実には読めないため、ここでは「隣に設定ディレクトリがあるか」だけで判断する。
/// 判定できないときはリンクにしない (押せない顔をさせる) 方針なので、誤検出より取りこぼしを選ぶ。
enum MinutesVault {
    /// 議事録の親から上へ `.obsidian` を探し、最も近いディレクトリのbasenameをVault名として返す。
    /// Vault外・判定できない場合はnil。シンボリックリンクは追わない (`standardizedFileURL` は
    /// `..` の畳み込みだけを行い、リンク先へは移らない)。リンクで作った偽のVaultを辿って
    /// 無関係な場所を開かないため、`.obsidian` 自身がリンクの場合も採らない。
    static func name(forFile file: URL) -> String? {
        var directory = file.deletingLastPathComponent().standardizedFileURL
        while true {
            if isVaultRoot(directory) {
                let name = directory.lastPathComponent
                return name.isEmpty || name == "/" ? nil : name
            }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
    }
    private static func isVaultRoot(_ directory: URL) -> Bool {
        let marker = directory.appendingPathComponent(".obsidian")
        guard let values = try? marker.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
    /// `[[ノート]]` や `[[ノート#見出し]]` の宛先からObsidianのURIを組む。
    ///
    /// 公式ヘルプ (Obsidian URI) の通り、`file` はファイル名でもVaultルートからのパスでもよく、
    /// `Note%23Heading` のように符号化すれば見出しやブロックへも移動できる。`/` や空白も含めて
    /// 予約文字は必ず符号化するよう求めているため、`URLComponents` の緩い query 規則に任せず
    /// unreserved 以外をすべて自前で符号化する (queryItemsは `/` を素通しし、パスが壊れる)。
    static func openURL(vault: String, target: String) -> URL? {
        let note = noteReference(target)
        // 文書内アンカー `[[#見出し]]` はプレビュー内で移動する。Obsidianへは渡さない。
        guard !vault.isEmpty, !note.isEmpty, !note.hasPrefix("#") else { return nil }
        guard let vaultValue = encode(vault), let fileValue = encode(note) else { return nil }
        return URL(string: "obsidian://open?vault=" + vaultValue + "&file=" + fileValue)
    }
    /// 末尾の `.md` だけを落とす。`#見出し` や `#^ブロック` はObsidianが解釈するのでそのまま残す。
    static func noteReference(_ target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard let hash = trimmed.firstIndex(of: "#") else { return dropMarkdownExtension(trimmed) }
        let note = dropMarkdownExtension(String(trimmed[trimmed.startIndex..<hash]))
        return note + trimmed[hash...]
    }
    private static func dropMarkdownExtension(_ value: String) -> String {
        value.lowercased().hasSuffix(".md") ? String(value.dropLast(3)) : value
    }
    private static func encode(_ value: String) -> String? {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        // `CharacterSet.alphanumerics` は日本語も素通しするため、ASCIIのunreservedだけを許す。
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved)
    }
}
