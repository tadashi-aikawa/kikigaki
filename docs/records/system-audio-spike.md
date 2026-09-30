# システム音声取り込みの実現性試作の検証記録

2026-09-30の独立試作の検証記録。現行の仕様ではない。試作CLIの操作は[独立試作のREADME](../../experiments/system-audio/README.md)を参照する。

## 結論

**なる。内蔵・外付けUSB・Bluetoothイヤホンの3種類のマイクで、プロセスタップと同一aggregateによる同時取り込みを確認した。**

- 進行役がタダシ立ち会いで独立試作.appを許可し、別アプリの音声取得を確認した。
  - 実測者: 進行役。
  - 音源: Ghostty側の`afplay`とGoogle Chromeの動画。
  - 結果: Chromeだけの20秒録音をKIKIGAKIの等倍replayで2話者として文字起こしできた。
- 今回は`afplay`限定タップで、会議音声全長を42秒の16kHz mono Float32 WAVへ保存した。
  - 実測者: 委譲先のこのセッション。
  - 先頭保護: 5秒の無音を前置きし、原音の欠け上限はログ上0ms。
- 自己署名の同じbundle IDと証明書で試作.appを更新しても、録音を継続できた。
  - 制約: 手元の試作更新での結果。正式リリースを跨ぐ保証ではない。
- 進行役とタダシがUSB・内蔵マイクで48kHz、OWS 2マイクで16kHzの同時取り込みに成功した。
  - 結果: すべて欠落0。混合前2本と混合後1本を16kHz mono Float32で保存した。
- OWS 2の開始前エラーは、stream表示のレート一致を要求した試作側の制約だった。
  - 修正: aggregate公称レートを使い、実際のIOProcバッファのフレーム数と時計を検査する。
  - 実測: マイク16kHz・tap表示48kHzでも両バッファは320フレーム、共通時計16kHzだった。
  - 追加実測: 進行役とタダシのChrome・YouTube再生では、OWS 2でも10秒と60秒の両系統非ゼロ取得に成功した。
- 委譲先のOWS 2試験の全ゼロは、進行役の試験では再現しなかった。
  - 推定: 委譲先のafplay再生が実際には鳴っていなかった見込み。
  - 未確定: 原因は確かめていない。権限不足やBluetooth方式の失敗を示す結果とは扱わない。
- 本実装は、マイクとシステム音声を混ぜた1本を既存パイプラインへ渡す。
  - 決定者: タダシ。別々に文字起こしする形は採らない。
  - 理由: オンライン会議で声が重なったときは1人ずつ話し直す運用を想定し、重なった部分の認識欠落は許容する。
- 混合前にマイクとシステム音声の水準を揃える処理が必須。
  - 実測: マイク単独では読める文でも、低いマイク音量の混合では自分の声がほぼ落ちた。
  - 条件: 入力音量を上げた内蔵マイクではpeakが1.64に達した。音量調整と混合は上限を超えない形にする。
- リモート会議対応は補助機能として扱う。
  - 優先順位: 対面会議を重視するタダシの決定。
- 出力音量0、ミュート、録音中の出力切替は未実測。

## 環境と成果物

- 作業開始は2026-09-30T16:30。中間確認は2026-09-30T17:15。
  - 根拠: `date '+%Y-%m-%dT%H:%M'`の実時刻。
- 初回の実装・オフライン検証の完了確認は2026-09-30T17:33。
  - その後: 進行役が許可と別アプリ取得を実測し、追加発注で実装と検証を再開した。
- 追加発注の実装・録音・本文比較の完了確認は2026-09-30T18:08。
  - 根拠: 最終ビルド・署名検証後に`date '+%Y-%m-%dT%H:%M'`で取得した。
- 追加発注3の形式追従修正と最終ビルドの確認は2026-09-30T18:45。
  - 根拠: ビルド・署名・オフライン検証10件の成功後に`date '+%Y-%m-%dT%H:%M'`で取得した。
  - 追加結果: その後、進行役とタダシがOWS 2でも非ゼロ取得と混合replayを確認した。
- macOS 26.7、build 25G229。
- `experiments/system-audio/`に外部依存のない独立SwiftPM CLIを作成した。
  - 本体の未編集箇所:
    - `Sources/`
    - `Tests/`
    - `Package.swift`
    - `Resources/`
    - `scripts/`
- コミットとタスクノート更新は行っていない。

| 証拠 | パス |
| --- | --- |
| タップ出力 | [permission-probe/system.wav](../../experiments/system-audio/work/permission-probe/system.wav) |
| 録音時のAPI・形式・音量 | [permission-probe.log](../../experiments/system-audio/work/logs/permission-probe.log) |
| TCCの帰属と拒否理由 | [tcc-audio.log](../../experiments/system-audio/work/logs/tcc-audio.log) |
| 進行役による別アプリの取得1 | [app-other-01](../../experiments/system-audio/work/app-other-01/) |
| 進行役による別アプリの取得2 | [app-other-02](../../experiments/system-audio/work/app-other-02/) |
| Chromeのみの20秒録音 | [app-idle-02](../../experiments/system-audio/work/app-idle-02/) |
| Chromeのみのreplay | [replay-idle](../../experiments/system-audio/work/replay-idle/) |
| .appへの許可帰属と作成イベント | [tcc-app-followup.log](../../experiments/system-audio/work/logs/tcc-app-followup.log) |
| 再生限定42秒録音 | [followup-play-only-01](../../experiments/system-audio/work/followup-play-only-01/) |
| 再生限定WAVの相互相関 | [followup-play-only-lag.log](../../experiments/system-audio/work/logs/followup-play-only-lag.log) |
| 更新署名と検証 | [build-followup.log](../../experiments/system-audio/work/logs/build-followup.log) |
| 原音の等倍replay | [followup-replay-direct](../../experiments/system-audio/work/followup-replay-direct/2026-09-30_1755.md) |
| 再生限定WAVの等倍replay | [followup-replay-tap](../../experiments/system-audio/work/followup-replay-tap/2026-09-30_1758.md) |
| replayバイナリ識別 | [kikigaki-replay-binary.sha256](../../experiments/system-audio/work/logs/kikigaki-replay-binary.sha256) |
| 進行役のUSB入力60秒 | [run1-usb-182557/capture.log](../../experiments/system-audio/work/run1-usb-182557/capture.log) |
| 進行役の内蔵入力60秒 | [run2-builtin-182738/capture.log](../../experiments/system-audio/work/run2-builtin-182738/capture.log) |
| 進行役のOWS 2開始前失敗 | [run3-ows2-182908/capture.log](../../experiments/system-audio/work/run3-ows2-182908/capture.log) |
| 進行役の内蔵入力音量変更90秒 | [run4-builtin-loud-184117/capture.log](../../experiments/system-audio/work/run4-builtin-loud-184117/capture.log) |
| 進行役のOWS 2入力10秒 | [run5-ows2-191438/capture.log](../../experiments/system-audio/work/run5-ows2-191438/capture.log) |
| 進行役のOWS 2入力60秒 | [run6-ows2-191516/capture.log](../../experiments/system-audio/work/run6-ows2-191516/capture.log) |
| 委譲先のOWS 2形式確認3秒 | [ows2-format-01](../../experiments/system-audio/work/ows2-format-01/) |
| 委譲先のOWS 2既知音声再生試行8秒 | [ows2-format-02](../../experiments/system-audio/work/ows2-format-02/) |

