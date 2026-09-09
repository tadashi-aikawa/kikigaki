# 複数プロファイルの結合検証

> ここで検証した「利用者が手で起こした既存herdrペインへ接続する」案は、この検証の結果を受けて段5で取り下げた。接続型ではフックもサンドボックス許可も渡せず、返送の成否が接続先の設定に左右されるため。差し替え後の設計は [AI設定の複数プロファイル](ai-profiles.md) を参照する。**この記録は取り下げの根拠として残す。**

2026-09-09、`feature/ai-profiles` の段4で実施。接続先は両方ともClaude Code 2.1.266のペインにし、Codexのサンドボックスの話とは切り離した。設計は [AI設定の複数プロファイル](ai-profiles.md) を参照。

音声は `say -v Kyoko` で作った架空の会議に無音を足した262秒だけ。実データを含み得る既存WAVは使っていない。音声認識の精度を測る検証ではない。

会議前のペインは利用者の手順どおり `herdr workspace create` と `herdr agent start` で用意し、Claudeの信頼確認もペインで承認した。KIKIGAKIはこの2つを一切呼ばない。導入先Skillは各ペインのcwd配下 `.claude/skills/kikigaki` へ置いた。

## 設定

```toml
[[ai]]                                   # 手動の宛先
name = "相談"
cli = "claude"
address = "ネオへ"
attach = true
cwd = ".../pane-advice"

[[ai]]                                   # 自動の宛先
name = "議事録"
cli = "claude"
address = "迅雷へ"
attach = true
cwd = ".../pane-minutes"
autoStart = true
autoPrompt = "今回受領した架空の会話の決定事項を1文で返してください"
```

## 手動と自動が別のAIへ同時に飛ぶ

証跡は `/private/tmp/kikigaki-profiles-replay/run2.log` と `run2/`。meeting IDは `7A8F45D8-1561-416D-B4CD-B613F744DFC9`。

- 手動: `KIKIGAKI_DEBUG_AI_ASK_PROFILE=相談` と `KIKIGAKI_DEBUG_AI_ASK="60:この段取りで抜けている観点を1つだけ挙げてください"`
- 自動: 設定の `autoStart` を `KIKIGAKI_DEBUG_AI_AUTO_SECONDS=20` で20秒間隔に短縮
- 終了待ち: `KIKIGAKI_DEBUG_REPLAY_HOLD=300`

| 送信 | 宛先 | slot | pane | stream | 起動原因 | 結果 | isUnread |
|---|---|---|---|---|---|---|---|
| #1 | ネオ | 1 | w6H:p1 | E27FD252 | 手動 | answered | true |
| #2 | 迅雷 | 2 | w6G:p1 | F7780951 | scheduled | answered | false |

**#1を13:08:22に送り、その返事が届く13:09:03より前の13:08:35に#2を送った。** 単一チャネルの頃は `canSend` が返事待ちで塞ぐため、これは成立しなかった。session recordは `ai/sessions/1/1.json` と `ai/sessions/2/1.json` に分かれ、接続先のpaneも別だった。番号は会議内の通しで、会議Markdownの `- 宛先:` はネオと迅雷に分かれた。自動の送信印にだけ `(自動)` が付き、自動のansweredは未読にならなかった。

返事は2つのペインがそれぞれの人格で返し、内容も宛先ごとの依頼に沿っていた。

## 接続先が一意に決まらないとき

`herdr workspace create` で同じcwdのペインをもう1つ立て、`議事録` の条件に2件が該当する状態を作った。証跡は `run3.log`。

```text
Kikigaki: replay autoStart: 議事録(slot 2)へ 20.0秒間隔
Kikigaki: autoStartの宛先を解決できない: 条件に合うペインが2件あります。cwd か displayAgent を足して絞ってください
```

自動送信は理由を出して止まり、`.kikigaki-context` 自体が作られなかった。requestもsession recordも0件で、**新しいworkspaceは1つも増えていない**。

段4の前は、宛先の確認が最初の送信時にしか走らず、決まらないまま利用者を1間隔ぶん待たせていた。設計文書の「その場で失敗を表示して自動送信を開始しない」と実装が食い違っていたので、開始直後に候補を引いて確かめる経路を足した。0件と2件以上のどちらもアプリテストで固定した。

## 用意したはずのペインが消えていたとき

`herdr workspace close` で接続先のペインを閉じてから手動送信した。証跡は `run4.log` と `run4/`。

requestは `failed` で終わり、session recordは書かれず(起動意図の `1.launch.json` だけ)、**herdrのペイン一覧は増えなかった**。新規起動への切り替えは起きない。

