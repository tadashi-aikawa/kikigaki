# Nemotron 試作比較

Nemotron 3 Diarization と Nemotron 3.5 ASR を、現行の Sortformer と Apple Speech に同じ入力で比べる独立CLI。アプリ本体・既定・設定・保存形式は変えていない。

## 結論

- 話者判別は Nemotron 3 へ替えられる見込みがある
    - 8枠の出力・10ms時刻・末尾flushが動き、一括処理と完全一致した
    - 4人の実録で4人を分けた。現行の High Context は同じ素材で2人にまとめた
    - fast128 の計算は現行より速い。現行の約1.7倍
    - fast32 と low は現行 High Context より遅い
    - 限界: 実録に正解ラベルが無く、話者精度の非劣化は未確定
- 文字起こしの全面置換は期待を満たさない
    - 日本語は動き、トークン時刻も取れる
    - 計算は今回の2素材・2回の実行とも Apple より遅かった
    - 今回の2素材では脱落・誤字が目立った
    - 限界: 人手の正解文が無く、CERは出していない。日本語全般の優劣は言えない
- FluidAudio 0.15.6 → 0.17.4 の依存更新だけでは、Sortformer の出力は変わらない
    - 3素材で区間が完全一致した
    - Sortformer のソースも両版で差分なし

## 構成

| パス | 内容 |
|---|---|
| `baseline-0156/` | FluidAudio 0.15.6。アプリと同じ Sortformer の基準線 |
| `fa-0174/` | FluidAudio 0.17.4。Sortformer・Nemotron 3・Nemotron ASR・Apple Speech・比較 |
| `Shared/BenchCommon.swift` | 両パッケージがシンボリックリンクで共有する入力・計測・Sortformer の実行 |
| `run.sh` / `run-asr.sh` / `run-voxconverse.sh` | 同じ区間を各エンジンへ直列に流す |
| `compare.sh` | 出力JSONを組にして比べ、要点をTSVで出す |
| `work/` | モデル・音声・出力・ログ。gitに入れない |

- 2つのパッケージに分けた理由: SwiftPM は同じ依存の2版を1つのグラフへ入れられない
- 入力はアプリの `FileSource` と同じ `AudioConverter().resampleAudioFile` で16kHz monoにし、0.5秒刻みで流す
- 0.17.4 のモデルは `work/models` へ隔離した
    - 理由: アプリが使う `~/Library/Application Support/FluidAudio/Models` へ新しい版の取得・修復処理を触れさせない

## 再現手順

```sh
cd experiments/nemotron
swift build -c release --package-path baseline-0156
swift build -c release --package-path fa-0174

# 実録。名前・WAV・開始秒・長さ
./run.sh panel4-head ~/Documents/KIKIGAKI/2026-09-14_0728.wav
./run.sh panel4-full ~/Documents/KIKIGAKI/2026-09-14_0044.wav
./run.sh talk2-head ~/Documents/KIKIGAKI/2026-09-13_1322_2.wav 0 360
./compare.sh panel4-head

# 文字起こし。5番目の引数は Apple の速報+高精度を等倍で流す秒数
./run-asr.sh panel4-head ~/Documents/KIKIGAKI/2026-09-14_0728.wav 0 "" 60
./run-asr.sh talk2-head ~/Documents/KIKIGAKI/2026-09-13_1322_2.wav 0 360

# 公開の8話者素材。音声と正解RTTMを取得して比べる
./run-voxconverse.sh kpjud ralnu

# 個別の比較
fa-0174/.build/release/Bench0174 compare diar A.json B.json [--ref-rttm x.rttm]
fa-0174/.build/release/Bench0174 compare asr A.json B.json
fa-0174/.build/release/Bench0174 compare attrib ASR.json DIAR_A.json DIAR_B.json
```

- 初回はモデルを HuggingFace から取得する。合計は約1.5GB
    - `nemotron-3-diarization`: 578MB。fast32・fast128・low の3つ
    - `nemotron-multilingual`: 640MB。multilingual/2240ms
    - `sortformer`: 252MB。0.17.4 側の High Context