- 以下の`work/`は、リポジトリルートの`experiments/system-audio/work/`を指す。
  - 相対リンク: この文書からは`../../experiments/system-audio/work/`。
- `work/`の録音・ログ・replay結果はgitで無視される、検証した手元だけの証拠。
  - 制約: 別のcheckoutやGitHubからは参照できない。実測値と判断はこの記録に残した。
- `.build/`もgit無視対象。
- CLIの操作・試作.appの作成・隔離replay設定は[README](../../experiments/system-audio/README.md)に記載した。

## 完了した検証

| 検証 | 結果 |
| --- | --- |
| 独立パッケージの`swift build` | 成功 |
| `SystemAudioProbe self-check` | オフライン検証10件が成功 |
| 合成されたマイクとstereo tapのchannel分離 | interleavedと分離bufferの両方で確認 |
| 実バッファのフレーム数不一致 | 2フレームと3フレームの入力を拒否し、誤った混合を防ぐ |
| sample timeの欠落 | 不連続を検出することを確認 |
| 48kHzから16kHzへの変換とWAV保存 | 1秒の長さ・mono Float32・ファイル長を確認 |
| WAVの上書き保護 | 既存ファイルを拒否することを確認 |
| Info.plist | `plutil -lint`成功 |
| マイク許可判断 | 未決定・許可・拒否・制限・60秒時間切れを確認 |
| 再生の前置き | 5秒の無音の後に全原音サンプルを保持 |
| 相互相関 | 正負の既知遅延、弱い相関・無音・周期的な曖昧さを確認 |
| 先頭末尾のずれ | 合成70秒で先頭8ms・末尾20ms・差12msを確認 |
| 試作.app作成スクリプト | 同一証明書で更新署名・検証・起動が成功 |

- `self-check`は録音デバイス・権限要求・再生を使わない。
  - 制約: これらの成功は、実マイクとの同期やTCC許可を確認した結果ではない。

## CLIの実装と検証

| 機能 | 実装 | 実測 |
| --- | --- | --- |
| システム音声 | 自プロセスを除くglobal stereo tapをprivate tap-only aggregateへ載せる | 進行役がChromeの音声取得を確認 |
| `--play-only` | `afplay`のHAL processだけを`stereoMixdownOfProcesses`へ指定 | 原音35.160秒を含む42秒取得 |
| マイク併用 | マイクをmain sub-device、tapをドリフト補正ありのsub-tapにする | USB・内蔵・OWS 2で60秒成功。内蔵は入力音量変更後の90秒も成功 |
| 混合前と混合後 | `system.wav`、`mic.wav`、`mixed.wav`を16kHz mono Float32で保存 | 3種類のマイクで非ゼロの3本を保存 |
| マイク許可待ち | 最大60秒。許可なら続行、拒否・制限・時間切れなら理由をログへ出して終了 | 進行役が許可済み。今回はauthorizedで待たずに録音開始 |
| `lag` | 先頭30秒と末尾30秒で正規化相互相関 | 合成70秒と実際の再生WAVで確認 |
| `processes` | HAL process・PID・bundle ID・runningOutputを一覧表示 | Chrome本体とhelperの存在を確認 |
| 指定時間停止 | 1〜120秒、停止後に変換と保存 | 42秒、672000フレームで確認 |
| 出力判定 | transport・terminal・data source・source kindを読む | 内蔵スピーカーとBluetoothヘッドホンを確認 |
| 出力変化 | 100msごとに既定出力のUIDと端子情報を再読込 | 変更試験は未実施 |

- 自プロセス除外にはPOSIX PIDをHAL process object IDへ変換して使う。
  - 実測: PID 14174 → HAL ID 142、tap 143。
  - 未検証: 自プロセス自身による音声再生を除外する実音試験。
- `CATapDescription`の`muteBehavior`は`.unmuted`。
  - 目的: タップ取得中も再生音声を通常の出力へ送る。[^taps]
  - 未検証: 人による音切れ・音量変化の聴感確認。
- システムのみのaggregateには出力デバイスを追加しない。
  - 理由: USB入出力機器のマイク入力を、タップ入力と取り違えないため。
- コールバック内ではディスクI/Oをしない。
  - 処理: native rateの事前確保mono領域へchannel平均を記録し、停止後に`AVAudioConverter`で変換する。
  - 制約: 短時間試作。長時間の本番ストリーミング用コードではない。
- 時間軸はaggregateの`kAudioDevicePropertyNominalSampleRate`から読む。[^nominal]
  - 条件: 連続channel、対応範囲のstreamレート、little-endian Float32。stream表示のレート一致は要求しない。
  - 検査: 各IOProcバッファのフレーム数一致、sample time連続性、sample time差とhost time差から求める時計レート。
  - 時計の検査: 実測レートと公称レートが1%以上違えば保存を止める。短時間で大きな解釈誤りを検出する条件であり、ppm精度の保証ではない。
  - 例外: 未対応形式、フレーム数不一致、時刻欠落はエラーで止める。
  - 注意: 一般のvirtual formatはIOProc形式を表すとSDKにある。今回のtap stream表示と共通時計の違いは実機固有の観測として扱う。[^virtual]
- 混合は`0.5 * system + 0.5 * mic`。
  - 目的: 6dBの余裕を取り、同時発話のクリップを抑える。
  - 制約: 自動正規化とエコー除去は実装していない。

## 権限

| 確認項目 | 結果 | 区分 |
| --- | --- | --- |
| `NSAudioCaptureUsageDescription` | 必要。tap付きaggregateの初回録音開始時に許可要求 | 公式本文で確認 [^taps] [^audio-key] |
| マイクの説明文 | `NSMicrophoneUsageDescription`を用意。進行役が許可し、60秒の実録音に成功 | 進行役の実測。今回もauthorization=3 |
| CLI側の説明文 | Mach-Oの`__TEXT,__info_plist`に埋め込み済み | `otool`で確認 |
| CLIの許可帰属 | Ghostty。requesting/accessingはCLIでもsubjectとresponsibleはGhostty | 実測 |
| 許可要求の拒否 | Ghosttyの音声取得説明文不足 | TCCログで実測 |
| 拒否時のAPI挙動 | create/startは成功し、非ゼロの音声が届いた | 今回の条件のみ実測 |
| 画面収録の許可 | システム音声のみの許可経路。画面取得APIは使用していない | 公式資料とコードで確認 [^audio-settings] |
| 独立.appの許可 | 試作bundle IDへ帰属。ダイアログをタダシが許可 | 進行役実測とTCCログで確認 |
| 自己署名の更新跨ぎ | 同じbundle ID・証明書で更新した.appが再録音できた | 今回の実測。正式リリース跨ぎは未確認 |

- APIの成功や非ゼロ音声だけでは、他アプリの取得が許可されたと判定できない。
  - 実測上の論点: 説明文不足の拒否ログと非ゼロのWAVが同時に存在する。
