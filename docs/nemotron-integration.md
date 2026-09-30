# Nemotron fast128 への話者判別の切替

話者判別を Sortformer High Context から Nemotron 3 Diarization の `fast128` へ一本化し、最大8話者にした。文字起こしは Apple の速報+高精度のまま。

試作の比較と実測は [experiments/nemotron/README.md](../experiments/nemotron/README.md) にある。

## 依存

```swift
// swift-tools-version: 6.2
.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4", traits: []),
```

- `traits: []` で FluidAudio の既定 trait `NemoTextProcessing` を外す
    - 理由: TTS と逆テキスト正規化専用の Rust 静的ライブラリで、話者判別は使わない
    - 0.15.6 でも同じバイナリ依存をリンクしていた。今回の変更で外れる
    - 確認: 組み立てた `.app` の実行ファイルに該当記号がない。0.15.6 版では29件あった
- FluidAudio でこのバイナリ依存を外すには tools 6.2 以上が要る。開発要件も Swift 6.2 以上にした
    - 理由: FluidAudio は trait を `Package@swift-6.2.swift` にだけ宣言し、6.2 未満の `Package.swift` では常にリンクする
- 空の `traits` で既定 trait が無効になることは SwiftPM の公式資料に記載がある[^traits]
- 0.15.6 をチェックアウト済みの作業ツリーで上げたとき、SwiftPM は「trait を宣言していない依存の既定 trait は外せない」と止まった
    - 一度 `traits: []` を外して `swift package resolve` し、戻すと通った
    - 未検証: クリーンな clone での解決と、リモートCIでの実行
- `FluidAudio_FluidAudio.bundle` は 0.15.6 から生成され、`make-app.sh` は同梱していない。TTS 以外は `Bundle.module` を触らないため扱いは変えない

[^traits]: [SwiftPM: Adding dependencies](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/Dependencies/AddingDependencies.md)

## モデル

- `DiarizationModels.config = Nemotron3Config.fast128`。chunk 10.24秒と右文脈0.32秒で、chunk の先頭から10.56秒ぶんの入力が溜まると判定が出る
    - 出た確率は後から変わらない。暫定の出力はない
- 取得先は `~/Library/Application Support/FluidAudio/Models/nemotron-3-diarization`。fast128 だけを取得し、約193MB
- 先読みと開始は `AppDelegate.loadModels` の1つの Task を共有する
    - 同じ置き場へ並行して取得すると `.partial` の移動で失敗する。実モデルのテストで観測した
- 旧 `sortformer` のモデルはアプリから消さない。README に場所だけ書いた

## 話者判別ラッパー

`SpeakerDiarizer` の口は `process` / `finish` / `segments` / `finalizedDuration`。エンジンの選択や抽象は置かない。

### 区間化

`KikigakiCore` の `SpeakerRuns` が、届いた確率を話者区間へ畳む。

- 持つのは閉じた区間と、話者ごとの開始フレーム8個だけ。確率は取り込んだ時点で読み捨てる
- 判定は `Nemotron3Diarizer.segments` と同じで、しきい値 `> 0.5`、最短長0。試作の比較条件と揃えた
- `segments(until:)` は発話中の区間を `min(判定済み末尾, 実音声長)` で切って足す。長さ0の区間は返さない
- 時刻は自分で数えたフレーム数から出す

### 失敗

最初の失敗でその会議の話者判別を止め、再開しない。

- 理由: FluidAudio の `runChunks` は入力位置を進めてから推論する。失敗した chunk を飛ばして続けると、以後の判定が chunk 単位で前へずれる。話者状態が部分的に更新されている可能性もある
- 取り込む前に、各 chunk の話者数・配列長と、取り込み後の合計フレーム数がエンジンの `streamedFrameCount` と一致するかを確かめる。食い違ったら何も取り込まずに失敗とする
- 失敗後
    - `process` はエンジンを呼ばず、音声も溜めない。投げるのは最初の1回だけで、ログも1回になる
    - `segments()` は失敗前に取り込んだ区間を返す。`finalizedDuration` はそこで止まり、`SpeakerFreeze` は未判定のトークンを固めない
    - `finish()` は保持した失敗を投げる。既存の `finalizationSucceeded = false` とログの経路に乗る
    - 失敗後の発言の話者は、Aligner の窓判定と補正次第になる。「?」になるとは限らない
- 利用者向けの表示は足していない

### 終了・短い会議・空入力

- `finish()` は `finishStream()` を1回だけ呼び、末尾の chunk を詰めて判定する。High Context で必要だった無音の補いは要らない
    - 判定済みの範囲は受け取った音声の長さを超えないので、保存する録音と会議時間は延長しない
- 0サンプルなら `finishStream` を呼ばない
- 10.56秒に満たない会議は、録音中は区間が出ず、停止時の `finish()` で全体が出る
- 区間は実音声の長さで切る。末尾の10ms切り上げで1フレーム余るため

### MainActor との受け渡し

- 消費タスクは `finalizedDuration` が進んだときだけ `segments()` を作る。描画の0.5秒間引きとは独立に、`consumedAudioTime` と同じ MainActor の更新で `receiveSpeakerState` へ渡す
- MainActor 側は受け取った区間を `speakerSegments` に持つ。停止後は最終区間で上書きする。録音開始で空に戻す
- AI送信の会話固定は `speakerSegments` を使い、話者判別のエンジンへ直接触れない
    - 区間と `processedUntil` が同じ時点の値になる。別々に読むと chunk 境界をまたいで結果が変わり得る
- 更新は preparation の世代で守り、前の会議の消費タスクから新しい会議へ書かない

## 8枠

- `SpeakerNames.letters` を A〜H にした。`slotCount` は8
- `receiveSpeakerState` の `0..<4` と人数表示の初期値を `slotCount` に寄せた
- 開始シートの文言を「区別する(最大8人)」にした
- 統合のポップオーバー・改名・`KIKIGAKI_DEBUG_AI_RENAME` はもともと `slotCount` を使っている
- E〜H の色は A〜D の4色の循環。人数表示の分母は全会議で8

## 保存互換

保存形式は変えていない。エンジン名や枠数のメタデータも足していない。

- `Utterance.speaker` と `SpeakerNames.names` は枠番号の整数。旧4人会議の0〜3はそのまま読める
- 既定名 `話者X` は保存せず、表示時に記号から作る
- 過去会議の話者判別をやり直す経路はない。統合の再計算は表示中の会議のメモリ上の区間だけを使う
- 旧版で8枠の会議を開くと、5枠目以降は `話者5` のような番号表示になり、統合の対象から外れる。落ちはしない

## SpeakerFreeze

録音中の話者の固定は、`judgedUntil` に Nemotron の判定済み末尾を渡す。モデルの確率が確定でも話者表示は後から変わり得るため、判定に読む入力が全て確定したフレーズを丸ごと凍結する。条件は [話者の割当と固定](speaker-assignment.md#録音中のフレーズ凍結) を参照する。

## 削除したもの

- `SortformerModelStore` と環境変数 `KIKIGAKI_SORTFORMER`
- High Context 用の末尾の無音補い
- Sortformer の確定区間と暫定区間の合成
- `SpeakerDiarizer.cleanup()` と3か所の呼び出し。Nemotron 3 に解放 API はない
- MainActor から `diarizer.segments()` を直接読む経路と `finalSegments`

## 検証

テスト・replay・GUIの検証は [Nemotron fast128 への切替の検証記録](records/nemotron-verification.md) に移した。
