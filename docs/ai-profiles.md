# AI設定の複数プロファイルと接続先の選択

`[ai]` を複数持ち、送信ごとに宛先を選び、会議前に用意した既存herdrペインへ送れるようにする設計。会議参加モードの契約は [ai-participant.md](ai-participant.md)、定期自動送信は [ai-scheduled.md](ai-scheduled.md) を引き継ぐ。既存docの「複数AIは対象外」はこの文書で改める。

## 確定した仕様

タダシとの質問票で決まっており、変えない。

- effortは専用キー `effort`。CLIごとに翻訳する。`extraArgs` との二重指定は拒否する。
- 複数設定は `[[ai]]` の配列。各要素に `name` を持ち、1つ目が既定。既存の単数 `[ai]` は互換で読む。
- 送信ごとに宛先を選ぶ。手動シートと自動送信シートにポップアップを置き、既定は1つ目、会議内では前回の選択を覚える。手動と自動で別のプロファイルを同時に使える。
- herdrセッション・世代・`AIStreamHistory` はプロファイルごとに持つ。会議内の `#n` は全体で通し、印とMarkdownの宛名で区別する。
- 会議前に利用者が起こした既存herdrペインへ接続する。KIKIGAKIは録音前に準備セッションを起こさない。
- プロファイルの `autoStart = true` で、録音開始時に `autoPrompt` と `autoIntervalMinutes` の自動送信を始める。

## 設定

```toml
[[ai]]
name = "議事録"
cli = "codex"
model = "gpt-5.4-codex"
effort = "high"
address = "迅雷へ"
cwd = "~/work/minutes"         # 明示すると、このcwdの稼働中ペインへ接続する。省略時は従来どおり新規起動
displayAgent = "迅雷"          # 同じcwdに複数のペインが並ぶときの追加の絞り込み。省略可
autoStart = true
autoPrompt = "会議の決定事項と担当・期限をMarkdown議事録へ更新してください"
autoIntervalMinutes = 3

# 配列表記では、この位置の [ai.hotkey] は直前の [[ai]] 要素に属する。
# ホットキーは1つ目のプロファイルにだけ書ける
[ai.hotkey]
modifiers = ["ctrl", "alt", "cmd"]
key = "a"

[[ai]]
name = "相談"
cli = "claude"
effort = "max"
address = "ネオへ"                # cwd も displayAgent も無いので、初回送信時に新規起動する
```

| キー | 既定と検証 |
| --- | --- |
| name | 省略時は `address` 末尾の「へ」を除いた参加者名。空・改行・NUL・前後空白のみを拒否し、64バイトまで。配列内の重複を拒否する。 |
| effort | 省略時はCLIの既定。単一行でNULを拒否し、CLIごとの値域で検証する。 |
| cwd | 省略時は従来どおり固定の `~/Library/Application Support/KIKIGAKI/ai-work/` を作って新規起動する。**明示すると接続先の絞り込み条件になる。** |
| displayAgent | 稼働中ペインの `display_agent` との完全一致。`cwd` と併せて絞り込む追加条件で、単独でも使える。 |
| autoStart | false。trueは配列全体で1つまで。`autoPrompt` が空なら設定エラー。 |
| hotkey | 1つ目のプロファイルにだけ書ける。2つ目以降にあれば設定エラー。 |
| その他 | 既存の `[ai]` と同じ。`cli` `command` `herdrCommand` `model` `address` `extraArgs` `prompt` `notifySound` `allowWork` `autoPrompt` `autoIntervalMinutes` を要素ごとに持つ。 |

単数 `[ai]` と配列 `[[ai]]` の併記は拒否する。TOMLの同名テーブルと配列は文法上も両立しないが、片方だけを黙って採らない。

### effortの翻訳と値域

| CLI | 渡し方 | 値域 |
| --- | --- | --- |
| codex | `-c model_reasoning_effort="<値>"` | none / minimal / low / medium / high / xhigh / max / ultra |
| claude | `--effort <値>` | low / medium / high / xhigh / max |

codexの値域は `codex-rs/protocol/src/openai_models.rs` の `ReasoningEffort` から採る。同リポジトリの `core/config.schema.json` はこのキーを「モデルが提示する非空の文字列」として自由文字列で定義しているため、実際に通る値はモデル依存になる。KIKIGAKIは列挙で先に弾き、CLIが拒否した場合は起動失敗として表示する。claudeの値域は `claude --help` の実測。

codexの `-c` の値はTOMLとして解釈されるので、文字列はクォートを付けて渡す。既存の `notify` と `sandbox_workspace_write.writable_roots` と同じ引数配列の作り方を使い、シェルを経由しない。

`extraArgs` の許可表から `--effort` を外す。旧設定で `extraArgs = ["--effort", "high"]` と書いていた場合は設定エラーにし、`effort` へ移すよう促す。黙って受理すると、翻訳した引数との順序依存で実際の効き方が読めなくなる。