- 全ゼロだけでも権限拒否とは断定できない。
  - 条件: 通常の無音、再生停止、機器構成、許可不足を区別する必要がある。
- 独立した不許可状態で必ずエラーになるか、無音になるかは未確定。
  - 理由: 許可取り消しは行っていない。初回CLIでの拒否は、そのCLIが端末へ帰属した条件の結果。
- 進行役による許可はTCCログからも確認した。
  - 観測: 17:34:46の`AUTHREQ_PROMPTING`は試作bundle ID。17:34:53に同じIDのAudioCapture `TCCDEvent: type=Create`。
  - 実測者: 許可操作は進行役とタダシ。今回のセッションはログを読み取り確認した。

### 自己署名.appの見込み

- 既存`.build/KIKIGAKI.app`のdesignated requirementを読み取り確認した。
  - 実測: `identifier "com.tadashi-aikawa.kikigaki" and certificate leaf = H"31e447bbcf0a2c737a445b456eaea1359e760d1d"`。
- 同じ証明書と識別子で更新を同じアプリとして識別できる署名になっている。
  - 根拠: Appleはdesignated requirementを更新間の同一性に使うと説明している。[^signing]
- AudioCapture TCCの許可維持は保証できない。
  - 理由: 署名の一般論は、システム音声録音のTCC更新保証ではない。
  - 実測: 今回、同じ証明書で更新・再署名した独立試作.appから非ゼロの音声を取得できた。
  - 限界: 正式なKIKIGAKIリリースの入替えは未実測。
- 証明書名だけでなく証明書そのものを維持する。
  - 理由: 証明書の作り直しやbundle ID変更は識別条件を変える。
- 初回CLIはad hoc署名でdesignated requirementは`cdhash`だった。
- 今回の.appは`kikigaki-dev`署名。
  - 実測: `identifier "com.tadashi-aikawa.kikigaki.system-audio-probe" and certificate leaf = H"31e447bbcf0a2c737a445b456eaea1359e760d1d"`。

## 取り込み品質

原音は`~/work/fluidaudio-sandbox/samples/dialog2.wav`。

### 今回の再生限定タップ

実測者は委譲先のこのセッション。

| 項目 | 原音 | 再生限定タップ出力 |
| --- | --- | --- |
| 形式 | 16kHz mono Int16 | 16kHz mono Float32 |
| 長さ | 35.1604375秒 | 42秒 |
| フレーム数 | 562567 | 672000 |
| peak | 0.4597473 | 0.45987728 |
| RMS | 0.06067012 | 0.05545943 |
| 非ゼロ数 | 387989 | 395053 |

- 再生用`playback.wav`には5秒の無音を前置きした。
  - 目的: `afplay`起動後にHAL IDを取得してタップを作る間、原音先頭を保護する。
  - 条件: 録音時間は原音長+6秒以上にする。
- `afplay`は正常終了0、録音は42秒。
  - 観測: 起動から初回入力host timeまで0.047649958秒。
  - 欠けの上限: `max(0, 初回入力時刻−起動時刻−5秒)`は0ms。
  - 限界: 実際の出音開始時刻は取得していない。ログの値は欠けの上限であり、計測した欠落サンプル数ではない。
- RMSの値は無音を含む長さが異なる。
  - 注意: この表のRMS差を、そのまま音量低下と解釈しない。
- tapとaggregateは48kHz stereo Float32で動作した。
  - 保存: 16kHz monoへ変換。
- コールバック3943回、採用native frame 2016000、sample time欠落0、channel構成不一致なし。
- `afinfo`で42秒、672000 packets、2688000 audio bytes、mono Float32を確認した。
- stop・IOProc破棄・aggregate破棄・tap破棄のOSStatusはすべて0。
- 再生用WAVとタップWAVを`lag`で比較した。
  - 先頭: タップ側84ms遅れ、相関0.950709、離れた山との差0.594993。
  - 末尾: タップ側84ms遅れ、相関0.951698、離れた山との差0.650439。
  - 差: 0ms。
  - 注意: ファイル先頭を基準にしたずれ。再生開始と録音開始の差も含むため、タップ経路単独の遅延ではない。
  - 限界: 共通音声長40.16秒で窓が重なるため、長時間のドリフト補正を検証した結果ではない。

### 本文比較

**比較は成立したが、本文は完全一致しなかった。**

- 原音とタップWAVを、同じKIKIGAKIバイナリで直列に等倍replayした。
  - 条件: `KIKIGAKI_DEBUG_REPLAY_REALTIME=1`、`KIKIGAKI_DEBUG_DIARIZATION=on`。
  - 保存先: 専用の2つの`--config`で分離した。
  - SHA-256: `e2678ea2f541bd843257ea3b2f3c2b85ea3dfd1910082f70a62a255969355765`。前後で不変。
- 両方が終了コード0でMarkdownを保存した。
  - 診断: 両ログに速報側の終了時`CancellationError()`がある。保存された本文は確認できた。
- 時刻と話者ラベルを外し、改行を詰めて本文を比較した。

| 箇所 | 原音のreplay | タップのreplay |
| --- | --- | --- |
| 冒頭 | おはようございます。今日の聴会を始めます。 | 同じ |
| リリース作業 | 昨日はリリース作業をしていました。 | 昨日はリース作業をしていました。 |
| リリースの質問 | リリースは無事に終わります。 | 対応する本文なし |
| 修正予定 | 終わつかわりました。 | 終わりましたつまずが見つかったので今日直します。 |
| 仕様書レビュー | 私は書のレビューめます。 | 私は仕様書のレビューを進めます。 |
| 相談 | 相談したいことがあるので時間もらえますか。 | どのに相談したいことがあるので、時間をもらえますか。 |
| 時間 | 3時以降なら空いています。 | 同じ |
| 最後の返答 | では、 3時に声をかけます。ありがとうございます。 | ではありとうございます。 |

- 原音側にも認識の崩れがあり、タップ側の方が文として戻っている箇所もある。
  - 判断: 1回ずつの比較から、本文差をタップ取得の劣化と断定しない。
- 5秒の無音、16→48→16kHzの変換、処理時の状態が比較条件の差になる。
  - 次の品質検証: 無音条件を合わせた比較や複数回の認識で、入力の差とASRの揺らぎを分ける。
- 会議音声が取得できて既存パイプラインへ流せることは確認できた。
  - 限界: 本文の同一性と長時間会議での精度は保証していない。

### 進行役の実測

- `work/app-idle-02/system.wav`は、追加の`afplay`を流さずに録ったChromeの20秒音声。
  - 実測者: 進行役。
  - 結果: `work/replay-idle/`で2話者の本文になった。
- `work/app-other-02/`はChrome音声と`afplay`が混ざっている。
  - 結果: 原音との本文比較には使えなかった。
  - 対応: 今回の`--play-only`はglobal tapを使わず、再生プロセスのみを指定する。
- 初回CLIの5秒WAVとTCC拒否ログは、初回の許可帰属の証拠として残した。

## プロセス指定の制約