- 比較は音源・開始秒・長さが一致しない入力を exit 2 で拒否する

## 計測の定義

| 項目 | 意味 |
|---|---|
| `loadSeconds` | モデルの取得・読み込み・コンパイル。初回はダウンロードを含む |
| `computeSeconds` | 流している間と末尾処理の壁時計。等倍入力の待ちは `paceWaitSeconds` へ分ける |
| `rtfx` | 音声秒 ÷ computeSeconds。等倍入力の計測では出さない |
| `configuredBufferSeconds` | 設定上の入力バッファ量。chunk と右文脈の和 |
| `frameWait` | 10msフレームごとの「判定が出た時点の入力済み位置 − フレーム時刻」 |
| `finalizedLag` | 入力済み位置と判定済み末尾の差。chunk 先頭の待ちは見えない |
| `emissionLag` | 文字起こしのトークンごとの「到着時点の入力済み位置 − トークン終了時刻」 |

- 話者の比較は10ms格子で、話者番号の置換を最適化してから数える
- 正解RTTMが無い比較は、片方を基準にした不一致率。DERではない
- DERは自前集計
    - 条件: collar=0、重なり発話を含む、10ms量子化、UEMなし
    - md-eval や dscore などの公式採点器ではない

## 結果

M4 Pro、24GB、macOS 26.7。表は最終1回分。統制した反復評価は、話者判別の warm 3回だけ。

### 話者判別の速度と待ち

4人パネル全長 18分40秒。

| 条件 | 枠 | 検出人数 | compute | RTFx | バッファ設定 | frameWait 中央値 / 最大 |
|---|---|---|---|---|---|---|
| Sortformer high・0.15.6 | 4 | 4 | 5.59秒 | 200 | 30.4秒 | 17.1秒 / 30.9秒 |
| Sortformer high・0.17.4 | 4 | 4 | 5.58秒 | 201 | 30.4秒 | 17.1秒 / 30.9秒 |
| Sortformer balanced | 4 | 4 | 127.0秒 | 9 | 1.04秒 | 1.06秒 / 1.54秒 |
| Sortformer fast | 4 | 4 | 40.9秒 | 27 | 1.04秒 | 1.06秒 / 1.54秒 |
| Nemotron 3 fast128 | 8 | 4 | 3.18秒 | 353 | 10.56秒 | 5.7秒 / 11.06秒 |
| Nemotron 3 fast32 | 8 | 3 | 7.15秒 | 157 | 2.88秒 | 1.86秒 / 3.38秒 |
| Nemotron 3 low | 8 | 4 | 55.4秒 | 20 | 1.04秒 | 0.94秒 / 1.54秒 |

warm で直列に3回ずつ測り直した値。モデルの読み込みは除く。

| 条件 | compute 中央値 | 範囲 |
|---|---|---|
| Sortformer high・0.15.6 | 5.531秒 | 5.515〜5.548秒 |
| Nemotron 3 fast128 | 3.181秒 | 3.161〜3.189秒 |

- Nemotron 3 の読み込みは初回 27〜30秒。ダウンロードと約6秒のコンパイルを含む。2回目以降は0.1秒未満
- `peakRSSMB` は ANE 上のメモリを含まず、モデル間の比較に使えない

### 話者判別の出力差

参照ラベルの無い実録。A を基準にした不一致であり、正誤ではない。人数は合計1秒以上話した枠の数。`single` は両方が1人と判定したフレームでの一致率。

