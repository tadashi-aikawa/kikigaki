# AI参加者の通信境界: 段2の実測

2026-09-07に専用workspaceで検証した。設計への反映は [AI参加者の設計](ai-participant.md)。本番コードの実装や端から端の動作確認はまだ行っていない。

## 環境と再現手順

| 対象 | 実測版・場所 |
| --- | --- |
| herdr | 0.8.2 |
| Codex | 0.153.4、gpt-6-astra、workspace-write |
| Claude Code | 2.1.263、既定Fable 5.1、auto |
| スパイク | `/private/tmp/kikigaki-stage2.jjeobh/Probe.swift` |
| 同梱CLI相当 | `/private/tmp/kikigaki-stage2.jjeobh/Probe.app/Contents/Helpers/kikigaki-cli` |
| cwd | `/private/tmp/kikigaki-stage2.jjeobh/work` |
| 受信箱 | cwd内の `.kikigaki-context/probe/ai/inbox/` |

スパイクはFoundationのProcessへ実行ファイルURL・引数配列を設定し、環境から名前がHERDR_で始まるキーを全て除去する。stdoutとstderrを回収し、起動から終了までをDateで測った。実際に除去したキーは次の六つ。

- HERDR_BIN_PATH
- HERDR_ENV
- HERDR_PANE_ID
- HERDR_SOCKET_PATH
- HERDR_TAB_ID
- HERDR_WORKSPACE_ID

`swiftc Probe.swift -o Probe.app/Contents/Helpers/kikigaki-cli -module-cache-path module-cache` でビルド成功。`kikigaki-cli run <herdr絶対パス> <引数...>` が上記Processを実行する。外側のCodex sandbox内ではherdrソケット接続が拒否されたため、依頼元の承認範囲でスパイクの起動をsandbox外で行った。試験先Codexのworkspace-writeは維持した。この二つのsandboxを混同しない。

workspaceは `workspace create --cwd <cwd> --no-focus --label "KIKIGAKI <参加者名> HH:MM"` で作成した。試験先はw5F、w5G、w5Hだけで、親のw5Eは操作対象外。以後のstart・prompt・代替pane runも上記Process経由で成功した。表示と生存はagent getおよびpane readのvisibleで観測した。

## 起動とcommand指定

| ケース | 結果 |
| --- | --- |
| 初回Codex agent start | 約3.53秒でagent_not_ready。信頼ダイアログを確認 |
| 初回Claude agent start | 約3.42秒でagent_not_ready。trust dialogを確認 |
| 信頼済みCodex agent start | 3.645秒、interactive_ready true、idle |
| 信頼済みClaude agent start | 3.830秒、interactive_ready true、idle、新agent_sessionあり |
| 両CLIのagent prompt | 約0.07〜0.08秒で送信成功。受領・回答完了を表す応答ではない |
| PATH差替 | workspace作成で専用binをPATH先頭に渡しても、ペイン内のcommand -vは既定の実パスを返した |
| 絶対パスのpane run | 両CLIが起動。Codexはidle、Claudeは新agent_sessionとidleを確認 |

初回の信頼確認は依頼元が手動で通した。固定cwdでも最初の利用時にペインでの承認が必要であり、自動Enterしない。Codexは信頼前でもagent startの名前が登録されるため、失敗応答だけで別workspaceを作り直さない。

信頼済み起動の引数は次のとおり。パスは上表のscratchを指す。

```text
agent start <name> --kind codex --pane <pane> --timeout 15000 -- -m gpt-6-astra --sandbox workspace-write
agent start <name> --kind claude --pane <pane> --timeout 15000 -- --settings <scratch>/claude-settings.json
```

command経路の検証では専用binに実CLIへのsymlinkを置いた。PATH経路が失敗した正確なシェル初期化箇所までは特定していない。代替は `pane run <pane> "'<scratch>/bin/codex' '-m' 'gpt-6-astra' '--sandbox' 'workspace-write'"` とClaudeの同形式。Claudeはprocess-infoのargvにも指定したsymlinkパスが現れた。CodexはNodeランチャーと実バイナリへ解決されたプロセス引数を確認した。任意のラッパースクリプトすべてへの対応を実証したものではない。

## 返送とClaudeのセッション限定許可

Codexはworkspace-writeからHelpers内のSwiftバイナリを実行し、受信箱へ `CODEX_REPLY_OK` と改行の15バイトを保存した。出力ファイルは0600。Claudeの既定autoは同じバイナリを未知のMach-Oとして拒否し、ファイルは生成されなかった。

依頼元のB判断に従い、KIKIGAKIが本番でも生成するセッション専用JSONに次のallowを追加した。`~/.claude/settings.json` は編集していない。

```json
{
  "permissions": {
    "allow": ["Bash(/private/tmp/kikigaki-stage2.jjeobh/Probe.app/Contents/Helpers/kikigaki-cli *)"]
  },
  "hooks": {
    "SessionStart": [{"matcher":"*","hooks":[{"type":"command","command":"'/private/tmp/kikigaki-stage2.jjeobh/Probe.app/Contents/Helpers/kikigaki-cli' session","timeout":10}]}],
    "Stop": [{"hooks":[{"type":"command","command":"'/private/tmp/kikigaki-stage2.jjeobh/Probe.app/Contents/Helpers/kikigaki-cli' notify claude","timeout":10}]}]
  }
}
```

このJSONを `--settings` で渡して新しいClaudeを起動し、同梱CLIを直接呼んで引用したヒアドキュメントをstdinへ渡した。autoのまま `CLAUDE_ALLOW_OK` と改行の16バイトを返送できた。Stopのpermission_modeもautoだった。`--permission-mode` の追加指定は不要で、別モードは試していない。生成ファイルは検証時に秘密のtokenを含まない0644だったが、検証後0600へ変更した。本番では生成時から0600にする。