- `--play-only`は`CATapDescription(stereoMixdownOfProcesses:)`へ`afplay`のHAL process IDだけを渡す。[^process-tap]
  - 実測: 初回のPID照会は0、登録後はHAL ID 163を取得できた。
- 音が聞こえる前でも、HALに登録済みならタップを作れた。
  - 条件: 今回は5秒の無音を再生中。音声I/Oは初期化されている。
- 起動しただけでまだHALへ登録されていないPIDは、そのまま指定できない。
  - 理由: APIが受け取るのはPOSIX PIDではなくHAL process object ID。未登録なら照会結果は`kAudioObjectUnknown`。
- 単一のprocess指定はブラウザの子プロセスを自動で包括する契約ではない。
  - 実測: Chrome本体`com.google.Chrome`と2つの`com.google.Chrome.helper`がHALに別々に存在した。
  - 限界: この一覧取得時はChromeの`runningOutput=0`。どのhelperが動画の音声を出すかを限定取得で実測したわけではない。
- macOS 26では`bundleIDs`と`isProcessRestoreEnabled`も利用できる。[^bundle-ids] [^restore]
  - 設計候補: helperを含む実際の音声プロセスのbundle IDを指定し、起動・終了で対象を更新する。
  - 未実測: bundle ID指定とブラウザ再起動時の復元。
  - 限界: 同じブラウザの会議以外のタブをどう除くかは別課題。

## 同時取り込みと時計のずれ

### 進行役とタダシの実測

出力は全試験でBluetoothイヤホンOWS 2。音源はタダシがChromeで再生したYouTube。すべて`--mic`の同一aggregateで録音した。

| 出力先 | 入力 | 秒数 | aggregateレート | 欠落 | system RMS | mic RMS |
| --- | --- | --- | --- | --- | --- | --- |
| `run1-usb-182557` | USB MICROPHONE | 60 | 48kHz | 0 | 0.0620035 | 0.0220623 |
| `run2-builtin-182738` | MacBook Proのマイク、既定の入力音量 | 60 | 48kHz | 0 | 0.0689943 | 0.0140754 |
| `run4-builtin-loud-184117` | MacBook Proのマイク、入力音量ほぼ最大 | 90 | 48kHz | 0 | 0.0561262 | 0.0685481 |
| `run5-ows2-191438` | OWS 2 | 10 | 16kHz | 0 | 0.0651144 | 0.0212638 |
| `run6-ows2-191516` | OWS 2 | 60 | 16kHz | 0 | 0.0522371 | 0.0205438 |

- すべて両系統が非ゼロで、layout不一致はfalseだった。
  - 証拠: 上の証拠一覧の各`capture.log`。追加発注4で報告された値と照合した。
- 内蔵マイクの入力音量変更は、進行役とタダシが行った。
  - 実測: run4のmic peakは1.6374049、mixed peakは0.84049535だった。
  - 注意: Float32入力は1.0を超えていた。単にマイクを増幅する処理には上限対策が必要。
- OWS 2ではtap stream表示は48kHzのままだが、公称16kHzの共通時計で録れた。
  - run5: callback 504回、320フレーム固定、保存160000 native frames、observedHostRate 16000Hz。
  - run6: callback 3001回、320フレーム固定、保存960000 native frames、observedHostRate 約16000Hz。
  - run6の初回buffer: micはmono・1280 bytes、tapはstereo・2560 bytes。両方320フレーム。
- 先行の`work/tadashi-181722/`もUSB入力で成功した。
  - 出典: 追加発注3の進行役報告。
- イヤホン条件の`lag`は相関がほぼ0だった。
  - 出典: `tadashi-181722`についての進行役報告。
  - 聴感: 進行役とタダシの確認では、マイク単独の音にYouTube側の声は入っていなかった。
  - 結果: 今回のイヤホン条件では、マイクが相手の声を拾う二重取り込みは認められなかった。
  - 制約: 相関が弱い2本では遅延と長時間driftは測れない。他の装着状態や機器の保証ではない。

### 混合replayでのマイク音量

進行役とタダシが、同じKIKIGAKIバイナリの等倍replayで混合とマイク単独を比較した。

| 回 | 混合でのタダシの声 | マイク単独 | 混合の保存結果 |
| --- | --- | --- | --- |
| run1 | 別話者として拾えた。相手と重なると短い断片に割れた | 比較を実施 | [replay-run1-mixed](../../experiments/system-audio/work/replay-run1-mixed/2026-09-30_1830.md) |
| run2 | ほぼ落ちた | 読める文で出た | [replay-run2-mixed](../../experiments/system-audio/work/replay-run2-mixed/2026-09-30_1832.md) |
| run4 | 相づちと短い返答が相手と別話者で交互に出た。自分の声が2話者に割れる場面もあった | 比較を実施 | [replay-run4-mixed](../../experiments/system-audio/work/replay-run4-mixed/2026-09-30_1843.md) |
| run6 | ほぼ落ちた | 読める文で出た | [replay-run6-mixed](../../experiments/system-audio/work/replay-run6-mixed/2026-09-30_1916.md) |

- マイク単独の結果も手元に保存されている。
  - run1: [replay-run1-mic](../../experiments/system-audio/work/replay-run1-mic/2026-09-30_1831.md)。
  - run2: [replay-run2-mic](../../experiments/system-audio/work/replay-run2-mic/2026-09-30_1833.md)。
  - run4: [replay-run4-mic](../../experiments/system-audio/work/replay-run4-mic/2026-09-30_1844.md)。
  - run6: [replay-run6-mic](../../experiments/system-audio/work/replay-run6-mic/2026-09-30_1917.md)。
- YouTube側の声はどの回も読める文となり、話者も分かれた。
  - 出典: 進行役とタダシの混合replay評価。
- 進行役は、マイクとシステム音声の水準を揃える処理を本実装で必須と判断した。
  - 根拠: run2とrun6はマイク単独で読める文が混合でほぼ落ち、run4ではマイク音量を上げると返答が出た。
  - 制約: 音量を揃えた処理自体はまだ試していない。ゲイン調整後の認識精度や話者分離の保証ではない。

### 委譲先のOWS 2試験

委譲先は3秒と8秒の形式確認を行った。入出力設定と音量は変更していない。録音は形式・音量のみ確認し、文字起こしへ流していない。

| 試験 | 結果 |
| --- | --- |
| `ows2-format-01`、3秒 | マイク非ゼロ、システム全ゼロ。既知音声は未再生 |
| `ows2-format-02`、8秒 | afplayを起動したがシステム全ゼロ。実際に出音したかは確認していない |

#### 届いたバッファ

| 項目 | 3秒試験 | 8秒試験 |
| --- | --- | --- |
| aggregate公称レート | 16000Hz | 16000Hz |
| mic buffer | mono、1280 bytes、320 frames | mono、1280 bytes、320 frames |
| tap buffer | stereo、2560 bytes、320 frames | stereo、2560 bytes、320 frames |
| callback数 | 152 | 405 |
| 保存したnative frames | 48000 | 128000 |
| 欠落・layout不一致 | 0・false | 0・false |
| 全callbackのフレーム数範囲 | 記録なし | min 320、max 320 |
| 最初から最後のhost time差 | 3.02秒 | 8.08秒 |
| 同区間のsample time差 | 記録なし | 129280 frames |
| sample time差 / host time差 | 記録なし | 16000.0Hz |
| system peak・RMS | 0・0 | 0・0 |
| mic peak・RMS | 0.265686・0.0199496 | 0.264740・0.0199893 |