接続中のペインが途中で消えた場合の「切断」表示そのものは、`agent get` の `agent_not_found` を `.disconnected` に変える経路のユニットテストで確かめている。この実herdr検証で画面表示までは確認していない。

## 段4で見つけて直した欠陥

**同梱CLIがプロファイルの枝を解釈できず、返送が全滅した。** 最初の実herdr実行で、両方のペインが `kikigaki-cli accept` の `unsafe_file` を報告した。CLIは `--session` のパスから保存先の根を割り出すのに平置きを前提として決め打ちで5階層を遡っており、`ai/sessions/<slot>/<generation>.json` では検証に落ちていた。

段2・段3のテストがこれを捕まえられなかった理由は2つある。アプリ側のテストはCLIを実行せず、CLIのテストは平置きのfixtureしか作っていなかった。枝の有無で遡る階層を変え、CLIのテストに枝ありのfixtureと不正な枝番号の拒否を足した。

あわせて、接続型でも起動引数とClaudeのフック設定を作っていたのをやめた。誰も読まない設定ファイルが会議ごとに残り、接続するだけなのにCLIの実行ファイルが要る状態になっていた。

## 自動テスト

`swift build` と全352テストが成功。`CODESIGN_IDENTITY=none ./scripts/make-app.sh` で組んだ `.app` と同梱CLIを使い、返送を模倣するfixtureは使っていない。実際のClaudeが改訂Skillを読み、`accept` と `reply` を呼んだ。

replayの追加入力は通常起動では解釈せず、`--smoke --replay` で空・0・負数・非有限秒・上限超過・改行・NULを拒否することをテストで固定した。

---

# 準備済みセッションの結合検証(段8)

> 以下は初回の記録。会話が0行だったCodex返送と、紐づけ前の取消だけでは完了条件を満たしていなかった。証跡の補完結果は末尾の「段8の再検証」に記録する。

2026-09-09、`feature/ai-prepared` の段8で実施。上の記録とは別の案(会議に紐づかない準備済みセッションを起こして紐づける)の検証で、こちらが現行の設計。

音声は `say -v Kyoko` で作った架空の会議24秒だけ。実データを含み得る既存WAVは使っていない。音声認識の精度を測る検証ではない。

## 設定

```toml
outputDir = ".../out2"

[[ai]]                                   # 自動の宛先。準備済みを紐づける
name = "議事録"
cli = "claude"
address = "迅雷へ"
autoStart = true
autoPrompt = "この会議の決定事項を3行以内で箇条書きにして返してください。ファイルは作らないでください"
autoIntervalMinutes = 1

[[ai]]                                   # 手動の宛先。準備済みを紐づける
name = "相談"
cli = "codex"
address = "ネオへ"
```

`cwd` は省略し、既定の `~/Library/Application Support/KIKIGAKI/ai-work` を使った。新しいディレクトリを指定するとClaudeもCodexも初回の信頼確認でペインが `blocked` のまま止まる。**これは設計どおりの挙動**(利用者がペインで承認する)で、検証を自動で回すために既に信頼済みのcwdを選んだ。

## replayの追加入力

段8で足した3つ。通常起動では解釈せず、`--smoke --replay` で形式だけ検証できる。

- `KIKIGAKI_DEBUG_AI_PREPARE="議事録;相談"`: 録音を始める前に、本番の `prepare` でその名前のプロファイルを起こす
- `KIKIGAKI_DEBUG_AI_ATTACH="1=oldest;2=oldest"`: 枠ごとの紐づけの選択。`oldest` は最も古い準備済み、`new` は新規に起動する。本番の `applyPreparedSelection` を通す
- `KIKIGAKI_DEBUG_AI_ATTACH_CANCEL=1`: 紐づけシートの「取消(録音を始めない)」と同じ `abandon()` を通す

## 連続2会議

同じ設定・同じ保存先で2回続けて実行した。どちらの会議も、開始前に2つのプロファイルを準備し、両方の枠へ最も古い準備済みを紐づけた。

| | 会議1 | 会議2 |
| --- | --- | --- |
| 準備 | 議事録・相談の2件 | 議事録・相談の2件(会議1のものは使用済み) |
| 紐づけ | `1=oldest,2=oldest` 失敗なし | `1=oldest,2=oldest` 失敗なし |
| 自動送信 | 議事録(Claude)へ25秒後 | 議事録(Claude)へ20秒後 |
| 手動送信 | 音声が24秒で終わり未到達 | 相談(Codex)へ10.5秒 |
| 返送 | `answered` 1件を回収し保存 | `answered`(議事録)と `needs_input`(相談)を回収し保存 |