## 送信ごとの宛先選択

手動シートと自動送信シートの先頭にポップアップを置く。既定は配列の1つ目、同じ会議内では前回選んだプロファイルを覚える。手動と自動は別々に覚える。

ポップアップの項目は2群に分ける。上段が設定のプロファイル、区切りの下が「稼働中のherdr agent」。下段はその場限りの宛先で、選ぶと `display_agent` から宛名を作り、CLI種別はペインの実物から採る。

シートの表題は選択に追随して「議事録へ 自動送信」のように変わる。接続状態・警告・「ペインを開く」も選択中のプロファイルのものを出す。手動シートを開いている間の自動tickスキップは、**同じプロファイルのときだけ**にする。別プロファイルなら手動と自動が同時に走ってよい(確定した仕様)。

印は既存どおり `#3 迅雷へ · 自動` の形で、`participant_name` から宛名を出す。番号は会議内の通し番号のままで、プロファイルごとには振り直さない。会議Markdownの `- 宛先:` も既存の生成をそのまま使う。

## 既存herdrペインへの接続

### herdrから採れる情報(実測)

`herdr agent list` と `agent get` が返すのは `pane_id` / `workspace_id` / `agent`(CLI種別)/ `agent_session.value` / `agent_status` / `cwd` / `foreground_cwd` / `display_agent` / `terminal_id` / `terminal_title` である。**`agent start <NAME>` で付けた名前はどちらにも返らない。** よって「herdrのagent名で指す」設計は成立せず、指せるのは `cwd` か `display_agent` か `pane_id` だけになる。設定キーを `agent` ではなく `cwd` + `displayAgent` にするのはこのため。

### 絞り込みの純関数

接続先の決定は `AIAgentResolver.resolve(candidates:criteria:provider:)` に閉じる。候補配列を受けて、一意の候補か失敗理由を返すだけの純関数で、herdr呼び出しも副作用も持たない。どのキーで絞るかは `AIAgentCriteria` に集めてあり、後から差し替えられる。

絞り込みは `cwd` → `displayAgent` の順で、**CLI種別は絞り込みに使わず最後の拒否条件にする**。種別で絞ると、条件が甘いまま偶然1件になった候補へ送ってしまう。失敗理由は `noCriteria`(条件なし)・`notFound`(0件)・`ambiguous`(複数件)・`kindMismatch`(種別違い)の4つで、いずれも**新規起動へ倒さない**。

`cwd` の比較は末尾の `/` と `.` の表記ゆれだけを吸収する。実体の同一性やシンボリックリンクは判定しない。herdrの `foreground_cwd` はworktreeへ入ると変わるので、ペインの `cwd` だけで比べる。

### 接続の契約

- 接続型では `workspace create` も `agent start` も `pane run` も行わない。既存の `pane_id` へ `agent prompt` するだけにする。
- 接続時に `pane_id` `workspace_id` `agent` `agent_session.value` `terminal_id` を `AIHerdrConnection` へ保存し、以後の同一性判定は既存の `observe` と同じ照合を使う。`display_agent` と `cwd` は選ぶときだけ使い、同一性判定に使わない。利用者がいつでも変えられるため。
- 設定の `cli` と実物の `agent` が食い違ったら拒否する。実物を優先して黙ってCLIを切り替えない。対応外のkind(`pi` `gemini` など)も拒否する。
- **絞った結果が0件か2件以上なら失敗**にする。`display_agent` はペイン単位で重複でき、同じメンバーの複数セッションが日常的に並ぶ。自動送信は非対話で決まるので、黙って別のペインへ送るほうが危険である。シートでは全候補を `cwd` と `terminal_title` 付きで並べ、利用者に選ばせる。
- 同じ条件へ解決するプロファイルが2つ以上あれば設定エラーにする。streamと世代が別なのに同じCLI文脈へ2本の会話が混ざり、受領基準がずれる。
- ペインが消えた後は既存の切断扱い(`agent_not_found` → `.disconnected`)。**新規起動へ倒さない。**
- 接続先のcwdをKIKIGAKIが書き換えることはしない。`cwd` はあくまで探すための条件である。

### 接続型で失われるもの

KIKIGAKIが起動しないので、起動時にしか渡せない設定を渡せない。文書に明記し、シートの選択時にも短く示す。

- **返し忘れ検知が使えない。** Claudeの `--settings` によるStopフックも、Codexの `notify` 差し替えも仕込めない。`AIReturnStatus` の「返送未確認」表示は接続型のチャネルでは出さず、herdrの接続状態だけを表示する。返送そのものは同梱CLIの契約で従来どおり動く。
- **Codexのサンドボックス許可を足せない。** `-c sandbox_workspace_write.writable_roots` を渡せないため、`workspace-write` の接続先では同梱CLIの返送が `unsafe_file` で落ちる。会議の保存先が接続先のcwd配下にない限り再現する既知の失敗である。
- **Claudeの返送コマンド許可を足せない。** `permissions.allow` に同梱CLIを追加できないので、返送のBash実行が利用者への確認になり得る。ペインで一度許可してもらう。