- Float32の解釈はstream形式の32bit・float・little-endianと、実バッファのchannel数・byte数に基づく。
  - 制約: AudioBufferList自体はASBDを持たない。レートはaggregate公称値と時刻で確認した。
- 8秒試験の3本は、すべて16kHz mono Float32、128000フレームだった。
  - system: 全ゼロ。
  - mic: 非ゼロ118642フレーム。
  - mixed: micを0.5倍しただけの内容。2音源の混合成功とは扱わない。
- afplayは録音開始後に起動し、8秒で明示的に終了させた。
  - 観測: PID 29125、terminationStatus=15。形式と音量のみ確認し、文字起こしには流していない。
  - 未確認: 人が聴いた実際の再生音。
- 進行役とタダシのChrome再生では全ゼロは再現せず、両系統の取得に成功した。
  - 推定: 委譲先側の再生が実際には鳴っていなかった見込み。
  - 未確定: 原因は調べていない。OWS 2取得の実現性は進行役の非ゼロ取得で確認できた。
- 修正前の`run3-ows2-182908`は、録音開始前のstreamレート一致チェックで失敗した。
  - 解決: aggregate公称レートで解釈し、実バッファを検査する修正後にrun5・run6が成功した。

### 方式の判断

**同一aggregateとHALのドリフト補正を本実装に推奨する。**

- マイクをmain sub-deviceの時計とし、tap側の`kAudioSubTapDriftCompensationKey`を有効にする。
  - 品質: high qualityを指定。キーの意味はApple SDKで確認した。[^drift]
- 同じIOProc内のフレーム位置でマイクとシステム音声を分ける。
  - 整列: 別々の開始時刻の推定は不要になる。
  - 変換: aggregate公称レートで両系統を解釈し、16kHzへ変換する。
  - 条件: 全バッファが同じフレーム数・時計で届くこと。stream表示だけを揃える設定変更はしない。
- sample timeの欠落を検出した場合は、保存をエラーにする。
  - 理由: 欠落した時間を詰めたWAVを正しく同期した結果として扱わないため。
- 共通時計だけでは機器の入力遅延やBluetooth伝送遅延は消えない。
  - 次回測定: インパルスの相対位置、長時間の位置変化、入力latency。
- 別々に取得してhost timeで揃える方式も実現可能と考えられる。
  - 必要処理: 初期位置合わせ、リングバッファ、rate推定、継続的resample、欠落時のゼロ挿入。
  - 限界: 最初の時刻だけ合わせても長時間の時計のずれは直らない。
- 同一aggregateは同期責務をHALへ任せられる。
  - 推定: 固定した機器での長時間録音にはこちらが堅い。
  - 実測: USB・内蔵・OWS 2の60秒取得に成功。内蔵は90秒も成功した。
  - 未実測: 録音中のBluetoothプロファイル変化、出力切替、長時間drift。
  - 制約: 最長90秒の取得成功は、1時間のドリフトや機器固有の経路遅延を保証しない。
- マイクとtapの独立取得は机上比較のみ。
  - 利点: 現行`MicSource`のAVAudioEngine.inputNodeとAudioResamplerを活かし、tapを48kHzの独立aggregateにできる。
  - 必要変更: 現行MicSourceはtap閉包のAVAudioTimeを捨てている。時刻付き内部サンプル口を追加し、混合workerへhost timeとframe位置を渡す必要がある。
  - 注意: 現在のAudioSourceの`[Float]`だけでは同期用時刻を受け渡せない。そのまま2つのAudioSourceを足す形では不足する。
  - 判断: 変更行数は少なく見えても、独立時計の追従・欠落処理を自前で持つため、現時点でより堅いとは判断しない。

### 独立取得時の1時間のずれの推定

| 2時計の相対レート差の仮定 | 1時間後のずれ | 16kHzでのずれ |
| --- | --- | --- |
| 10ppm | 36ms | 576 samples |
| 50ppm | 180ms | 2880 samples |
| 100ppm | 360ms | 5760 samples |
| 200ppm | 720ms | 11520 samples |

- すべて仮定からの計算であり、OWS 2の時計仕様や実測値ではない。
  - 計算: 3600秒 × 相対ppm × 0.000001。
  - 例: 各時計が逆方向へ100ppmずれるなら相対差は200ppmになる。
- 初回host timeだけで位置を揃えても、このずれは残る。
  - 本実装: host timeとsample timeの複数点から相対レートを推定し、緩やかなresample比率補正を続ける。
  - 制約: callback到着時刻はスケジューリングで揺れるため、音声に付いた時刻を使う。機器遅延は別途扱う。

### `lag`の測定条件

- 先頭30秒と共通終端側30秒の、1ms RMS包絡の正規化相互相関を求める。
  - 探索: 最大±2000ms。正の値はマイク側が遅れる向き。
  - 実装: Accelerateの`vDSP_dotpr`と各重なり区間の平均・分散で正規化する。[^dot]
  - 長さ違い: 短い方の終端に揃えて長い方の余りを除く。
- 相関0.35未満、100ms以上離れた山との差0.05未満、無音、探索範囲端、3秒未満は「測れない」とする。
  - 制約: しきい値は試作の保守的な判断値。実際の部屋とマイクでの校正は未実施。
- 共通音声が60秒未満では窓が重なると表示する。
  - 理由: 重なった窓の一致を長時間ドリフトの検証結果と誤認しないため。
- 合成70秒で先頭8ms、末尾20ms、変化12msを検出した。
  - 実測範囲: オフラインの既知遅延。実マイクの時計のずれは未実測。
- 音響遅延や経路変更も、末尾−先頭の差に含まれる。
  - 判断: 一定のスピーカー・マイク配置で測り、時計だけのずれと断定しない。

## 出力デバイスの判定

| 接続 | 判定できる範囲 | 限界 |
| --- | --- | --- |
| 内蔵 | 実機の`bltn`と`ispk`で内蔵スピーカーを判定 | 他Macは未実測 |
| 有線イヤホン | `hdpn`やheadphones terminalが公開されれば判定可能 | 挿抜は未実測 |
| Bluetooth | 実測の`OWS 2`は`blue`と`hdph`でheadphonesと判定 | Bluetoothスピーカーもあるためtransport単独では判定しない |
| USB | `usb `で接続方式、terminalがheadphonesなら判定可能 | DACの先のイヤホンとスピーカーは区別できない場合がある |

- 実機は`MacBook Proのスピーカー`、device ID 71、transport `bltn`、data source `ispk`だった。
  - terminal: 769、つまり`0x0301`。
- 今回の録音時は`OWS 2`、device ID 116、transport `blue`、terminal `hdph`だった。
  - 実測者: このセッション。出力設定の変更は行っていない。