会議2の保存Markdownには、手動 `#1 ネオへ`・自動 `#2 迅雷へ(自動)`・`#1 の確認`・`#2 からの返事` が通し番号で並んだ。**準備済みの2つのCLIが同じ会議で並走し、それぞれのstreamで受領した。**

### Codexの返送許可(`contextWide`)

会議2の相談(Codex)は、準備時に `sandbox_workspace_write.writable_roots` へ `out2/.kikigaki-context` 全体を許可した状態で起動している。紐づけた先の会議は起動時には決まっていない別UUIDの枝だが、`accept` と `reply` は落ちずに `needs_input` を書き込めた。**会議ごとの枝だけを許可していた実装では、ここで `unsafe_file` になる。**

Claude側は `permissions.allow` に同梱CLIのBash実行を1つ足すだけでパスを条件にしていないため、準備済みでも会議から起こしたものと同じ規則で足りることを実機でも確認した。

## 取消(録音を始めない)

準備を1件起こしてから録音を開始し、`abandon()` を通した。結果は次のとおり。

- 保存 `false`。保存先に新しい `.md` は増えていない
- その会議の `.kikigaki-context/<会議ID>` は存在しない
- `ai-roots.json` にその会議IDは無い
- 準備した1件は**未紐づけのまま台帳に残り**、次の録音で選べる

## 段8で分かったこと

- 準備の起動そのものは `herdr agent start: agent_not_ready` を1回報告することがある。これは `pane run` で起こした直後にherdrがまだagentを検知していない既知の状態で、その後の起動と送信は通った
- ペインの表題はClaudeが起動後すぐに設定した(`kikigaki 会議の決定事項`)。Codexは `ai-work` のままだった。**表題が無い・素っ気ない状態は異常ではない**という設計の判断どおり

## 自動テスト

`swift build` と全429テストが成功。`.app` と同梱CLIを使い、返送を模倣するfixtureは使っていない。実際のClaudeとCodexが `accept` と `reply` を呼んだ。

## 段8の再検証

2026-09-09、修正済みの `dfcfe93` と診断ログ追加の `092e6fd` を引き継いで不足分を検証した。証跡は `/private/tmp/kikigaki-prepared-verify2/`。

### 録音中に次会議用を準備

前の担当が取得した `runA.log` を `previous-recording-prepare.log` として保存した。会議1の録音中、状態 `recording`・経過5.5秒で相談プロファイルの準備を開始し、未紐づけ1件として完了している。元の証跡は `/private/tmp/kikigaki-prepared-verify/` にある。この準備は次の会議のためのもので、会議開始前に準備した初回記録とは区別する。

### 会話本文を含むCodex返送

今回起動したAIは両方ともCodex、モデル `gpt-6-astra`、effort `low`。Claudeは起動していない。検証設定の全文は `config.toml`、ペインのモデル表示と実際の `accept`・`reply` は `codex-reply-pane.txt` に保存した。`cwd` は信頼済みの既定ディレクトリを使った。

音声は前の担当が `say -v Kyoko` で生成した架空会議 `meeting-long.wav` をコピーしたもの。実長44.9375秒で、実会議の録音は使っていない。`CODESIGN_IDENTITY=none ./scripts/make-app.sh` で組んだアプリと同梱CLIを実行した。

```text
KIKIGAKI_DEBUG_AI_PREPARE=議事録;相談
KIKIGAKI_DEBUG_AI_ATTACH=1=oldest;2=oldest
KIKIGAKI_DEBUG_AI_AUTO_SECONDS=12
KIKIGAKI_DEBUG_REPLAY_HOLD=140
```

| 項目 | 結果 |
| --- | --- |
| 会議ID | `64D30263-7C2D-4448-9A19-38220989933C` |
| 準備済みの紐づけ | 議事録 `w7E:p1`・相談 `w7F:p1`、失敗なし |
| 送信 | 議事録へ自動 `#1`、20:13:03 |
| request ID | `81DFC975-0F20-485D-AD97-46102DABFB6B` |
| 会話範囲 | `read_line_count = 1`、架空会議の発話本文を含む |
| 受領・返送 | 20:13:25に受領、20:13:38に `answered` |
| 保存 | `out/2026-09-09_2012_2.md` に自動送信印・受領時刻・返事を保存 |

返事は本社大会議室・参加者20名・松村さん担当・来週金曜期限・備品3万円など、実際に渡した本文の決定事項と一致した。アプリの受信箱と状態ファイルにも実CLIの返送が残っている。

