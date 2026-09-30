# AI設定の複数プロファイル

`[[ai]]` を複数持ち、送信ごとに宛先を選べる。会議参加モードの契約は [ai-participant.md](ai-participant.md)、定期自動送信は [ai-scheduled.md](ai-scheduled.md) を参照する。利用者が手で起こした既存herdrペインへ接続する案と、会議に紐づかない準備済みAIセッションは取り下げた。経緯は「取り下げた案(経緯)」にある。

## 確定した仕様

タダシとの質問票で決まっており、変えない。

- effortは専用キー `effort`。CLIごとに翻訳する。`extraArgs` との二重指定は拒否する。
- 複数設定は `[[ai]]` の配列。各要素に `name` を持ち、1つ目が既定。既存の単数 `[ai]` は互換で読む。
- 送信ごとに宛先を選ぶ。手動シートと自動送信シートにポップアップを置き、既定は1つ目、会議内では前回の選択を覚える。手動と自動で別のプロファイルを同時に使える。
- 通常の手動実行も宛先の `autoPrompt` を初期表示する。空欄を含む編集内容は宛先ごとに保持し、送信後やシートの開き直しでも復元する。自動実行の下書きとは独立し、新しい録音でリセットする。確認への返答・失敗した依頼の再送にはこの初期値を使わない。
- herdrセッション・世代・`AIStreamHistory` はプロファイルごとに持つ。会議内の `#n` は全体で通し、印とMarkdownの宛名で区別する。
- AIセッションはKIKIGAKIが `workspace create` と `agent start` で起こす。フック・サンドボックス許可・返送コマンド許可を渡せる形を保つ。
- プロファイルの `autoStart = true` は、録音開始シートの自動送信の宛先の既定になる。自動送信の始まり方は [ai-scheduled.md](ai-scheduled.md) を参照する。

## 設定

`[[ai]]` がなければ新規送信の操作・外部起動を有効にしない。過去に送信済みの会議が登録されている場合は回答記録の回収だけ続ける。空の `[ai]` は既定値で有効。設定は録音開始時に固定し、途中の再読込では次の録音から適用する。保存先や参加者を進行中の質問で変更しない。

```toml
[[ai]]
name = "議事録"
cli = "codex"
model = "gpt-5.4-codex"
effort = "high"
address = "迅雷へ"
cwd = "~/work/minutes"         # 起動時の作業ディレクトリ。省略時は固定の既定
autoStart = true
autoPrompt = "会議の決定事項と担当・期限をMarkdown議事録へ更新してください"
autoIntervalMinutes = 3

[[ai]]
name = "相談"
cli = "claude"
effort = "max"
address = "ネオへ"                # cwd を省いたので既定のディレクトリで起動する
```

