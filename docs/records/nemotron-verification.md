# Nemotron fast128 への切替の検証記録

2026-09-26 の切替時の検証の記録。現行の仕様ではない。現行の実装は [Nemotron fast128 への話者判別の切替](../nemotron-integration.md) を参照する。

## テスト

- `SpeakerRunsTests`: 重なり、分割しても一括と同じ結果、末尾の切り上げと長さ0、食い違った出力を取り込まないこと
- `SpeakerNamesTests`: E〜H、9枠目以降の番号、旧4人会議の archive、枠7の往復
- `DiarizationTests`: E〜H の検出・改名・統合、8枠のポップオーバー
- `SpeakerDiarizerTests`: 実モデルで0・1600・48000・168960・170000サンプル。`KIKIGAKI_TEST_DIARIZATION=1` のときだけ走る

## replay

保存先は素材ごとに分け、AIは設定しない。`KIKIGAKI_DEBUG_DIARIZATION=on KIKIGAKI_DEBUG_PHRASES=1` で流し、`[segment]` 行を試作の fast128 の区間と小数3桁で比べた。

| 素材 | 結果 |
|---|---|
| 公開 kpjud 140.5秒 | 27区間が一致。枠0〜7すべてが出る |
| 4人パネル冒頭 226秒 | 57区間が一致。4人 |
| 2人対談 先頭360秒 | 94区間が一致。2人。ffmpeg で先頭5,760,000サンプルを無変換で切り出した |
| 3秒・無音5秒 | 停止まで通り、保存できる |

- 末尾の区間は試作と同じ `finishStream` の結果と一致したことで確かめた。無音で終わる音声では、区間が音声の終端まで届くとは限らない
- kpjud で `KIKIGAKI_DEBUG_TYPED_VERIFY=1` と `KIKIGAKI_DEBUG_AI_RENAME` を通し、E〜H の改名が Markdown へ保存され、統合と解除が戻ることを確かめた
    - kpjud は英語音声で、ja_JP の文字起こしが出す行は試行ごとに揺れる。どの枠に行が付くかは一定しない

## GUI

- 8枠を検出した状態の統合ポップオーバーと開始シートを PNG にした
    - `KIKIGAKI_UI_CAPTURE=<出力先> swift test --filter DiarizationTests`
    - `KIKIGAKI_START_SHEET_CAPTURE=<既存の出力先> swift test --filter StartSheetTests`
- 録音中・停止後のウィンドウは `--replay <kpjud> --show-window` で撮る
