import Foundation

/// 議事録プレビューの更新強調の基準を、いつ置き直すかだけを決める。
/// AIの1依頼の中の編集を1箇所ずつ消さずに残すため、依頼の送信とその依頼の編集開始で置き直す。
/// 強調そのものと本文の比較は表示側が持ち、この型は保存もUIも持たない。
public struct MinutesHighlightBaseline: Equatable, Sendable {
    /// 基準を置き直した回数。表示側はこの値の変化だけを見る。
    public private(set) var revision = 0
    private var sent: Set<UUID> = []
    private var editing: Set<UUID> = []

    public init() {}

    /// このアプリがCLIへ渡した時点。宛先を問わず、依頼1つにつき1回だけ置き直す。
    public mutating func didSend(_ requestID: UUID) {
        if sent.insert(requestID).inserted { revision += 1 }
    }

    /// `progress --editing` の観測。送信より後に人が触った分を混ぜないよう、編集の直前で置き直す。
    /// 自分が送った依頼だけを見る。過去会議の回収で読んだ古い申告では置き直さない。
    public mutating func observe(_ reports: [UUID: AIProgressReport]) {
        for (id, report) in reports where report.isEditing && sent.contains(id) {
            if editing.insert(id).inserted { revision += 1 }
        }
    }
}