- Core AudioのFourCC端子定数だけでは実機を判定できなかった。
  - 対応: IOKitの`OUTPUT_SPEAKER`・`OUTPUT_HEADPHONES`・`BIDIRECTIONAL_HEADSET`とdata source定数も使う。
  - 出典: インストール済みApple SDKの`IOKit/audio/IOAudioTypes.h`。
- 判定は`built-in-speaker`・`headphones`・`unknown`の3値。
  - 方針: 製品名やBluetooth・USB接続だけでヘッドホンと断定しない。
- 会議アプリが既定出力以外を選んでいる場合、既定出力の判定だけでは不十分。
  - 本実装: 利用者の明示的な音源選択を残す。

## 未実測の項目

| 項目 | 理由 | 再開時の確認 |
| --- | --- | --- |
| 音量調整後の混合品質 | 現行試作は固定0.5倍の混合のみ。低いマイク音量では認識が落ちた | ゲイン上限・無音時の扱い・混合後の上限を含む調整を実装してreplay比較 |
| 実機の長時間driftと経路遅延 | 3種類の60秒と内蔵90秒は取得成功。イヤホンでは共通音声がなくlag測定不能 | 共通インパルス、60秒以上と1時間の計測 |
| 未決定からのマイク許可待ち時間 | 進行役が許可済み。今回の起動はauthorizedだった | 初回未決定状態の別途試験時に、人が許可して続行する挙動を確認 |
| 音量0・ミュート | システム設定を書き換えない指示 | 人が出力音量とミュートを操作 |
| 既定出力切替 | 同上。機器接続操作なし | 人が録音中に切替、前後の音と欠落を確認 |
| 再生への影響 | 人の聴感確認なし | 音切れと音量変化を聴き比べる |
| 不許可時の一般的挙動 | 拒否ログと非ゼロ出力が併存 | 独立.appの許可前後を確認 |
| 正式リリースの更新跨ぎ | 試作.appの更新は確認済み | KIKIGAKIのリリース入替えで確認 |
| ブラウザの限定取得と再起動 | 今回の限定取得対象は単一の`afplay` | 音声helper選定とbundle ID指定を検証 |
| ASR本文差の原因分離 | 同じ原音の直接入力とタップ取得を1回ずつ比較 | 無音条件の統一と複数回の認識で検証 |

## 追加検証の手順

- 実現性確認のための許可と3種類のマイク取得は完了した。
  - 今後: 未実測表の品質と運用条件を別途確認する。
- 再試験では[README](../../experiments/system-audio/README.md)の`.app`起動手順と新しい出力先を使う。
  - 音源: 人がChromeなどの別アプリで既知音声を再生し、実際に聞こえることを確認する。
- 新しい環境の初回許可は人が操作する。
  - システム音声: システム設定 → プライバシーとセキュリティ → 画面収録とシステムオーディオ録音。
  - マイク: システム設定 → プライバシーとセキュリティ → マイク。
  - 対象: `SystemAudioProbe`。システムオーディオのみの許可経路を使う。
- 長時間のずれを測るときは、先頭と末尾に両系統で共通の音を入れる。
  - 理由: イヤホン利用の別々の発話を相関しても時計のずれは測れない。

TCCのデータベース変更、`tccutil`、仮想デバイス・ドライバ導入は行っていない。

## 本実装へ進む場合

- `AudioSource`へ`SystemAudioSource`と`MicAndSystemSource`を載せる形が自然。
  - 契約: 既存と同じ16kHz mono Float32の`onSamples`。
  - 処理: IOProcから事前確保リングバッファへコピーし、workerでresample・混合する。
- マイク併用モードは同一aggregate方式を推奨する。
  - 理由: 同じIOProcとHALのドリフト補正で同期を担保し、自前の独立時計補正を減らせる。
  - 根拠: 内蔵・USB・Bluetoothイヤホンの3種類で同時取得に成功した。
  - 本体変更: マイクのみのモードは現行MicSourceを維持する。混合モードは新たなMicAndSystemSourceへ切り替えるため、既存MicSourceのAVAudioEngineを並走させない。
- 2系統を混ぜた1本を、既存の文字起こしと話者判別へ渡す。
  - 決定: タダシ。音源ごとに別々に文字起こしする構成は採らない。
  - 許容: 重なった発話の認識欠落。必要なら会議参加者が1人ずつ話し直す。
  - 制約: 重なっていない自分の声まで音量差で落とす挙動は、音量調整で改善する必要がある。
- 混合前のマイク音量をシステム音声と同じ水準へ揃える処理を入れる。
  - 必須条件: 調整ゲインと混合後の振幅は上限を超えない形にする。
  - 設計候補: 発話中のレベルを使ってゲインを緩やかに変え、無音時の過大増幅を防ぎ、混合後にheadroomとlimiterを持たせる。
  - 注意: 録音全体のRMSには無音時間が含まれる。上のRMS比をそのまま固定ゲインにする判断は避ける。
  - 検証: 小声、相づち、通知音、同時発話で認識と話者割当を比較する。音量調整後の品質は未実測。
- リモート会議対応は補助機能とし、対面会議を優先する。
  - 決定: タダシ。マイクのみの既存経路を維持する。
- `stop()`はIO停止、キュー排出、IOProc・aggregate・tapの破棄を行う。
- KIKIGAKI.appへ`NSAudioCaptureUsageDescription`を追加する。
  - 案内: 相手の声を文字起こしするため再生音声を取得すると伝え、録音開始UIから許可へ案内する。
- 内蔵スピーカー時はマイクのみを既定にする。
  - 理由: マイクが拾う相手の声とタップ音声の二重取り込みを避ける。
- ヘッドホンと確認できれば2系統を混ぜる。
  - 例外: `unknown`は利用者に音源を選んでもらう。
- 録音中の出力変更時に音源モードを見直す。
  - 理由: スピーカーへの切替で二重取り込みの条件が変わる。
- 遅延とゲインを測り、通常の発話のASR・話者判別品質を確認する。
- global tapは通知や音楽も取得する。
  - 本実装: 会議アプリ限定の取得が必要かを別途検討する。

## ScreenCaptureKitとの机上比較

| 観点 | Core Audio process tap | ScreenCaptureKit |
| --- | --- | --- |
| システム音声のOS要件 | macOS 14.2以降 | `capturesAudio`はmacOS 13以降 |
| マイク | aggregateへ追加 | `captureMicrophone`はmacOS 15以降 |
| 許可 | システム音声のみ、`NSAudioCaptureUsageDescription` | 公式サンプルはScreen Recording許可と再起動を案内 |
| 構成 | tap・aggregate・IOProc・形式と時計の管理 | shareable content・filter・SCStream・audioとmicrophoneのsample処理 |

- KIKIGAKIのmacOS 26以降では対応OSはどちらも問題にならない。
- 音声のみの取得目的と権限負担から、Core Audioを第一候補にする。
  - 根拠: Core Audio公式サンプルとAppleのシステム音声のみの許可案内。[^taps] [^audio-settings]
- ScreenCaptureKitの実装量が必ず少ないとは断定しない。
  - 条件: content filter構築と、別々に届くaudio・microphone sampleの時刻処理が必要。