Codexの読み取り側は `workspace-write` でも広いため、cwd外の会話ファイル(snapshotの絶対パス)を読めるかは段4で実測する。読めない構成があれば、その組み合わせを接続型の対象外として明記する。

## 録音開始時の自動送信

`autoStart = true` のプロファイルがあれば、録音開始で既存の `startAISchedule` を呼ぶ。プロンプトは `autoPrompt`、間隔は `autoIntervalMinutes`、作業許可は `allowWork`、録音停止時の最後の1回はON。既存契約どおり即時送信はせず、開始から1間隔後を初回期限にする。

接続先が解決できない場合(条件に合うペインが無い、または複数該当)は、その場で失敗を表示して自動送信を開始しない。新規起動へは倒さない。`cwd` も `displayAgent` も持たないプロファイルは従来どおり初回送信時に新規起動する。

開始後の操作は既存と同じ。「自動送信を停止」で録音を続けたまま止められ、設定を変えるにはいったん止めてシートを開き直す。状態行は「自動送信 3分 · 次 12:34 · 議事録へ」とし、宛先を含める。稼働状態は新会議・再起動で引き継がない。

## データ構造と保存

### 会議に1つの会話、プロファイルごとのチャネル

`AIConversationController` は会議に1つのまま残し、内部に**チャネル**をプロファイル分持つ。チャネルが持つのは `AIStreamHistory`、世代、`AISessionRecord`、`AIHerdrConnection`、接続状態、固定した設定、警告である。

controllerをプロファイルごとに複数へ分ける案は採らない。`AIConversation` が `request.number == index + 1` を復号時に検証しており、`archive.original.ai` も1つの会話を前提にしている。分けると通し番号・Markdown生成・保存・登録簿の再設計が連鎖する。受信箱はrequest ID単位なので、そもそも分ける必要がない。

チャネル化で変える判定は次の3つ。

- `canSend`: 現在は現世代の返事待ちを会話全体から探している。**そのチャネルの世代に属するrequestだけ**で判定する。これが手動と自動を別プロファイルで同時に走らせる根拠になる。
- `prepare` の設定等価性検証: チャネルが固定した設定とだけ比較する。
- `scanHooks` の休止判定: チャネルの `session` と世代でだけ突き合わせる。接続型のチャネルはフックが来ないので判定自体を行わない。

`AIRecordStore.Record` は会議に1つのまま。`saveResult` `savedConversation` `needsRecovery` と登録簿の扱いは変えない。

### パスとenvelope

session recordの置き場を `ai/sessions/<slot>/<generation>.json` へ変える。`<slot>` は会議開始時にプロファイルへ割り当てた1始まりの整数で、設定の並び順から作る。`name` は日本語や記号を含むためパスへ持ち込まない。

`AIParticipantContext` に任意キー `profile`(表示名)と `profile_slot`(整数)を足す。`trigger` と同じ扱いで、`schema_version` は1のまま、欠損は既定プロファイル・slot 1として読む。`AIEnvelope.validate` の `sessionPath` 検証は、slotがあれば `ai/sessions/<slot>/<generation>.json`、無ければ従来の `ai/sessions/<generation>.json` を要求する。

manifestは `schemaVersion` を2へ上げ、`config` を `profiles: [ResolvedAIProfile]` の配列にする。schemaVersion 1のmanifestは、slot 1・`name` を参加者名としたプロファイル1つとして読む。

`.kikigaki-context/<meeting>/ai/` の `state.json` `archive.json` `requests/` `inbox/` `generation.json` は形も置き場も変えない。`generation.json` だけはチャネル別になるので `ai/sessions/<slot>/generation.json` へ移す。

## 互換

- 単数 `[ai]` の設定はそのまま動く。slot 1、`name` は参加者名。
- 旧manifest(schemaVersion 1)を持つ会議は回収できる。旧requestは `profile` を持たないので slot 1 として表示し、旧 `sessionPath` 形式で検証する。
- 旧 `state.json` と `archive.json` はそのまま読める。`AIConversation` の形を変えない。
- 旧 `ai/sessions/<generation>.json` は残したまま読み、新規は必ずslot付きで書く。同じ会議を新旧アプリで交互に開く運用は想定しない。
- 配布用Skillの契約は変えない。envelopeの追加キーは既知の任意キーとして無視されてよい。

## 検証する境界

保証しないことを先に書く。