| キー | 既定と検証 |
| --- | --- |
| name | 省略時は `address` 末尾の「へ」を除いた参加者名。空・改行・NUL・前後空白のみを拒否し、配列内の重複を拒否する。**64バイトの上限は明示した `name` にだけ掛ける。** 宛名から補った名前は対象外で、`address` の長さは単数設定の頃から制限していない。上限を送信側にも掛けると、長い宛名の設定が解析を通るのに送信準備で落ちる。 |
| cli | codex。codexまたはclaudeのみ。 |
| command | 省略時は選択CLIをPATHと既知の置き場(下記)で解決し、絶対パスと実行可能性を検証する。指定時は空でない絶対パス。見つからなければ送信前に原因を示し、別CLIへ切り替えない。 |
| herdrCommand | **共通**。省略時は `herdr` をPATHと既知の置き場で解決する。指定時は空でない絶対パス。2つ目以降は省略でき、先頭の値を引き継ぐ。先頭と違う値を明示したときだけ設定エラー。 |
| model | 省略時はCLIの既定。指定時は空でない単一行の文字列として該当CLIのモデル引数へ渡す。 |
| effort | 省略時はCLIの既定。単一行でNULを拒否し、CLIごとの値域で検証する。 |
| address | 迅雷へ。空・改行・制御文字を拒否。起動時の表示名にも使用する。 |
| avatar | 省略時は紫のイニシャル。ローカルパスまたはhttp/httpsのURL。下記の「アバターの指定」を参照。 |
| cwd | 省略時は従来どおり固定の `~/Library/Application Support/KIKIGAKI/ai-work/`。起動時の作業ディレクトリで、プロファイルごとに変えられる。指定時は絶対パスまたは先頭の `~/` を解決し、存在するディレクトリであることを確認する。 |
| extraArgs | 空配列。引数の配列でありシェル文字列ではない。下記の規則で検証する。 |
| prompt | 空文字列。利用者が指定する追加指示。32 KiBまで。接続プロトコルを上書きする位置へ置かない。 |
| notifySound | false。trueのときだけ、返事が届いた枠の設定でアプリから通知音を鳴らす。 |
| allowWork | true。送信シートの「作業を許可する」の初期値。会議内の変更を次の質問にも引き継ぎ、新しい録音で設定値へ戻す。 |
| autoStart | false。trueは配列全体で1つまで。`board` を指定しない宛先は `autoPrompt` が空なら設定エラー。録音開始シートの宛先の既定になる。 |
| autoPrompt | 空文字列。手動・自動実行シートと録音開始シートのプロンプトの初期値。32 KiBまで。 |
| autoIntervalMinutes | 3。1〜60分。 |
| board | 省略時はボードなし。単一のMarkdown見出し(`#` から `######`)で、配列内の重複を拒否する。 |
| boardPrompt | `board` があるときだけ指定できる。省略時は内蔵のボードプロンプト。 |
| boardLocation | `board` があるときだけ指定できる。議事録のパスが無いときの作成指示。 |
| hotkey | **廃止**。書かれていても読み飛ばし、エラーにも警告にもしない。 |
| attach / displayAgent | **取り下げ**。書くと設定エラーにする。 |

単数 `[ai]` と配列 `[[ai]]` の併記は拒否する。TOMLの同名テーブルと配列は文法上も両立しないが、片方だけを黙って採らない。

`board` を指定した宛先は、自動だけ内蔵のボードプロンプトを使い、`autoPrompt` は手動の初期値に残す。`boardPrompt` で全文差し替えが可能。`autoStart` はboardがあれば `autoPrompt` の省略を許す。詳細は [議論のボード](board.md)。

### CLIとherdrの実行ファイルの探し方

GUI起動ではPATHに普段のCLIがない(実測: Finderや `open` から起動した.appは `/usr/bin:/bin:/usr/sbin:/sbin` だけで、miseやHomebrewの herdr・codex・claude を見つけられない)。PATHで見つからなければ `~/.local/bin`、`~/.local/share/mise/shims`、`/opt/homebrew/bin`、`/usr/local/bin` の順に探す。それでも見つからなければ `command` / `herdrCommand` の絶対パス指定を案内し、環境設定を自動変更しない。herdrが未導入なら手動コピーは使える状態でAI送信だけを失敗にする。

### extraArgs

`extraArgs` は、値の個数と意味を確認できる追加指定だけを受け付ける。NUL、対話モードを変えるprint/exec、resume、接続先・model・hooksを上書きする衝突指定は拒否する。

| CLI | 値なしの指定 | 既知の値だけを受ける指定 | 絶対パス一つを受ける指定 |
| --- | --- | --- | --- |
| codex | `--search`、`--no-alt-screen`、`--strict-config` | `--sandbox` / `-s`(read-only・workspace-write・danger-full-access)、`--ask-for-approval` / `-a`(on-request・never) | `--add-dir` |
| claude | `--verbose` | `--permission-mode`(default・manual・acceptEdits・plan・auto・dontAsk) | `--add-dir` |

権限モードは利用者が明示した場合だけ渡し、アプリが自動で追加しない。`--key=value` も同じ検証を通す。その他のオプション、起動時prompt、サブコマンド、結合した短縮引数は送信前に拒否する。Codexの自由な `-c/--config` は、notify等への上書き経路になるため受け付けない。将来の追加はキーと値の規則をテストしてから行う。

### effortの翻訳と値域