今回のreplayは約5秒で音声を流し終えるため、12秒の通常期限より録音停止が先になる。**初回は `autoStart` で有効になった自動送信の、停止時の最後の1回**である。録音中の通常期限による送信成功を示す証跡ではない。

最初の試行 `reply.log` は保存先 `out` がまだ存在せず準備に失敗した。`AIFileStore` が既存のルートディレクトリを開く実装で、録音開始が保存先を作るより先に準備を呼ぶため。保存先が存在する状態で再実行した `reply2.log` が成功の証跡である。この所見は後続の修正で対応した。準備時も会議開始と同じ方法で保存先を作り、session保存で `.kikigaki-context` を0700で作成してから、起動時の許可先へ渡す。

回帰テストは未作成の多段の保存先から準備を実行する。起動時点での許可先の実在、起動引数、0700の権限、sessionファイル、台帳の再読込を確認する。旧挙動では準備失敗と候補なしで落ち、修正後は成功した。証跡は `missing-output-red.log` と `missing-output-green.log`。

### 紐づけ後の取消

同じ設定で相談の準備済みを1件追加し、`KIKIGAKI_DEBUG_AI_ATTACH=2=oldest` と `KIKIGAKI_DEBUG_AI_ATTACH_CANCEL=1` を指定した。準備には `KIKIGAKI_DEBUG_AI_PREPARE=相談` を使った。`saveRecording = true` でWAVも取消対象に含めた。

```text
replay 取消前の紐づけ: 失敗 [] 紐づけ済み 3件
replay 取消: 会議 0709B3EE-90EA-4EE1-B137-AE55C3EF8658 保存 false 残り [] 未紐づけ 1件
```

取消前の3件は前の会議に紐づいた2件と、今回紐づけた `w7G:p1` の1件。取消後の台帳 `ledger-after-cancel.json` では、今回の準備済み `0BCA1DC5-8B67-4AB4-89D7-D60514A02695` だけが未紐づけへ戻り、前の会議の2件は紐づいたままである。

`cancel.log` の終了コードは0。アプリは取消前の会議IDと保存先を固定して、Markdown・WAV・会議の置き場・登録簿・紐づけ・片付け残しを検査した。終了後にも次を確認した。

- `out/2026-09-09_2015.md` と同名WAVは存在しない。
- `out/.kikigaki-context/0709B3EE-90EA-4EE1-B137-AE55C3EF8658` は存在しない。
- `roots-after-cancel.json` に取消対象の会議IDはない。
- 台帳に取消対象の紐づけはなく、今回の準備済みは未紐づけで残る。

準備時のフック用ディレクトリは、未紐づけへ戻ったセッションのために残る。削除対象である実会議の置き場とは別である。

### 検証と後片付け

`swift build`、全437テスト、アプリと同梱CLIの署名検証が成功した。ログは `build.log` と `tests.log`。今回は表示の変更と新たな画面撮影は行っていない。実Codexの端末表示とアプリが保存した会議Markdownを確認した。

検証で起動したworkspace `w7E`・`w7F`・`w7G` はすべて閉じた。最終一覧は `workspaces-after-cleanup.json`。開始時に存在しなかった `ai-prepared.json` は、この検証の3件だけを含むことを確認し、証跡をコピーしてから削除した。会議の登録簿は残し、既存の会議登録を変更していない。

### Opus 5の統合前確認への対応

準備時にフック用の空の `ai/inbox` を作成し、最初のnotifyが届く前の走査でも警告しないようにした。未紐づけを破棄・ペイン消失で台帳から外す場合は、台帳の保存後に準備用の置き場を削除する。削除できない場合は警告し、同じアプリ内の次の一覧更新で再試行する。紐づけ済みは削除対象にしない。

紐づけシートの選択待ちでは全枠の手動送信を表示と入口の両方で止める。候補の選び直しは、紐づけ処理と同じく会議に固定したプロファイルと保存先を使う。次の録音を始める前の候補は現在の設定を使う。

4件の回帰テストを修正前に実行し、すべて失敗することを確認した。破棄とペイン消失は引数を分けて両経路を通した。修正後は同じ4件が成功し、台帳保存失敗時の保持と紐づけ済みの保護も追加で確認した。`swift build` と全444テストが成功。証跡は `opus-review-red.log`・`opus-review-green.log`・`opus-review-build.log`・`opus-review-tests.log`。この対応では実AIセッションの追加起動やUI撮影は行っていない。