| 素材 | A | B | A人数 / 交代 | B人数 / 交代 | 取り違え | single |
|---|---|---|---|---|---|---|
| 4人冒頭 3分46秒 | high・0.15.6 | high・0.17.4 | 2 / 7 | 2 / 7 | 0 | 100% |
| 4人冒頭 3分46秒 | high | n3 fast32 | 2 / 7 | 4 / 9 | 36.4% | 61.0% |
| 4人冒頭 3分46秒 | Sortformer fast | n3 fast32 | 3 / 6 | 4 / 9 | 10.9% | 88.5% |
| 4人全長 18分40秒 | high・0.15.6 | high・0.17.4 | 4 / 19 | 4 / 19 | 0 | 100% |
| 4人全長 18分40秒 | high | n3 fast32 | 4 / 19 | 3 / 49 | 31.1% | 64.3% |
| 4人全長 18分40秒 | n3 fast32 | n3 fast128 | 3 / 49 | 4 / 16 | 22.6% | 77.0% |
| 2人対談 6分 | high・0.15.6 | high・0.17.4 | 2 / 35 | 2 / 35 | 0 | 100% |
| 2人対談 6分 | high | n3 fast32 | 2 / 35 | 2 / 47 | 0.7% | 99.2% |

- 2人対談では現行と Nemotron 3 がほぼ一致した
- 4人の素材では大きく食い違う
    - 冒頭3分46秒: 2026-09-17 の Sortformer 実録比較で、high は4人を2人にまとめ、本文から読める正解区間での正解率は56.6%だった。Nemotron 3 の検出人数4は正解の人数と合う
    - 全長18分40秒: fast32 は3人しか分けられなかった。fast128 と low は4人
    - どちらが正しいかは原音を聞かないと決められない

Apple の同じ文字列へ話者を割り当てたときの文字単位の一致率。基準は high・0.15.6。割り当てはトークンと最も長く重なる話者を採る単純な方法で、アプリの Aligner ではない。

| 素材 | n3 fast32 | n3 fast128 | Sortformer fast |
|---|---|---|---|
| 4人冒頭 | 57.3% | 57.2% | 57.1% |
| 2人対談 | 97.8% | 97.8% | 97.6% |

### 公開の8話者素材 VoxConverse

- 音声: Hugging Face の `ggfox00000/dia-voxconverse-test` の `audio/test/<id>.wav`。cc-by-4.0 のミラー
- 正解: 公式 `joonson/voxconverse` の `master/test/<id>.rttm`。v0.3、コミット `24bf60b`
- 長さの整合
    - kpjud: 音声 140.5秒、RTTM終端 140.5秒
    - ralnu: 音声 175.5秒、RTTM終端 171.5秒
- **学習データに含まれる**。NVIDIA の Nemotron 3 公式モデルカードは Training Datasets に VoxConverse v0.3 dev/test を挙げている
    - このため8人での動作・出力の確認と参考DERに留まる
    - 未知データへの汎化や、日本語会議での非劣化の証明にはならない

| 素材 | 正解人数 | 条件 | 検出人数 | 見逃し | 誤検出 | 取り違え | DER |
|---|---|---|---|---|---|---|---|
| kpjud 140秒 | 8 | Sortformer high | 4 | 4.2% | 1.9% | 14.6% | 20.8% |
| | | Nemotron 3 fast128 | 8 | 3.6% | 3.3% | 5.0% | 11.9% |
| | | Nemotron 3 fast32 | 8 | 2.5% | 1.8% | 6.0% | 10.3% |
| ralnu 176秒 | 8 | Sortformer high | 4 | 5.9% | 4.4% | 19.8% | 30.0% |
| | | Nemotron 3 fast128 | 7 | 2.0% | 4.1% | 7.0% | 13.1% |
| | | Nemotron 3 fast32 | 7 | 3.5% | 3.6% | 6.7% | 13.8% |

- 検出人数は合計1秒以上話した枠の数。ralnu の正解8人のうち1人は合計1.1秒しか話さない

### 文字起こし

`panel4-head` の文字起こしJSONは同じ名前で上書きした。下の表は最終実行の値。

| 実行 | 内容 |
|---|---|
| 初回 | Nemotron 3.771秒、Apple 高精度のみ 1.755秒、速報+高精度 2.042秒。途中報告の初回値 |
| 最終 | `run-asr.sh` を全条件で流し直した。下の表と現在のJSON |