| CLI | 渡し方 | 値域 |
| --- | --- | --- |
| codex | `-c model_reasoning_effort="<値>"` | none / minimal / low / medium / high / xhigh / max / ultra |
| claude | `--effort <値>` | low / medium / high / xhigh / max |

codexの値域は `codex-rs/protocol/src/openai_models.rs` の `ReasoningEffort` から採る。同リポジトリの `core/config.schema.json` はこのキーを「モデルが提示する非空の文字列」として自由文字列で定義しているため、実際に通る値はモデル依存になる。KIKIGAKIは列挙で先に弾き、CLIが拒否した場合は起動失敗として表示する。claudeの値域は `claude --help` の実測。

codexの `-c` の値はTOMLとして解釈されるので、文字列はクォートを付けて渡す。既存の `notify` と `sandbox_workspace_write.writable_roots` と同じ引数配列の作り方を使い、シェルを経由しない。

`extraArgs` の許可表から `--effort` を外す。`extraArgs = ["--effort", "high"]` と書くと設定エラーにし、`effort` へ移すよう促す。黙って受理すると、翻訳した引数との順序依存で実際の効き方が読めなくなる。

### アバターの指定

`[[ai]].avatar` には話者台帳と同じローカルパス、HTTPまたはHTTPSの画像URLを指定できる。ローカルの `~` は利用者のホームへ展開する。AIの行は送信元プロファイルの画像を使い、省略・取得失敗時は紫のイニシャルへ戻す。取得とURLキャッシュは話者と共通の `AvatarStore` を使い、キャッシュ先は `~/Library/Caches/kikigaki/avatars/`。設定は会議開始時に固定してmanifestにも保存し、古いmanifestにキーが無ければ画像なしとして読む。

## 送信ごとの宛先選択

手動シートと自動送信シートの先頭にポップアップを置く。既定は配列の1つ目、同じ会議内では前回選んだプロファイルを覚える。手動と自動は別々に覚える。

ポップアップに並ぶのは設定のプロファイルだけである。

シートの表題は選択に追随して「議事録へ 自動送信」のように変わる。接続状態・警告・「ペインを開く」も選択中のプロファイルのものを出す。手動シートを開いている間の自動tickスキップは、**同じプロファイルのときだけ**にする。別プロファイルなら手動と自動が同時に走ってよい(確定した仕様)。

印は既存どおり `#3 迅雷へ · 自動` の形で、`participant_name` から宛名を出す。番号は会議内の通し番号のままで、プロファイルごとには振り直さない。会議Markdownの `- 宛先:` も既存の生成をそのまま使う。

**確認質問への返答は、元の質問と同じ宛先へ返す。** 返答シートでは宛先を選ばせず、`prepare` と会話の整合検証でも親子の枠の一致を要求する。別のAIへ返すと、確認した本人ではない相手が答え、しかも元の質問が「返答済み」になってしまう。

各印に出す接続状態と「旧接続からの返事」の判定は、**その質問を送った枠のもの**を見る。選択中の宛先で全行を塗ると、Aを作り直しただけでBの正常な返事まで旧接続扱いになる。

## 取り下げた案(経緯)

<details>
<summary>利用者が手で起こした既存herdrペインへ接続する案</summary>

段1から段4まではこの案で実装し、実herdrで動くところまで確認した。取り下げたのは、KIKIGAKIが起動しない以上、起動時にしか渡せないものを渡せないため。

- Claudeの `--settings` によるStopフックとCodexの `notify` 差し替えを仕込めず、返し忘れ検知が使えない
- `-c sandbox_workspace_write.writable_roots` を渡せず、Codexの `workspace-write` では返送が `unsafe_file` で落ちる
- `permissions.allow` に同梱CLIを足せず、返送のBash実行が利用者への確認になり得る

`attach` / `displayAgent` / `AIAgentResolver` / `AIHerdr.list` の宛先候補 / 稼働中ペインのその場限りの宛先は実装ごと除く。Codex接続型の `writable_roots` 事前警告は不要になった。

</details>

<details>
<summary>会議に紐づかない準備済みAIセッション(段6〜8で実装し、後に撤去)</summary>