- 接続型ではCLIの権限・サンドボックス・フックをKIKIGAKIが設定しない。返送が通るかは接続先の設定に依存する。
- 会議前に用意したペインが何を読んでいたかをKIKIGAKIは知らない。文脈の連続性は利用者の準備の結果であり、KIKIGAKIの保証ではない。
- 複数プロファイルへ同時に送っても、AI同士は互いの回答を見ない。同じ会議の同じ範囲を別々に読むだけである。
- `display_agent` は接続後に変わり得る。表示と実際の接続先が食い違う可能性は残る。

## 実装順

| 段 | 内容 |
| --- | --- |
| 2・Core | `AIProfileList` の解析(配列・単数互換・name重複・autoStart重複・hotkeyの位置・effort値域・extraArgs二重指定・同条件の重複)、`AIEffort` の翻訳、接続先解決の純関数 `AIAgentResolver`、`participant.profile` / `profile_slot` の往復と旧欠損、`sessionPath` の新旧検証、manifest schemaVersion 2と1の読み分け。**完了** |
| 3・アプリ | チャネル化した `AIConversationController`、`herdr agent list` の解釈と接続型の `connect`、両シートのポップアップと会議内の記憶、`autoStart`、状態行・警告・ピルの宛先表示、接続型でのフック判定の無効化 |
| 3・実画面 | 600・900幅でポップアップ、複数プロファイルの印が積んだ会議、接続型の警告、解決失敗の表示を撮影して目視 |
| 4・replay | 手動と自動で別プロファイルへ同時送信、片方の返事待ちがもう片方を止めないこと、`autoStart` の初回期限、接続先解決失敗で自動送信が始まらないこと |
| 4・実herdr | 稼働中ペインへの接続と返送、Codex接続型での `unsafe_file` の再現と回避、`displayAgent` 重複時の失敗、ペイン消失後の切断表示 |

各段のコミット前に `swift build` と `swift test` を通す。

## 対象外

- 3つ以上のプロファイルを自動送信で同時に回すこと。自動送信の状態機械は会議に1つのままにする。
- KIKIGAKIが会議前に準備セッションを起こすこと。連続する会議での取り違えを避けるため作らない。
- 接続先のCLI設定・サンドボックス・信頼設定をKIKIGAKIが書き換えること。
- プロファイルごとのホットキー。既存の1つで既定プロファイルのシートを開く。
- 音声からの宛先自動判別。宛名で呼ばれたAIへ自動で振り分けることはしない。

## 採用した判断

段1のレビューで決めた。段2はこの形で実装してある。

- **`autoStart` は配列全体で1つまで。** 自動送信の状態機械 `AIScheduleState` は会議に1つで、複数同時は期限・失敗回数・最後の1回の権利をすべて多重化する。必要なら段を分ける。
- **その場限りの「稼働中herdr agent」宛先を許し、選んだ時点でad hocプロファイルとしてmanifestへ残す。** requestのenvelopeがプロファイルを参照するので、記録の側に定義が無いと過去会議を復元できない。
- **接続型のチャネルが切断しても「作り直す」を出さない。** 準備済みの文脈が接続の目的なので、空のセッションを新規に起こしても目的を満たさない。「別のペインへ接続し直す」だけにする。
- **`extraArgs` での effort 指定は設定エラーにする。** 受理すると翻訳した引数との順序依存になり、どちらが効くか読めない。移行は1行の書き換えで済む。
- **`name` の既定は参加者名。** 重複したときだけ明示を必須にする。画面のポップアップは宛名で識別するのが自然で、設定の記述量も増えない。
- **ホットキーはプロファイルごとに持たない。** 既存の1つで既定プロファイルのシートを開き、宛先はシート内で選ぶ。プロファイル数だけ予約すると録音・一時停止との衝突検証が組み合わせで増える。

## 判断依頼

タダシへ確認する。段3の前に決まればよい。

1. **接続先の指定キー**。採用案は `cwd` で候補を絞り、`displayAgent` を任意の追加条件にする(少なくとも一方が必要、0件と複数件は失敗)。理由: `display_agent` だけでは同じメンバーの複数セッションが日常的に並んで失敗し続ける。会議前に用意するペインはワークスペースごとに立つので、`cwd` のほうが安定した鍵になる。代替は `displayAgent` だけで絞る案と、ペインの表題で絞る案。表題は作業内容で刻々と変わるので推さない。
2. **Codex接続型の返送**。推奨は、接続先がcodexのとき利用者の `~/.codex/config.toml` の `writable_roots` に会議の保存先が含まれるかを起動前に読んで確認し、無ければシートに警告を出す。既存の `CodexUserConfig.writableRoots` をそのまま使える。理由: KIKIGAKIが起動しない以上 `-c` を渡せず、設定ファイルの自動書き換えは既存契約で禁じている。代替はClaudeを接続型に使うこと(Bashに同じ制限が無いと実測済み)。