- 初回と最終で順位は変わらない。どちらも Nemotron が Apple の速報+高精度より遅い

| 素材 | 条件 | compute | RTFx | トークンごとの待ち 中央値 / 最大 | Apple高精度との差分率 |
|---|---|---|---|---|---|
| 4人冒頭 226秒 | Nemotron ASR 2240ms | 3.56秒 | 64 | 1.36秒 / 2.64秒 | 17.5% |
| | Apple 高精度のみ | 1.91秒 | 118 | 参考外 | 基準 |
| | Apple 速報+高精度 | 2.05秒 | 110 | 参考外 | 0.2% |
| 2人対談 360秒 | Nemotron ASR 2240ms | 5.28秒 | 68 | 1.30秒 / 2.64秒 | 26.5% |
| | Apple 高精度のみ | 2.62秒 | 137 | 参考外 | 基準 |
| | Apple 速報+高精度 | 3.05秒 | 118 | 参考外 | 2.7% |

- Apple の行は等倍より速く流した。待ちの列は処理待ちを含み、遅れとして読めない
- 差分率は空白・句読点・記号を除いた文字の編集距離。Apple は正解ではなく、CERではない
- 今回の2素材の本文では、Nemotron ASR 側に脱落・誤字が目立った
    - 例: 「AI時代の」の脱落、「登断」「aidvレンス」「喉かな」「オイス」「エアイ」
    - Apple の同じ箇所は「AI時代の」「登壇」「のどか」「オフィス」「AI」
    - 限界: 人手の正解文は無い。2素材の目視であり、日本語全般の優劣は言えない
    - 参考: Nemotron ASR のモデルカードの日本語 FLEURS の CER は 13.79%

Apple の速報+高精度を、4人冒頭の先頭60秒で等倍に流した値。最終実行の1回分。

| 計測 | 高精度側 | 速報側 |
|---|---|---|
| 確定トークンごとの待ち 中央値 / 最大 | 14.96秒 / 30.7秒 | 7.44秒 / 16.86秒 |
| 暫定結果の末尾の遅れ 中央値 / 最大 | 0.15秒 / 0.22秒 | 0.17秒 / 0.22秒 |

- 計測の定義を直す途中の同じ条件の実行では、確定トークンごとの待ちが高精度側 15.14秒 / 30.7秒、速報側 11.28秒 / 32.7秒だった。1回ごとの揺れが大きく、代表値とは扱わない
- Apple の暫定結果は語ごとの時刻を持たず、区間全体で1つの範囲しか返さない(30秒の追跡1回で観測)。語ごとの表示遅れは測れない
    - 証拠: `work/logs/trace-apple.log`
- 暫定結果の末尾の遅れは、届いた時点の入力位置と暫定区間の末尾の差。届く間隔が空けばその間の待ちは見えない
- Nemotron ASR の同じ60秒は等倍ではなく高速投入で流した。確定トークンごとの待ちは中央値 1.30秒、最大 2.64秒
    - Nemotron の `process()` は同期処理で、この値は入力バッファ由来の差
    - 時刻の意味も計測単位も Apple と違うため、Apple の表示の遅れとは直接比べられない

## 限界

- 実録に正解ラベルが無い。話者の数値は出力の差であり、精度ではない
- 表は最終1回分。統制した反復評価は、話者判別の warm 3回だけ
- 8話者の実測は VoxConverse の2本だけで、学習データに含まれる
- 5〜7話者の素材は試していない
    - 理由: 8話者の確認を優先した。手元の実録に5人以上の会議が無い
- 日本語の複数話者で正解の付いた公開素材は見つけていない
- 録音中の表示の安定性は見ていない。停止後と同じ入力を流した結果だけ
- ASR の比較は Apple を基準にした差分率で、正解に対する CER ではない

## アプリへ入れる場合の変更点

話者判別だけを Nemotron 3 へ替える案。文字起こしは Apple のまま。

### 依存

