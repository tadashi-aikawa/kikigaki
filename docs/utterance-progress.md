# 発話が確定するまでの行ゲージ

## 決定事項

質問票 `q-20260913-144741-w9np1` の案2を採用する。アバター左に縦のゲージを置き、到達した段を塗り、現在段を朱、未到達を薄墨の輪郭で示す。点径8pt、中心間隔12pt。行高と本文色は変えない。各点のツールチップに段名を出し、話者固定には「停止時に全体を再判定します」を添える。

話者判別オンは暫定→速報の確定→高精度の確定→話者固定の4段。話者固定に到達した行のゲージは消す。オフは最初の3段だけとし、高精度の確定で消す。段は認識の正しさを保証しない。

## 観測源と導出

[発話フロー](utterance-flow.md)を土台に、`KikigakiCore` の `LiveTranscript.progress(accurateFinalCount:)` が表示専用の `UtteranceProgress` を返す。`Utterance` や保存形式には状態を足さない。

| 入力 | 観測源と用途 |
| --- | --- |
| tokens / finalCount | `TranscriptMerge.Snapshot` の合成トークンと通常行へ出すprefix |
| accurateFinalCount | 同じSnapshotの高精度確定prefix。必須引数で渡し、finalCountから推測しない |
| frozenCount | `SpeakerFreeze` が実際に凍結したラベル数。経過時間や話者番号から推測しない |
| speakers | 表示へ適用する話者対応。手動統合も反映した行境界を使う |
| diarizationEnabled | 会議開始時に決まる話者判別モード |

既存のLiveTranscript生成APIは維持する。高精度境界を持たない呼出元には段を暗黙に割り当てず、同じスナップショットから必須引数を渡す。LiveTranscriptは段の再導出に必要な行範囲と境界値を保持するため、等価比較にもこれらを含む。本文の変更点灯はこの比較で決めない。

通常行はfinalCount内だけから生成される。オンでは `Aligner.utteranceTokenRanges`、オフでは `UndiarizedTranscript.utteranceTokenRanges` を一度だけ計算し、その同じ範囲配列から通常行と段を組み立て、添字の一致を保証する。行の上端ではなく半開区間のupperBoundを確定境界と比較する。

| 条件 | 行の現在段 |
| --- | --- |
| upperBound > accurateFinalCount | 速報の確定 |
| 上記以外、オンかつupperBound > frozenCount | 高精度の確定 |
| 上記以外 | 最終段に到達。ゲージなし |

境界とupperBoundが等しい場合は行全体がそのprefix内にある。行内で高精度と速報、または凍結済みと未凍結が混在すれば最も未確定側を採用する。話者nilも凍結可能であり、話者が判明しただけでは固定にしない。高精度が先着すれば速報段は飛ばす。これは履歴を蓄積する状態機械ではなく現在の観測からの導出であり、文字置換や行の結合で添字や段が変わり得る。

防御的にfinalCountを0…tokens.count、凍結を0…finalCountへ制限して保持する。段の導出時は高精度を0…finalCount、凍結を0…高精度へ制限する。短い話者列は既存Alignerと同じく実在する行の範囲だけを使う。

`rows` はLiveTranscript.utterancesと同じ添字の配列で、nilはゲージなし。`tentative` は別に描かれる非空の暫定末尾の段で、通常行の添字へ混ぜない。`steps` はオン4段・オフ3段の説明と描画に使う。最終段はゲージを消すのでrowsには現れないが、未到達の点の説明には必要となる。

## 停止後と画面への接続

停止処理中は到達状況を表示し、MeetingSessionが最終結果をsnapshotへ代入する箇所でゲージ情報を空にする。LiveTranscriptに停止判定の引数は持たせず、この切替へ一本化する。停止時は既存どおり全体の話者を再判定する。保存済み会議の読込には進捗情報を持ち込まず、ゲージを出さない。

MeetingSessionの発話用スナップショットにaccurateFinalCountを引き継ぐ。オンのライブ更新とオフの結果通知の両方を接続し、`TranscriptEntries.merge` の手入力併合と同じ添字変換で行の段を渡す。手入力行にはゲージを出さない。SessionSnapshotの `utteranceProgress` は表示用の情報だけを保持し、停止結果への切替時にnilへ戻す。

オフの `AppleTranscriber.onResult` は保持済みの `TranscriptMerge.Snapshot` 全体を渡す。`publishUndiarized` はそのaccurateFinalCountも `SpeakerTranscript` に保持する。オンのpublish経路でも同じ値を保持し、手入力・一時停止・統合からの非publish経路の `refreshLive` は保持値を再利用する。改名によるemitでも保持済みの表示情報を使う。高精度境界を既定値0に戻して速報段へ落とさない。オフで高精度境界が進んだ通知は、表示用確定数が増えなくても即時に反映する。