会議の初回送信でセッションを起こすと下ごしらえが会議中に走るため、KIKIGAKIが従来どおり起こしつつ会議には紐づけないセッションを台帳 `ai-prepared.json` で持ち、録音開始時のシートで枠ごとに選んで紐づける形を実装した。これも取り下げ、実装ごと撤去した。理由は3つ。

- 下ごしらえの目的は、先に議事録を作ってURLで渡す運用で代替できる
- 台帳が実運用で使われなくなった
- 起動引数に焼き付く許可のせいで、設定・保存先・`launch_revision` の不一致検査と紐づけ取消の巻き戻しを保ち続ける必要があり、維持コストが大きい

撤去したのは準備・紐づけの経路だけで、複数プロファイル・宛先の選択・`autoStart`・herdrでの起動・Codexの `outputDir` への書き込み許可は残す。利用者の台帳ファイルと準備用の置き場は読まず、消さない。envelopeの `participant.prepared_session_name` は送らなくなり、残っている旧requestでは未知の任意キーとして無視される。

</details>

## 録音開始時の自動送信

録音開始シートでの宛先の選び方、開始直後の判定、ロボットの見た目と操作は [ai-scheduled.md](ai-scheduled.md) を正本とする。

## データ構造と保存

### 会議に1つの会話、プロファイルごとのチャネル

`AIConversationController` は会議に1つのまま残し、内部に**チャネル**をプロファイル分持つ。チャネルが持つのは `AIStreamHistory`、世代、`AISessionRecord`、`AIHerdrConnection`、接続状態、固定した設定、警告である。

controllerをプロファイルごとに複数へ分ける案は採らない。`AIConversation` が `request.number == index + 1` を復号時に検証しており、`archive.original.ai` も1つの会話を前提にしている。分けると通し番号・Markdown生成・保存・登録簿の再設計が連鎖する。受信箱はrequest ID単位なので、そもそも分ける必要がない。

チャネル化で変える判定は次の5つ。

- `canSend`: 現在は現世代の返事待ちを会話全体から探している。**そのチャネルの世代に属するrequestだけ**で判定する。これが手動と自動を別プロファイルで同時に走らせる根拠になる。
- `prepare` の設定等価性検証: チャネルが固定した設定とだけ比較する。
- `scanHooks` の休止判定: 受信箱は会議で1つなので、**どのチャネルの観測かを先に決めてから検証する**。チャネルごとに自分のproviderで検証すると、相手側CLIの正常なフックが不正イベントに化ける(世代番号が並ぶと必ず起きる)。
- 送信の進行(Task・実行ID・進捗・取消)もチャネルごとに持つ。会議に1つだと、Aの確定待ちや起動待ちの間Bへ送れない。会話への保存はMainActor上の直列処理のままにする。
- 警告の解消: 結果が届いた枠と世代を照合し、**その結果で解消できる警告だけ**を消す。Bの回答でAの送達不明を消さない。

`AIRecordStore.Record` は会議に1つのまま。`saveResult` `savedConversation` `needsRecovery` と登録簿の扱いは変えない。

警告は会議に1つの文字列として出す。プロファイルが2つ以上ある会議だけ「議事録: 送達を確認できません」のように名前を添える。表示の系統を増やさずに、どの宛先の話かを示せる。

### パスとenvelope

session recordの置き場を `ai/sessions/<slot>/<generation>.json` へ変える。`<slot>` は会議開始時にプロファイルへ割り当てた1始まりの整数で、設定の並び順から作る。`name` は日本語や記号を含むためパスへ持ち込まない。

ただし**プロファイルが1つだけの会議は従来の平置き** `ai/sessions/<generation>.json` のままにする。単一プロファイルの設定でファイル配置が動くと、旧会議と新会議で形が食い違う理由がないのに増える。Claudeの `--settings` もsession recordの隣へ置き、同じ規則で枝に入る。

**同梱CLIも両方の形を解釈する。** CLIは `--session` のパスから保存先の根を割り出しており、平置きを前提に決め打ちで5階層を遡っていた。枝を切った会議ではここが合わずに `unsafe_file` となり、段4の実herdrで返送が全滅した。アプリのテストはCLIを実行しないので落ちず、CLIのテストは平置きしか作っていなかった。枝の有無を見て遡る階層を変え、両方の形をCLIのテストで固定した。