スパイクのreplyは診断用であり、渡されたパスに `.kikigaki-context/` があることと新規書込だけを確認する。本番のrequest照合、token、nofollow、サイズ制限、完成ファイルの原子的公開は未実装。診断用run・delayを製品の同梱CLIへ持ち込まない。

## フックの実物と対応付け

Codexへセッション限定の `-c 'notify=["<helper>","notify","codex"]'` を渡した。JSONは最後のargvとしてhelperへ届いた。全キーは次のとおり。

```text
client
cwd
input-messages
last-assistant-message
thread-id
turn-id
type
```

本回答ではtypeがagent-turn-complete、clientがcodex-tui、last-assistant-messageがCODEX_PROBE_DONEだった。input-messagesには送信したenvelope全文が入った。後続turnではそれ以前の入力も累積した。

同じ初回入力を使うタイトル生成からもnotifyが届いた。タイトル側のinput-messagesはタイトル生成指示と元入力の途中までを含み、KIKIGAKI_CONTEXTまで入っていた。元envelope全文が届いたわけではない。本回答との識別値は次のとおり。

| 発生元 | thread-id | turn-id |
| --- | --- | --- |
| 本回答 | `01a07744-7fda-7133-9ccc-3b8c11c479b1` | `01a07746-1161-7ea2-88be-db7c59a0eb03` |
| タイトル | `01a07746-132a-7d01-bf93-800bab0387a1` | `01a07746-134f-72e0-8569-bfeb35295ccf` |

本threadはherdr agent_sessionと、モデルが実行した `printenv CODEX_THREAD_ID` の値が一致した。異なるthreadの混入はこれで区別できる。一方、herdr prompt応答にはturn-idがなく、累積input-messagesも質問単位の対応を保証しない。turn-idは同一イベントの二重排除に使い、返し忘れの断定には使わない。初回ready時点ではCodexのagent_sessionがまだ無かった点にも注意する。

Claude Stopはstdin JSONで届き、全キーは次のとおり。

```text
background_tasks
cwd
effort
hook_event_name
last_assistant_message
permission_mode
prompt_id
scratchpad_dir
session_crons
session_id
stop_hook_active
transcript_path
```

拒否時も成功時もlast_assistant_messageが入った。背景sleep継続中にもStopが発生し、background_tasksにはtype shell・status runningが入った。Stopは作業終了を意味しない。prompt_idはあるがherdr promptから対応IDを取得できず、requestとの厳密な照合は未成立。

生成したSessionStartのhelperが出力した全キーは `cwd, hook_event_name, model, scratchpad_dir, session_id, source, transcript_path`。既存settingsのherdr SessionStartを生成JSONに複製していないのに、独自payloadと同sessionのherdr agent_sessionが両方生じたため、同イベントのhooksの併合を確認した。既存フック全種類の効果や通知音まで検証したわけではない。

返送漏れは設計で「result未着かつidle/doneが5秒続いた場合の返送未確認」へ弱める。フック本文からansweredを作らない。Claudeに既知の実行中background_tasksがあれば休止判定を保留する。

## 処理中のprompt

Codexでsleep 45の実行中をvisibleで確認し、第二の問いを送った。herdrはworkingのままagent_promptedを返した。第二の入力が同じ処理の途中へ現れ、第二の返答が先に表示された後、第一の返答が最終となった。notifyは一つのturnで全入力を含み、最後の本文は第一の返答だった。sleepのプロセスが入力で停止された様子はなく、処理中の指示として取り込まれた。

Claudeはallow済みhelperのdelay 25を前景実行し、5秒経過した表示を確認して第二の問いを送った。herdrはworkingのまま成功を返し、delay完了後の一つの最終応答で第一・第二の両方へ返答した。Stopも両方を含む本文だった。

どちらも「独立した質問を一件ずつ完了する待ち行列」の保証にはならない。MVPは処理中の追加送信を無効にし、下書きだけ保持する。単にinteractive_ready trueだから送信可能とは扱わない。

## 残った設定と検証範囲

初回信頼確認により残った次のエントリを読み取り確認した。設定自体は編集・削除していない。

- `~/.codex/config.toml`: `projects."/private/tmp/kikigaki-stage2.jjeobh/work".trust_level = "trusted"`
- `~/.claude.json`: 同cwdのprojectsエントリに `hasTrustDialogAccepted = true`

試験CLIが通常作成するセッション履歴も残る。scratchにはフックの生payloadと診断ログを保持する。これらは使い捨ての検証資料で、製品の永続化契約ではない。

2026-09-07T00:28の完了確認時点で、試験workspaceのw5F・w5G・w5Hは全てworkspace closeが成功した。親workspaceは閉じていない。

本番の固定cwdとDocumentsなど別のoutputDir、空白を含むbundleパス、配布署名済みhelper、CLI設定や組織ポリシーが異なる環境は段6で確認する。cwd内の/tmpへの返送成功から任意の保存先の権限を推測しない。既存Claude hooksの通知音は共存するため、KIKIGAKIのnotifySound falseが他の通知まで無音にする保証はない。

## 参照

- [Codexのnotify](https://learn.chatgpt.com/docs/config-file/config-advanced#notifications)
- [Claude CodeのStop](https://code.claude.com/docs/en/hooks#stop)
- [Claude CodeのCLI引数](https://code.claude.com/docs/en/cli-reference)
- [Claude Codeの権限ルール](https://code.claude.com/docs/en/permissions)

公式資料で引数と項目の意味を確認し、上の成否はインストール済み版で実測した。