「話者未確定」の薄い地と注記は別属性として維持する。小音量除外による薄表示にも独立してゲージを出す。ゲージだけの変化は `TranscriptRow.update` の点灯を起こさない。Markdown、archive、AI文脈、コピー範囲、保存JSON、文字起こし・凍結条件を変更しない。

話者判別オンの一時停止中は音声チャンクが来ずpublishLiveが走らないため、段の更新は再開まで止まる。オフは結果通知のpublishUndiarizedで一時停止中も反映する。

点は円形で、左余白12ptの中央のx=2…10ptへ置き、通常は行上端から6ptに揃える。行が短い場合だけ全段が収まる起点へ補正する。到達済みは中間調 `#918477`、現在段は朱 `#AA1405`、未到達は薄墨の40%の輪郭。和紙上の到達済みは約3.06:1、朱は約6.28:1で、現在と到達済みの輝度差も持つ。小音量除外は本文側の合成レイヤーだけを薄化し、ゲージを薄化しない。ツールチップとVoiceOverの値は「速報の確定(4段中2段目)」の形で段数を含め、VoiceOverの子要素は閉じる。

## 検証

`UtteranceProgressTests` で暫定→速報→高精度→固定、高精度先着、両確定境界の混在、手動統合、オフの3段と行分割、異常境界数、空入力、話者不明、短い話者列、ツールチップを検証する。全導出でrowsとutterancesの個数一致を検査する。`UtteranceProgressMergeTests` は手入力の併合、`UtteranceGaugeTests` は両話者モードでの再描画、停止後全消去、高精度置換の即時反映、段だけの更新と行高を検証する。

実寸撮影はDEBUGの `--utterance-gauge <出力先>` で行う。`UtteranceGaugeHarness` がCoreで導出した行と段を本番のTranscriptWindowへ渡し、600×740ptでcacheDisplayする。録音中5行、停止後、話者判別オフ、手入力と小音量除外を含む混雑画面を同じ題材のBEFORE付きで保存する。各画像の `-1x.png` は600×740pxの等倍確認用。

### 等倍replayの実測

入力は `2026-09-13_0028.wav` の52.556312秒、16kHz mono Float32。話者オン・オフを順番に実行し、どちらも終了コード0でMarkdownを保存した。検証先は `/private/tmp/kikigaki-row-gauge-replay/`。`on.log` と `off.log` に既存の本文traceと、画面へ渡した `utterance-progress` を記録した。再現用の設定は `on.toml` と `off.toml`、行開始位置ごとの初回観測は `on-summary.txt` と `off-summary.txt` にある。

| 観測 | 話者オン | 話者オフ |
| --- | --- | --- |
| 暫定末尾の初回 | 音声4.00秒 | 音声3.50秒 |
| 先頭発話の速報確定 | 8.00秒、開始0.72秒 | 7.50秒、開始0.72秒 |
| 先頭発話の高精度到達 | 24.00秒で高精度段、開始0.60秒 | 12.00秒でゲージ消去、開始0.60秒 |
| 話者固定で消去 | 34.00秒で開始0.60秒の行が非表示 | 話者段は持たない |
| 停止後 | 52.56秒、4行と暫定末尾すべて非表示 | 52.56秒、7行と暫定末尾すべて非表示 |

これは同じ発話内容の観測であり、高精度置換によって開始位置も変わる。さらにオンの開始30.90秒の行では、音声47.00秒の高精度段から49.00秒の速報段へ戻った。本文traceで、後続の速報が同じ話者の行へつながったことを確認した。確定prefixの後退ではなく、行の範囲が広がった結果であり、行内の最も未確定側へ寄せる規則に従う。行添字や開始位置を固定した単調な状態機械としては扱わない。

再現にはDEBUGビルドの `.build/KIKIGAKI.app/Contents/MacOS/KIKIGAKI` に `--config <on.tomlまたはoff.toml> --show-window --replay <入力WAV>` を渡す。環境変数は `KIKIGAKI_DEBUG_REPLAY_REALTIME=1`、`KIKIGAKI_DEBUG_DIARIZATION=on` または `off`、`KIKIGAKI_DEBUG_LIVE_TRACE=1`。等倍指定はFileSourceの0.5秒分の投入間隔を500msにし、指定なしの約10倍速は維持する。通常のマイク入力には影響しない。