`AIParticipantContext` に任意キー `profile`(表示名)と `profile_slot`(整数)を足す。`trigger` と同じ扱いで、`schema_version` は1のまま、欠損は既定プロファイル・slot 1として読む。単一プロファイルの会議ではこの2つも付けない。片方だけの指定は拒否する。`AIEnvelope.validate` の `sessionPath` 検証は、slotがあれば `ai/sessions/<slot>/<generation>.json`、無ければ従来の `ai/sessions/<generation>.json` を要求する。

manifestは `schemaVersion` を2へ上げ、`config` を `profiles: [ResolvedAIProfile]` の配列にする。schemaVersion 1のmanifestは、slot 1・`name` を参加者名としたプロファイル1つとして読む。

`.kikigaki-context/<meeting>/ai/` の `state.json` `archive.json` `requests/` `inbox/` は形も置き場も変えない。`generation.json` だけはチャネル別になるので `ai/sessions/<slot>/generation.json` へ移す。

## 互換

- 単数 `[ai]` の設定はそのまま動く。slot 1、`name` は参加者名。
- 旧manifest(schemaVersion 1)を持つ会議は回収できる。旧requestは `profile` を持たないので slot 1 として表示し、旧 `sessionPath` 形式で検証する。
- 旧 `state.json` と `archive.json` はそのまま読める。`AIConversation` の形を変えない。
- 旧 `ai/sessions/<generation>.json` は残したまま読む。新規も、プロファイルが1つだけの会議は同じ平置きへ書き、2つ以上のときだけ枝を切る。同じ会議を新旧アプリで交互に開く運用は想定しない。
- 配布用Skillの契約は変えない。envelopeの追加キーは既知の任意キーとして無視されてよい。
- 利用者の台帳 `ai-prepared.json` と準備用の置き場には触れない。撤去後のKIKIGAKIは読まず、消しもしない。
- `attach` と `displayAgent` を書いた設定は**設定エラーにする**。黙って無視すると、接続するつもりの設定で新規起動が始まる。取り下げた旨と移行先をメッセージに書く。

## 保証しないこと

- 複数プロファイルへ同時に送っても、AI同士は互いの回答を見ない。同じ会議の同じ範囲を別々に読むだけである。
- KIKIGAKIが起こしたペインを利用者が別の用途に使っても検知しない。既存の同一性判定(pane・workspace・session・terminal)で置き換えだけを見つける。

## 対象外

- 複数のプロファイルを自動送信で同時に回すこと。`autoStart` は配列全体で1つまでで、自動送信の状態機械は会議に1つのままにする。
- 利用者が手で起こした既存herdrペインへ接続すること。取り下げた。
- 会議に紐づかないAIセッションを先に起こしておくこと。実装したうえで撤去した。
- CLIの設定・サンドボックス・信頼設定をKIKIGAKIが書き換えること。
- プロファイルごとのホットキー。グローバルショートカット自体を廃止した。
- 音声からの宛先自動判別。宛名で呼ばれたAIへ自動で振り分けることはしない。

## 採用した判断

- **`autoStart` は配列全体で1つまで。** 自動送信の状態機械 `AIScheduleState` は会議に1つで、複数同時は期限・失敗回数・最後の1回の権利をすべて多重化する。必要なら段を分ける。
- **プロファイルの定義は固定値としてmanifestへ残す。** requestのenvelopeがプロファイルを参照するので、記録の側に定義が無いと過去会議を復元できない。
- **切断したチャネルは「作り直す」で新しい世代を起こせる。** KIKIGAKIが起動する形なので、この操作は既存の契約のまま使える。
- **`extraArgs` での effort 指定は設定エラーにする。** 受理すると翻訳した引数との順序依存になり、どちらが効くか読めない。移行は1行の書き換えで済む。
- **`name` の既定は参加者名。** 重複したときだけ明示を必須にする。画面のポップアップは宛名で識別するのが自然で、設定の記述量も増えない。
