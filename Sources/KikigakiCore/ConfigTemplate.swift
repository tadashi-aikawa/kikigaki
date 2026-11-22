import Foundation

/// メニューの「設定ファイルを開く」で、設定ファイルが無いときに書き出す雛形。
/// 項目はすべてコメントアウトし、そのまま読み込むとファイルが無いときと同じ既定の設定になる (テストで確かめる)。
/// 先頭のスキーマの行は docs/config.md の「エディタでの補完と検証」の書き方
public enum DefaultConfigTemplate {
    public static let text = """
        #:schema /Applications/KIKIGAKI.app/Contents/Resources/config.schema.json
        # KIKIGAKI の設定ファイル。どのキーも省略でき、省略したキーは既定値になる。
        # 書き換えたら、メニューバーのメニューの「設定を再読込」で読み直す。
        # 全キー: https://tadashi-aikawa.github.io/kikigaki/docs/configuration/

        # Markdown (と録音WAV) の保存先。既定: ~/Documents/KIKIGAKI
        # outputDir = "~/Documents/KIKIGAKI"
        # 録音WAVを Markdown と並べて残すか。既定: false
        # saveRecording = false
        # 話者名の候補に使う、議事録の先頭の参加者のキー。既定: participants
        # participantsKey = "participants"
        # 録音中に会議Markdownへ途中の記録を書く間隔(秒)。10〜3600。既定: 60
        # autoSaveIntervalSeconds = 60

        """
}

public enum ConfigFileError: LocalizedError, Equatable {
    case brokenSymlink(path: String)

    public var errorDescription: String? {
        switch self {
        case .brokenSymlink(let path):
            return "設定ファイルのシンボリックリンクのリンク先がありません: \(path)"
        }
    }
}

extension ConfigLoader {
    /// 設定ファイルがシンボリックリンクで、リンク先が無いか
    /// (dotfiles 管理などでリンクにしている場合、雛形で実体を作るとリンクを潰す)
    public static func isBrokenSymlink(_ url: URL) -> Bool {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeSymbolicLink
        else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    /// ファイルが無ければ親ディレクトリを作り雛形を書き出す。リンク切れのときは作らずにエラーにする
    public static func ensureFileExists(at url: URL) throws {
        if isBrokenSymlink(url) {
            throw ConfigFileError.brokenSymlink(path: url.path)
        }
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeTemplateWithoutOverwriting(at: url)
    }

    /// 雛形を新しいファイルとしてだけ置く。確かめてから書くまでに別のプロセスが作ったファイルやリンクを置き換えない。
    /// 同じディレクトリの一時ファイルへ書き切ってから link で置くので、途中までの雛形を残さない。失敗しても一時ファイルは消える。
    /// 既にあれば、できていたファイルをそのまま開けるよう成功として返す。リンク切れなら作らずにエラーにする
    static func writeTemplateWithoutOverwriting(at url: URL) throws {
        do {
            try PrivateFileIO.write(Data(DefaultConfigTemplate.text.utf8), to: url, replacing: false)
        } catch CocoaError.fileWriteFileExists {
            if isBrokenSymlink(url) {
                throw ConfigFileError.brokenSymlink(path: url.path)
            }
        }
    }
}