- ScreenCaptureKit側は机上比較のみ。
  - 出典: 実際に開いた公式サンプルとAPI資料。[^screen] [^screen-audio] [^screen-mic]

## 公式資料

Context7の結果はAppleのページ本文とSDKで検証した。

[^taps]: [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)。Markdown本文を取得。記事のメタデータは26.0だが本文の実行条件は14.2以降。
[^audio-key]: [NSAudioCaptureUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription)。Markdown本文とavailability 14.2を確認。
[^audio-settings]: [Control access to screen and system audio recording on Mac](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac)。システム音声のみの許可を確認。
[^signing]: [TN2206: macOS Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)。designated requirementとself-signed identitiesの節を確認。
[^drift]: [kAudioSubTapDriftCompensationKey](https://developer.apple.com/documentation/coreaudio/kaudiosubtapdriftcompensationkey)。ページを開き、意味と値はSDKの`AudioHardware.h`で確認。
[^screen]: [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)。Markdown本文で許可とstream構成を確認。
[^screen-audio]: [capturesAudio](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio)。Markdown本文とavailability 13.0を確認。
[^screen-mic]: [captureMicrophone](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone)。Markdown本文とavailability 15.0を確認。
[^process-tap]: [init(stereoMixdownOfProcesses:)](https://developer.apple.com/documentation/coreaudio/catapdescription/init(stereomixdownofprocesses:))。Markdown本文のSwift宣言とSDKの対象process IDの説明を確認。
[^bundle-ids]: [bundleIDs](https://developer.apple.com/documentation/coreaudio/catapdescription/bundleids)。Markdown本文でprocessのbundle ID配列とmacOS 26 availabilityを確認。
[^restore]: [isProcessRestoreEnabled](https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled)。Markdown本文で終了・再起動時のbundle IDによる復元を確認。
[^dot]: [vDSP_dotpr](https://developer.apple.com/documentation/accelerate/vdsp_dotpr)。Markdown本文で単精度ベクトル内積のAPIを確認。
[^nominal]: [kAudioDevicePropertyNominalSampleRate](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertynominalsamplerate)。Markdownの宣言を開き、公称レートを表すFloat64であることはApple SDKのAudioHardwareBase.hで確認。
[^virtual]: [kAudioStreamPropertyVirtualFormat](https://developer.apple.com/documentation/coreaudio/kaudiostreampropertyvirtualformat)。Markdownの宣言を開き、IOProcが取引する形式という定義はApple SDKのAudioHardwareBase.hで確認。

追加で実際に開いたAPIページ:

- [CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)
- [init(stereoGlobalTapButExcludeProcesses:)](https://developer.apple.com/documentation/coreaudio/catapdescription/init(stereoglobaltapbutexcludeprocesses:))
  - 確認: MarkdownのSwift宣言。
- [kAudioDevicePropertyTransportType](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertytransporttype)
- [kAudioStreamPropertyTerminalType](https://developer.apple.com/documentation/coreaudio/kaudiostreampropertyterminaltype)

Apple SDKの確認箇所:

- `CoreAudio.framework/Headers/AudioHardwareTapping.h`
- `CoreAudio.framework/Headers/CATapDescription.h`
- `CoreAudio.framework/Headers/AudioHardware.h`
- `CoreAudio.framework/Headers/AudioHardwareBase.h`
- `IOKit.framework/Headers/audio/IOAudioTypes.h`

## 本体実装で試した音量調整と交互発話の検証

2026-09-30の本体実装中の検証記録。現行の仕様ではない。現在の混ぜ方は[システム音声の取り込み](../system-audio.md)を参照する。

### 試した2つの音量調整

| 項目 | 方式1: 窓ごとに追従 | 方式2: 発話水準を保持 |
|---|---|---|
| 計測 | 10ms窓、活動しきい値RMS 0.003 | 1秒先読み内の10ms窓、RMS 0.015と保持基準の35%以上、3窓以上の中央値 |
| マイクの基準 | 上昇20ms、下降500ms | 発話時だけ20秒の時定数で更新 |
| 相手の基準 | 活動窓で平滑化、最大2秒保持 | 発話時だけ20秒の時定数で更新し、沈黙では保持 |
| ゲイン更新 | 上昇100ms、下降20ms。相手の沈黙後は1へ戻す | 発話時だけ3秒の時定数。初回は先読みblockの先頭から適用 |
| ゲイン上限 | 12倍 | 0.25〜12倍 |
| 目標の初期値 | 相手の基準が無ければゲイン1 | 目標RMSの下限0.08 |
| システム側 | ゲイン1 | ゲイン1 |
| ピーク保護 | 和を±1へ制限 | 和を±1へ制限 |

- 方式1は、相手の有無で自分の音量が変わり、雑音を基準に学習しやすい構造だった。
  - 指摘: 相手が2秒黙るとゲイン1へ戻る。マイク基準の下降も速く、発話のたびに語頭のゲインが立ち上がる。
- 方式2は、沈黙で基準を捨てず、語頭から決めたゲインを掛けるために試した。
  - 実測: 交互素材の固定した発話窓では、自分の3区間のRMS差が約1.2〜1.8dB。大きいマイクの上限到達は0になった。
  - 代償: 最大1秒の先読みと1秒ごとの音声chunkが加わる。

### 重ならない交互素材

- 独立試作で保存したmic.wavとsystem.wavから、8〜12秒の区間を3往復並べた。
  - 素材: run2は小さい内蔵マイク、run6はOWS 2、run4は入力音量が大きい内蔵マイク。
  - 編集: 相手のturnではマイクを全サンプル0にし、自分のturnではシステム側を全サンプル0にする。全フレームで少なくとも片方が0であることを確認した。
  - 境界: 両端だけ10ms fade。その他の音量は変えない。
  - 長さ: run2とrun6は62秒、run4は64秒。
- 検証素材はgitへ入れないwork内へ置いた。
  - 場所: リポジトリ起点の `experiments/system-audio/work/alternating-review1-run{2,6,4}/`。
  - 原音: 同じwork内の `run2-builtin-182738`、`run6-ows2-191516`、`run4-builtin-loud-184117`。
  - 記録: `work/alternating-run*-segments.tsv` に出力位置と原音の切り出し範囲を保存した。

| 素材 | 相手1 / 自分1の原音秒 | 相手2 / 自分2の原音秒 | 相手3 / 自分3の原音秒 |
|---|---|---|---|
| run2 | 12〜22 / 6〜16 | 24〜34 / 20〜30 | 48〜58 / 42〜54 |
| run6 | 0〜10 / 24〜34 | 10〜20 / 38〜50 | 40〜50 / 50〜60 |
| run4 | 19〜29 / 20〜30 | 38〜48 / 30〜42 | 49〜59 / 59〜71 |

- マイク単独、方式1、方式2を同じ素材の等倍replayで比較した。
  - 条件: `KIKIGAKI_DEBUG_REPLAY_SYSTEM` と話者判別を使い、saveRecording=trueで別の保存先へ出した。
  - 順序: 方式1の3本を先に取り終えてから、方式2へ変更した。
  - マイク単独: システム側の検証変数を付けずに同じmic.wavを流した。

| 素材 | 方式1の双方の主要な発話 | 方式2の双方の主要な発話 | 自分の名前付き話者数: 単独→方式1→方式2 | 上限到達サンプル: 方式1→方式2 |
|---|---|---|---|---|
| run2 | 3往復とも文字になった | 3往復とも文字になった | 1→1→1 | 0→0 |
| run6 | 3往復とも文字になった | 3往復とも文字になった | 1→1→1 | 0→0 |
| run4 | 3往復とも文字になった | 3往復とも文字になった | 1→1→1 | 212→0 |

- 短い不明話者の断片と単語の誤認は残った。
  - 境界: 不明断片を別の人物として数えていない。全文の完全一致や、すべての単語での改善を示す結果ではない。
- 重複した原音で起きた脱落や話者分裂を、音量調整だけの原因とは断定しない。
  - 根拠: 重なりを除いた交互素材では、方式1の時点で双方の主要な発話が入り、自分は1人にまとまった。

### 区間全体のRMS

- 保存WAVの区間全体で計測した。
  - 条件: 無音や発話の間も含む。値は小数5桁へ丸めた。
  - 記録: `work/alternating-run{2,6,4}-{mic,before,stable}-rms.tsv`。
  - 定義: micはマイク単独、beforeは方式1、stableは方式2。

| 素材 | 系統 | 出力秒 | マイク単独 | 方式1 | 方式2 |
|---|---|---|---:|---:|---:|
| run2 | 相手1 | 0〜10 | 0 | 0.06235 | 0.06235 |
| run2 | 自分1 | 10〜20 | 0.00975 | 0.01061 | 0.01424 |
| run2 | 相手2 | 20〜30 | 0 | 0.05203 | 0.05203 |
| run2 | 自分2 | 30〜40 | 0.01117 | 0.01117 | 0.01626 |
| run2 | 相手3 | 40〜50 | 0 | 0.08144 | 0.08144 |
| run2 | 自分3 | 50〜62 | 0.01625 | 0.01680 | 0.02362 |
| run6 | 相手1 | 0〜10 | 0 | 0.05371 | 0.05371 |
| run6 | 自分1 | 10〜20 | 0.02389 | 0.02389 | 0.03193 |
| run6 | 相手2 | 20〜30 | 0 | 0.06039 | 0.06039 |
| run6 | 自分2 | 30〜42 | 0.03390 | 0.03399 | 0.04617 |
| run6 | 相手3 | 42〜52 | 0 | 0.05672 | 0.05672 |
| run6 | 自分3 | 52〜62 | 0.02389 | 0.02471 | 0.03355 |
| run4 | 相手1 | 0〜10 | 0 | 0.08365 | 0.08365 |
| run4 | 自分1 | 10〜20 | 0.13741 | 0.13758 | 0.08626 |
| run4 | 相手2 | 20〜30 | 0 | 0.05767 | 0.05767 |
| run4 | 自分2 | 30〜42 | 0.09174 | 0.09440 | 0.05720 |
| run4 | 相手3 | 42〜52 | 0 | 0.06281 | 0.06281 |
| run4 | 自分3 | 52〜64 | 0.06942 | 0.06898 | 0.04318 |

### 音量調整を外した判断

- 進行役は交互素材の実測を受け、音量調整を外すと判断した。
  - 根拠: 方式1の自分の区間はほぼゲイン1で、マイク単独とRMSが近い。それでも双方の主要な発話が文字になった。
  - 境界: 小さい声が負ける重複発話は、タダシが受け入れると決めている。
- 調整を続ける代償が、補助機能としての利点を上回ると判断した。
  - 遅延: 方式2の先読みは、実機の速報表示に最大1秒を加える。
  - 雑音: 発話と同じblockの雑音は、発話に掛けるゲインで持ち上がる。
  - 除外: マイクの水準を変えると、小音量除外の効き方も変わる。
- 以下で、音量を変えずに足す形を同じ交互素材で再確認した。

### ゲイン1で加算した再検証

- 音量の推定・保持・先読みを削除し、同じ2本をサンプルごとにそのまま足した。
  - 保護: 各系統の非有限値を0へ置き換え、和を±1へ制限する。
  - 条件: 話者判別ありの等倍replay。原音とマイク単独の比較対象は上の2方式と同じ。
  - 保存先: 各fixtureのafter-unity。configは `work/alternating-run{2,6,4}-unity.toml`。
  - 記録: `work/alternating-run{2,6,4}-unity.log` と `-unity-rms.tsv`。

| 素材 | 双方の主要な発話 | 自分の名前付き話者数 | 最大絶対値 | ±1へ達したサンプル数 |
|---|---|---:|---:|---:|
| run2 | 3往復とも文字になった | 1 | 0.78482 | 0 |
| run6 | 3往復とも文字になった | 1 | 0.57525 | 0 |
| run4 | 3往復とも文字になった | 1 | 1.00000 | 169 |

- 自分の主要な発話の脱落は、3素材とも見つからなかった。
  - 比較: 同じmic.wavの単独replayの結果。
  - 限界: 単語の誤認、短い不明話者の断片、切断点をまたぐ文の割当は残る。相手の短い相づちにも違いがあり、全発話の完全一致は主張しない。
- 相手だけの3区間のRMSは、各素材とも上の方式1・方式2と同じ値だった。
- 自分だけの区間のRMSは次のとおり。
  - 条件: 区間全体のRMS。無音を含む。小数5桁へ丸めた。

| 素材 | 自分の出力秒 | マイク単独 | ゲイン1の加算 | 上限到達サンプル数 |
|---|---|---:|---:|---:|
| run2 | 10〜20 | 0.00975 | 0.00975 | 0 |
| run2 | 30〜40 | 0.01117 | 0.01117 | 0 |
| run2 | 50〜62 | 0.01625 | 0.01625 | 0 |
| run6 | 10〜20 | 0.02389 | 0.02389 | 0 |
| run6 | 30〜42 | 0.03390 | 0.03390 | 0 |
| run6 | 52〜62 | 0.02389 | 0.02389 | 0 |
| run4 | 10〜20 | 0.13741 | 0.13694 | 102 |
| run4 | 30〜42 | 0.09174 | 0.09149 | 30 |
| run4 | 52〜64 | 0.06942 | 0.06896 | 37 |

- run2とrun6の自分の区間は、マイク単独と同じRMSで文字になった。
- run4の169サンプルは、原音のマイクが±1を超えていた部分を±1へ制限した結果。
  - 影響: 3区間のRMSはわずかに下がる。音量を揃えるための増幅・減衰はしていない。
  - 割合: 全1,024,000サンプルの約0.0165%。
  - 境界: システム無音でのマイクの同値出力は、有限で±1以内の入力について確認する。大入力はピーク保護を優先する。
- 混合用の先読みは無くなった。
  - 検証: 16kHzの2サンプルをその呼び出しで返し、48kHz変換でも最初の入力から出力するテストが通った。
  - 限界: 実機の録音、許可拒否、切断時の復旧、長時間会議の品質は、この再検証では確認していない。