- `Package.swift` の FluidAudio を 0.15.6 から 0.17.4 へ上げる
    - Sortformer の出力は3素材で変わらなかった
    - 新しいバイナリ依存 `NemoTextProcessing.xcframework` が入る。静的リンクで、`.app` への同梱や追加の署名は要らない
    - ビルド時に GitHub Releases から取得するため、CI とリリースの取得経路を確認する

### 話者判別

- `SpeakerDiarizer.swift` に Nemotron 3 の実装を足し、Sortformer と同じ口にする
    - `appendAudio` → `processBufferedAudio` で確率を連結し、`finishStream` で末尾を出す
    - High Context 用の無音の水増しは Nemotron 3 では要らない
    - 区間は実音声の終端で切る。10msの切り上げで1フレーム余るため
    - `finalizedDuration` は `streamedFrameCount × 0.01` で出す
    - 区間化のしきい値と最短長を決める。Sortformer は0.5・最短長なし
- `SortformerModelStore` をエンジン選択付きのモデル置き場にする。`KIKIGAKI_SORTFORMER` と同じ要領の比較用環境変数を足す

### 8枠への拡張

- `SpeakerNames.letters` を A〜H へ広げる
- `MeetingSession.swift:1130` の `0..<4` を `SpeakerNames.slotCount` へ置き換える
- 人数ボタン `SpeakerCountButton` の `n/4` 表示、`SpeakerSettingsPopover` の枠の並びを8枠で確かめる
- 改名・統合・`KIKIGAKI_DEBUG_AI_RENAME` の枠番号の検証を8枠にする
- 過去会議の互換
    - archive と `SpeakerNames` は枠番号の辞書なので、4枠の会議はそのまま読める
    - 読み込み時に枠数を会議ごとに固定するか、全会議を8枠として扱うかを決める

### 待ちの前提の見直し

- 話者固定の猶予30秒、発話行ゲージ、docs の「約30秒」を採用プリセットの待ちへ合わせる
    - fast32: フレームごとの待ち最大3.4秒
    - fast128: 最大11.1秒
- `SpeakerFreeze` の `judgedUntil` は Nemotron 3 の判定済み末尾を渡す

### 検証

- 日本語の実会議で、原音を聞いて付けた正解区間での採点が要る
- 相槌・短い応答の帰属は Aligner を通した結果で比べる
- 5〜7人の会議での実測

## 文字起こしを替える場合の制約

- モデルは `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML` の `multilingual/2240ms`
    - モデルカード冒頭に Discord でのアクセス申請の記載があるが、2026-09-26 時点ではトークン無しで取得できた
    - FluidAudio 0.17.4 の資料は「local-path-only」のままで、実装は HuggingFace から取得する
- トークン時刻は RNN-T の出力フレームで、実発話の境界ではない
    - `end = start + 80ms` の固定。語の長さを持たない
    - 現行の Aligner は語の長さで多数決の重みを付けるため、そのままでは短い相槌の帰属が変わり得る
- 今回の2素材では脱落・誤字が目立った。人手CERは無い
- 計算は今回の2素材で Apple の高精度側の約半分の速さだった
- 表示の速さは Apple と同じ条件で測れておらず、優劣は未確定
- 利点は、訂正の無い確定トークンが時刻付きで届く点。ただし時刻は出力フレームで、語の長さを持たない

## 次の検証候補

- 日本語の実会議に、原音を聞いて正解の話者区間を付けて採点する
- 5〜8人の日本語会議で、Nemotron 3 の人数と帰属を確かめる
- fast32 と fast128 を同じ正解で比べる
    - fast32: 待ちは最大3.4秒と短いが、4人全長では3人しか分けなかった
    - fast128: 待ちは最大11.1秒。4人を分け、計算も最速
- 相槌・短い応答の帰属を、アプリの Aligner を通して比べる
- 文字起こしを替える検討を続ける場合は、人手の正解文でCERを出し、Apple と同じ等倍条件で表示の遅れを測る
