# 会議中のAI参加者との往復連携

設計段階の契約。コードと現行Skillへの反映は後続の段で行う。手動コピーの契約は [AIへの受け渡し](ai-handoff.md)、Skillへの変更案は [会議参加モードのSkill改訂案](ai-participant-skill.md) を参照する。

## 採用する操作と範囲

設定に `[ai]` があるときだけ有効。ホットキーで書き起こしウィンドウの送信シートを開き、Enterで送る。問い欄に文字があれば利用者の明示依頼として優先し、空なら会話末尾のAIへの問いを使う。初回の質問でherdrの対話セッションを起こし、同じ録音では使い回す。CodexとClaude Codeの両方に対応する。

会議参加モードでは声の依頼でも作業に入ってよい。操作の承認はCLIの設定とペインで行う。回答はモデルが同梱CLIを呼んで返し、フックは返し忘れの検知に使う。録音停止でAIセッションを閉じず、停止後の回答も元の会議へ保存する。

回答は同じ会議Markdownの `## AIとのやりとり` に残す。書き起こしには参照の印だけを置き、AIを音声のUtteranceや話者枡へ追加しない。通知音は既定無効。読み上げ、音声呼びかけ語による自動送信、複数AI、アプリ再起動後のAIセッション復元は対象外。

## 用語と状態

- 会議: 一回の録音。開始時に作る `meeting_id` を手動コピー・AI連携・保存で共用する。
- AIセッション: 会議に一つの論理的な接続先。再作成ごとに `session_generation` を増やし、CLIが付けるsession IDとは分ける。
- 質問: 一回の送信操作。`request_id` と固定した問い・文脈を持つ。確認質問への返答も新しいrequest IDを発行し、元質問を参照する。
- 受領: AIが指定範囲を読んだ報告。作業の承認や正しさの保証ではない。
- 回答: 同梱CLIから保存されたモデルの返答。利用者の合意や採用を意味しない。

質問の状態は録音の準備中・録音中・一時停止・最終保存中・停止後と独立に持つ。録音の状態変更は質問を完了にしない。

| 状態 | 根拠と次の操作 |
| --- | --- |
| draft | 問い欄の編集中。閉じても同じ会議の下書きを保持する。 |
| preparing | Enter後の確定待ち・snapshot保存・起動準備。未送信なら取消できる。 |
| prepared | 問いとsnapshot、返送契約を保存済み。まだ端末へ送っていない。 |
| submitted | herdrのpromptが成功。AIの受領は未確認。 |
| accepted | 同梱CLIのacceptを保存済み。回答待ち。 |
| needs_input | 同梱CLIで確認質問を保存済み。当該カードから返答できる。 |
| answered | 同梱CLIで回答を保存済み。読む操作を待つ。 |
| failed | 入力前の拒否、起動失敗、モデルが返した失敗など、根拠のある失敗。原因と再開操作を表示する。 |
| delivery_unknown | 送信を試みたが応答喪失などで成否不明。自動再送しない。 |
| cancelled | 利用者が未送信を取り消した、または回答待ちの追跡を終了した。後者はAIの処理停止を保証しない。 |

preparedからsubmitted、acceptedへ進み、回答・確認質問・失敗のいずれかに至るのが通常の流れ。送信要求前に「送信を試行する」を永続化し、その後のクラッシュはdelivery_unknownとして扱う。acceptより先のreplyも保存してansweredにできる。後着acceptやherdrの休止で状態を巻き戻さない。

needs_inputへの返答は新しいrequestに `in_reply_to_request_id` と `in_reply_to_event_id` を付ける。確認待ちの元質問は「返答済み」と補足し、新request側で回答を待つ。確認を続けず別の問いを送る場合も明示操作にし、元質問をansweredへ変えない。同じrequestへの回答訂正はMVPでは上書きせず、新質問として依頼する。

herdrのworking、blocked、接続不能は接続状態の補助情報。workingをaccepted、doneをansweredと解釈しない。返送漏れも独立した警告であり、確定回答が届けば解消する。取消後や旧世代の回答は元質問に「取消後の回答」「旧接続からの回答」と残し、新しい質問を完了にしない。

## 送信シートと暫定末尾

ホットキーと「AIに聞く」操作は同じシートを開く。録音中・一時停止・停止後に使え、準備中・最終保存中は送信を無効にする。利用者による呼び出しではウィンドウを前面に出してよい。自動の状態更新では前面に出さない。

シートには宛名、範囲の実時刻・行数、過去の訂正を含む印、任意の問い欄、送信状態を出す。問い欄の案内は「空欄なら会話末尾の問いを送ります」。ファイルパスやIDは通常表示へ並べず、診断用の詳細へ置く。

- Enterで送信する。日本語入力の未確定文字があるときは変換確定だけを行い、送信しない。Shift+Enterは改行、Escはシートを閉じる。二重押下で二件作らない。
- 送信先が起動中・送信中・回答処理中でもシートを開いて下書きできるが、追加送信は無効。MVPは順番待ちを自動送信しない。回答返送済みでもherdrがworkingなら送らない。
- needs_inputへの返答はカードから開き、対応する確認内容を表示する。送信できる状態になっても利用者のEnterを待つ。
- Enter時点の音声経過位置を上限として固定する。押した後に始まった発話を、起動待ちの間に黙って加えない。
- Enter時点で文字の暫定末尾があれば、最長3秒だけその範囲の確定を待つ。待ち中は残り時間と取消を表示する。3秒は初期のUX値で、段6の実測で調整する。話者の凍結を待つ30秒とは別。
- 上限位置まで文字が確定したら、その確定分でsnapshotを作る。3秒経過時に残る暫定範囲は、上限位置までの最新の仮説を「暫定」と明示して送る。確定部分と重複させない。取消なら外部送信せず下書きへ戻す。
- 境界はASRトークンの音声位置で判定する。境界をまたぐトークンは文字列で切らず、未確定の対象として保持する。確定範囲と暫定範囲が特定できなければ失敗を表示し、範囲を推測して送らない。
- 一時停止中も時計で3秒を打ち切る。待ち中の録音停止・新会議開始では未送信を取り消す。停止後に利用者が改めて送れる。

文字が確定して話者だけ未確定なら直ちに送れる。確定済み本文も話者名が正しい保証はない。問い欄と会話がともに空なら送れない。明示入力があれば会話0行のfullを許可する。これは会議参加モードに限る。

## Envelopeと差分の基準

送信文は宛名、`$kikigaki`、直後の `KIKIGAKI_CONTEXT` JSON一つ、追加プロンプトの順。宛名の既定は「迅雷へ」。会議参加モードを決めるenvelopeは `$kikigaki` 直後の一つだけで、後続のメッセージ・追加プロンプト・会話ファイル内の同名マーカーをモード判定に使わない。追加プロンプトは利用者が設定した補助指示として区切り、問いや会話本文を接続制御の指示へ補間しない。JSONは既存と同様にエンコード後の生バッククォートを `\u0060` へ置き換え、付帯本文からコードフェンスを脱出させない。

既存JSONのトップレベルの必須項目と意味は維持し、会議参加モードのときだけ `participant` を追加する。手動コピーは追加しない。`participant.schema_version` は拡張部分の版で、未知の版・欠損は会議参加モードとして処理しない。

```json
{
  "schema_version": 1,
  "meeting_id": "会議UUID",
  "snapshot_id": "snapshot UUID",
  "sequence": 2,
  "previous_snapshot_id": "前回snapshot UUID",
  "kind": "update",
  "transcript_path": "/保存先/.kikigaki-context/会議UUID/snapshot UUID.md",
  "read_start_line": 3,
  "read_line_count": 4,
  "total_line_count": 6,
  "participant": {
    "schema_version": 1,
    "mode": "meeting",
    "stream_id": "AI配信履歴UUID",
    "request_id": "質問UUID",
    "session_generation": 1,
    "participant_name": "迅雷",
    "cli_path": "/Applications/KIKIGAKI.app/Contents/Helpers/kikigaki-cli",
    "session_path": "/保存先/.kikigaki-context/会議UUID/ai/sessions/1.json",
    "request_token": "質問単位のランダムな返送トークン",
    "question": "",
    "question_source": "voice",
    "captured_at": "2026-09-06T14:05:00+09:00",
    "audio_cutoff_seconds": 300,
    "tentative_tail": {
      "text": "迅雷、さっきの案を直して",
      "start_seconds": 296,
      "end_seconds": 300,
      "status": "tentative"
    }
  }
}
```

UUIDとパス・時刻は書式の説明用。実データでは生成した値を使う。`question_source` は問い欄が空ならvoice、それ以外はtyped。`tentative_tail` と確認質問への二つの参照IDは必要な場合だけ付ける。`participant_name` は `address` 末尾の「へ」を除いた表示名とし、明示指定された一宛先を扱う。複数宛名への展開はしない。

snapshotは従来どおり確定済みの会話全文だけを固定保存する。暫定末尾はparticipantの付帯データであり、行数・差分・次回の基準へ含めない。次回に文字が確定したら、通常の文脈差分として訂正する。回答の根拠に暫定を含んだ事実は質問記録へ残す。AI回答や参照印もsnapshotへ混ぜない。

手動コピーとAI送信の履歴は分離する。手動の成功コピーがAIの受領を保証せず、共用すると未受領範囲を飛ばすため。AI側の履歴キーは `meeting_id + stream_id`、手動は従来のmeeting ID。sequenceは各履歴内の順序で、AIの新世代は新streamのfullから始める。別streamの差分を混ぜない。

自動側はsnapshot作成と配信を分離し、acceptまたは文脈受領済みのreplyで受領基準を進める。保存だけ、submittedだけ、フックだけでは進めない。未受領で失敗したsnapshotのsequenceは再利用せず、次の送信ではより大きい番号のfullを作る。手動コピーの成功時更新・再コピーの動作は変えない。

会話に変更がなくても新しい問いは送れる。同一streamの直前snapshotをそのまま再利用し、新request IDだけを発行する。前回が未受領ならfullで回復する。AIが前回snapshotを失った場合は `needs_input` の `context_missing` 理由で返し、シートの「全文で送り直す」から新requestとして送る。モデルによる範囲外の自動読み込みやアプリの自動再送はしない。

## 受信箱と永続化

会議の `.kikigaki-context/<meeting_id>/ai/` に置く。AIが会議Markdownへ追記する口は作らない。書き手は、モデル返送イベントを発行する同梱CLIと、会議データ・取り込み結果・Markdownを管理するアプリに分ける。

```text
ai/
  manifest.json                 会議ID、予約済みMarkdownパス、設定の固定値
  sessions/<generation>.json    CLI種別、接続先、フック用トークン、版
  requests/<request_id>.json    固定したenvelope、送信時点の問い、返送トークン
  inbox/<request_id>.accept.json
  inbox/<request_id>.result.json
  inbox/notify-<event_id>.json
  state.json                    送信試行、取り込み順、未読、表示状態
  archive.json                  最後に永続化した人間の保存用データ
```

manifestとrequestはアプリが送信前に保存する。sessionの接続情報更新、state、archiveはアプリの会議単位の直列処理で原子的に更新する。requestは作成後に変更しない。返送側は既知sessionからrequestを引き、自由な出力先指定を受け付けない。

acceptとresultはrequest内で各一つ。resultのkindはanswered、needs_input、failedのいずれか。ファイル名を固定することでCLI再実行も同じ論理イベントとして扱う。notifyはプロバイダのイベント識別子を使い、なければ正規化したペイロードのdigestでIDを作る。モデルにevent ID・会議ID・保存時刻を捏造させず、同梱CLIがrequestの固定情報から生成する。

```json
{
  "schema_version": 1,
  "event_id": "質問UUID/result",
  "meeting_id": "会議UUID",
  "request_id": "質問UUID",
  "session_generation": 1,
  "snapshot_id": "snapshot UUID",
  "kind": "answered",
  "recorded_at": "2026-09-06T14:06:02+09:00",
  "context_received": true,
  "body": "結論です。\n\n- 理由を示します。"
}
```

`recorded_at` は同梱CLIが保存する実時刻。アプリは取り込み時刻と単調な取り込み番号を別に保存する。ファイル名やUUIDの辞書順を到着順としない。再走査時は保存時刻とevent IDで決定的に並べ、同時刻の厳密な実行順までは保証しない。本文は複数行のUTF-8 Markdown。質問用返送トークンはenvelopeとrequest、フック用トークンはsessionと生成したフック設定にだけ保存し、イベントや会議Markdownへ出さない。

- 専用ディレクトリは既存でも0700、ファイルは0600。設定できなければ失敗。親のoutputDirの権限は変更しない。
- directory fdを基点に `O_NOFOLLOW` で辿り、通常ファイル・所有者・権限を確認する。UUIDや世代番号を検証し、パス区切り・相対パスをIDとして使わせない。
- 一意な一時ファイルへ新規排他的に書き、flush・close後、既存の完成ファイルを置換しない方法で公開する。例えば同一ディレクトリのlinkによる新規公開を使う。既存先を置換するrenameは使わない。監視対象は完成名だけ。
- 初期上限はイベント全体1 MiB、本文256 KiB、問い・追加プロンプトはそれぞれ32 KiB。文字数ではなくUTF-8バイト数で判定する。これは保護上限で、段6で実例を測って見直す。超過時は切り詰めて成功にせず、明示エラーを返す。
- JSONの版、型、必要キー、ID対応、kind、本文の有無、サイズを取り込み入口で検証する。未知版・壊れたJSON・session不一致は通常イベントへ混ぜず診断へ出す。任意のファイルやURLを解決しない。
- 同じ論理イベントの再実行は固定情報・kind・本文・context_receivedが同じなら以前の成功を返す。CLIが付けた時刻の差は同一性判定から除く。内容が違えば競合で拒否し、先の回答を保持する。
- CLIは完成ファイルの永続化成功後にだけ成功を返す。アプリの取り込みやMarkdown再保存まで成功した意味ではない。取り込み済み状態の保存前に落ちても、再走査で同じイベントを二重追加しない。

アプリ起動中は監視に加えて定期再走査し、監視通知の欠落を補う。起動時の再走査は登録済みで未完了の質問を持つ会議だけに限る。保存先と未完了会議の登録簿は `~/Library/Application Support/KIKIGAKI/ai-roots.json` とし、ユーザーの全ディスクや全過去会議を探索しない。未取り込みのresultも未完了に含め、受信箱の回収とMarkdown保存が終わるまで登録を残す。設定でoutputDirを変えても既に送った会議の受信箱を見失わない。アクセスできない保存先は警告に残す。

アプリ終了中も同梱CLIは受信箱へ保存できる。次回起動では記録の取り込みと会議Markdownの更新だけ行い、CLIの起動・再接続・質問再送は行わない。既存AIの以後の返送も、登録済みの会議記録として回収する。これをセッション復元とは呼ばない。

archiveは録音停止時と停止後の改名・統合時だけに更新し、同じ会議の遅延回答を描く元データにする。録音中には書かない。archiveが欠落・不正なら既存Markdownを推測で組み直さず、回答を受信箱に保ったまま保存失敗を表示する。録音中の異常終了から音声本文を回復する機能は追加しない。

## 同梱CLI

実行ファイル名は `kikigaki-cli`、配置は `.app/Contents/Helpers/kikigaki-cli`。アプリが実際のbundleパスから絶対パスを作り、envelopeとフックへ渡す。PATHへのインストールは不要。アプリ更新時もプロトコル版1を読めることを後続の互換条件にする。

| コマンド | 入力と効果 |
| --- | --- |
| `accept --session <path> --request <UUID> --token <token>` | 指定文脈を読み終えた受領を保存する。本文なし。 |
| `reply --session <path> --request <UUID> --token <token> --kind answered` | stdinのMarkdownを最終回答として保存する。 |
| `reply ... --kind needs_input --reason clarification` | stdinを確認質問として保存する。全文要求はreasonをcontext_missingとする。 |
| `reply ... --kind failed --reason <code>` | stdinの失敗理由を保存する。本文への機密のエラーダンプ混入を避ける。 |
| `notify --provider codex --session <path> --token <session-token> <payload-json>` | Codexの最後のJSON引数を解釈し、フック観測を保存する。 |
| `notify --provider claude --session <path> --token <session-token>` | Claudeのstdin JSONからフック観測を保存する。 |

replyは通常 `context_received: true`。文脈を読めなかったcontext_missingやread_failedではfalseとし、CLIがreasonから値を決める。質問対象が不明でも文脈を読めたならaccept後にclarificationを返す。成功時stdoutはevent IDを含む短いJSON、失敗時は非0と短い理由。本文をstdoutへ再表示しない。

セッショントークンはnotify専用で、質問へのreplyを許可しない。質問のtokenは当該requestへのacceptとresultだけを許可する。同一ユーザー権限の他プロセスからの完全な隔離は保証しない。トークンは誤接続対策であり、OSの書き込み制限の代わりにはならない。

モデルは返送に失敗したら未返送であることと原因をペインに表示する。同じ内容の保存再試行は一回までにし、それでも失敗したら停止する。元の作業自体は再実行しない。会議Markdownの直接編集や別経路への送信で補わない。

## フックと返し忘れ

Codexには引数配列で `-c` と、TOMLとして正しくエンコードした `notify=["<同梱CLI>","notify","--provider","codex","--session","<path>","--token","<token>"]` を渡す。引用符やバッククォートをシェルへ解釈させない。当該会議セッションの既存notifyを差し替え、元の通知スクリプトは連鎖して呼ばない。既存の通知音・本文通知が会議用途の既定無効を破るため。グローバル設定ファイルは変更せず、通常のCodexセッションには影響させない。

Claudeには専用の0600のJSON設定ファイルを作り、`--settings <絶対パス>` を渡す。Stopのcommandフックが同梱CLIのnotifyを呼ぶ。commandフックは、固定コマンドと引用済みのパス・トークンだけで組み立てる。会話・回答本文はコマンド文字列へ埋めず、stdinで受け取る。Claude Code 2.1.263では生成JSONのSessionStartと既存のherdr SessionStartが両方動き、同じイベントのhooksが併合された。既存フックをコピーしたり置換したりしない。詳細は [段2の実測](ai-participant-spike.md)。

同じ生成JSONの `permissions.allow` に `Bash(<同梱CLIの絶対パス> *)` だけを追加する。既定autoでは未知のMach-Oとして拒否されたが、このルールを渡したセッションではautoのまま返送できた。`--permission-mode` は追加せず、利用者の設定を保つ。これは本番の返送経路にも必要な設定で、検証専用の緩和ではない。グローバルのsettingsは変更しない。ask・denyや組織ポリシーが優先して返送できない場合はペインで確認してもらい、自動で権限を拡大しない。[^permissions]

| Provider | 使う項目 |
| --- | --- |
| Codex | typeがagent-turn-completeか確認し、thread-id・turn-id・input-messages・last-assistant-messageを取得できる範囲で保存する。 |
| Claude | hook_event_name、session_id、prompt_id、last_assistant_message、stop_hook_active、background_tasksを取得する。 |

フックは応答の区切りの観測であり、質問への回答や作業完了の正本ではない。Codex 0.153.4では本回答に加えてタイトル生成の別thread・別turnからもnotifyが届いた。タイトル側のinput-messagesにも元入力の一部が入り、通常の後続turnでは過去入力が累積した。envelopeやrequest IDの存在だけで当該質問の完了へ結び付けない。

Codexの本threadはherdrのagent_session、またはaccept/reply実行環境の `CODEX_THREAD_ID` から取得し、notifyのthread-idと照合する。モデルにIDを記入させない。取得前のnotifyは相関不能として保持する。turn-idは重複排除には使えるが、herdr promptの応答には対応するturn-idがないため、MVPでは質問との厳密な相関に使わない。タイトル本文の形を推測して選別しない。Claudeもprompt_idとrequestの対応は未確定であり、Stopの本文を現在の質問へ自動転記しない。input-messagesの全文は照合後に捨て、必要な識別子だけを保存し、トークンをイベントへ複製しない。

返し忘れの検知はMVPでは「返送未確認」の補助表示に留める。対象世代に未完了質問があり、完成済みresultを再走査しても未着で、herdrのidle/doneが5秒続いた場合に表示する。blocked・unknown・切断は別表示とする。Claude Stopに実行中background_tasksがあれば休止とは扱わず、次の状態観測を待つ。背景処理を完全に検出できる保証はなく、5秒は初期値である。これをfailed・answeredへ変換せず、自動再プロンプトもしない。後着resultで警告を消す。未連携本文を診断表示で読める場合も、質問への確定回答とは表示しない。

Codexのnotifyの項目とClaudeのStop本文は公式資料に記載がある。Claudeの中断時はStopが発火せず、APIエラーには別イベントがある。実測でも背景sleepが継続中のStopが届いた。全payload項目と試験の限界は段2の記録へ残す。[^hooks]

## herdrセッションの管理

1. 設定と実行ファイルを解決し、会議・質問を永続化する。
2. `herdr workspace create --cwd <cwd> --no-focus --label "KIKIGAKI <participant_name> HH:MM"` で作成し、返ったworkspaceとroot paneを保存する。HH:MMは会議開始の実時刻。応答喪失なら作成成否不明として止め、自動で作り直さない。
3. 作成したpaneへ `report-metadata --source owlery --display-agent <participant_name>` を送る。失敗は名義表示の警告に留め、実行先のIDは変えない。
4. 下記のcommand経路で解決済みの絶対パスを起動し、pane IDを送信先として保持する。canonical executableを使える場合の `agent start <name> --kind codex|claude --pane <pane> -- <CLI引数>` も実測済みだが、指定commandを無視する代用には使わない。入力準備完了を確認し、固定秒数のsleepで代用しない。
5. `agent get` で期待する接続先・CLI種別と送信可能状態を確認し、`agent prompt <target> <envelopeを含む全文>` を一回実行する。`--wait` は通常付けず、Process側の期限と受領イベントで追跡する。`--timeout`だけを付けない。

KIKIGAKIのProcess起動は実行ファイルと引数の配列を使い、`sh -c` やログインシェルを経由しない。**KIKIGAKIが起動する外部プロセスへ渡す環境から、名前が `HERDR_` で始まる項目を全て除く。** workspaceに持ち込む環境も同じにする。herdrが作成先paneのために正しく付与する新しい環境まで除く意味ではない。親paneの名義やsessionを継がせない。

herdr 0.8.2でSwift ProcessからHERDR環境を除去し、信頼済みcwdのagent startはCodex 0.153.4で3.65秒、Claude Code 2.1.263で3.83秒でinteractive_ready trueを返した。promptも両方成功した。ただしworkingでもpromptは成功し、独立turnの待ち行列にはならなかったため、アプリは処理中の追加送信を禁止する。

設定commandの絶対パスを守る起動には `herdr pane run <pane> <厳密に引用した起動コマンド>` を使う。段2ではworkspace作成時のPATH差替がペイン内の解決先に反映されず、canonical executableによる起動では指定パスを保証できなかった。pane runで絶対パスを指定すると両CLIが起動した。Codexはagent getがunknownを抜けてidle/doneになるまで、Claudeは新しいagent_sessionが立ちidle/doneになるまで待つ。旧session値やblockedをreadyとしない。起動コマンドにはパスと引数だけを引用して置き、会話本文を含めない。KIKIGAKI自身はherdrを引数配列で起動するが、この起動コマンドは受信先シェルで解釈される。

既定cwdは固定の `~/Library/Application Support/KIKIGAKI/ai-work/`。会議ごとの新規ディレクトリで毎回信頼確認を発生させない。固定cwdでも選択したCLIの初回には利用者の信頼確認が必要である。最初の送信時に「初回設定をherdrで確認」とペインを開く操作を表示し、利用者が内容を見て一度承認する。入力準備完了を再確認してから送信し、ダイアログ中へenvelopeを入力しない。CLI切替・cwd変更時にも必要となり得る。自動承認や信頼設定の自動書き換えはしない。

段2では初回に両CLIがagent_not_readyとなり、信頼ダイアログを表示した。承認後、Codexはconfig.tomlのprojectsへtrust_level、Claudeは.claude.jsonのprojectsへhasTrustDialogAcceptedを保存した。これらはCLIが保存する利用者設定であり、KIKIGAKIは編集・削除しない。固定cwd外の本番outputDirへのアクセス許可は段6で確認する。段2の返送成功は試験cwd配下への保存であり、任意の保存先への権限を保証しない。

- 後続送信前もagent getで生存を確認する。blockedなら入力せず「herdrで確認」を表示する。権限ダイアログのEnterを代行しない。
- herdrへ接続できない場合は接続不能。正常な一覧・getから対象消失を確認できたときだけ切断とする。別CLIや別sessionへの置換が分かった場合も切断する。
- 消失後は「AIセッションを作り直す」を明示操作にする。新世代・新streamで全文を送り、旧質問を勝手に再実行しない。履歴を知らないAIへ過去回答を参照させたい場合は利用者が問い欄へ必要部分を添える。
- 録音停止後も同じ会議への新質問と回答受領を可能にする。次の録音開始時は別会議・未接続から始める。旧会議の受信管理はアプリ全体のstoreに残す。
- submitted後の取消は待ち表示の終了だけで、プロセス終了やCtrl+C送信をしない。回答が必要なくなっても外部作業の停止はCLI側で行う。

## 画面と記録

送信状態のチップを既存のコピー操作の近くへ置き、質問カードは折り畳めるAI領域にまとめる。カードには送信時刻、問い、受領状態、回答の冒頭、全文展開、herdrを開く操作を置く。送信がvoiceならacceptで報告された問いの解釈に頼らず、送信時点の末尾参照と暫定の有無を表示する。

到着時はウィンドウ内の未読の印だけを更新し、カードの自動展開、ウィンドウの前面化、スクロール移動をしない。全文を開いたときに既読にする。新会議中の旧会議への到着は「前の会議に回答あり」と示し、旧会議の回答一覧を開けるようにする。新会議の書き起こしへ挿入しない。

notifySoundがtrueのときだけ、新しいモデル回答・確認質問の取り込みで一回鳴らす。再走査、重複返送、起動時回収では鳴らさない。外部バナーはMVPでは作らない。既存Claude hooksは併合されるため、CLI自身や既存hooksによる通知まで無音にする保証はない。KIKIGAKIからの通知だけを制御する。

保存形式の例:

```markdown
## 書き起こし

- [14:05:00] 田中: 迅雷、さっきの案を直して。
- [14:05:03] AIへ質問 Q1 → AIとのやりとり
- [14:05:10] 松村: その間に次の件へ進みましょう。
- [14:06:02] AI回答 Q1 → AIとのやりとり

## AIとのやりとり

### AI Q1

- 送信: 2026-09-06 14:05:03 +09:00
- 宛先: 迅雷
- 問い: 「迅雷、さっきの案を直して。」
- 対象: snapshot UUIDの3〜6行。暫定末尾を含む
- 受領: 2026-09-06 14:05:08 +09:00
- 回答: 2026-09-06 14:06:02 +09:00

#### 回答

修正しました。

- 変更内容と確認結果です。
```

Q番号は会議内の送信順の表示番号で、対応付けにはrequest IDを使う。印は平文にし、読み手ごとに異なる見出しアンカーの生成規則へ依存しない。AI節の見出しは `### AI Q<番号>`。問いは `- 問い:` の一行だけに入力内容または末尾発話の引用を置き、複数行入力はこの表示に限って改行を空白へ変える。元の入力はrequestへ保持する。書き起こしの印は送信試行時とモデルresult受領時の各一行とし、送達不明や確認質問の場合はその状態を表す文言にする。acceptやフックごとの印は増やさない。

人間の発話と印は実時刻で合成する。同時刻は人間の発話、印の順、印同士は記録順で決定的に並べる。録音停止後の回答印は末尾へ置き、日をまたぐ場合は日付も付ける。話者統合・改名・相槌省略で人間の行が増減しても、印をその行番号へ固定しない。

AI節は送信時の問い・固定snapshot参照・暫定末尾・結果イベントから生成する。モデルの本文は改名や再判定で書き換えない。引用した過去の話者名も当時のまま残す。本文内のMarkdown見出しはAI本文の範囲として描画し、制御情報として再解釈しない。

通常Markdownと、相槌省略機能が作成した `.raw.md` に同じAI節と印を含める。AIのためだけにrawは作らない。raw保存失敗時に相槌を省略しない既存契約を保つ。生成の元データは人間のMeetingArchive相当、質問レコード、受領済みイベント集合で、完成Markdownのparseで状態を復元しない。

Markdownの書き手はKIKIGAKIだけ。録音中のAI受領では受信箱と画面を先に更新し、会議Markdownは従来どおり録音停止時に生成する。停止後の回答や改名では両出力を再生成する。保存用archiveを先に永続化し、Markdownは再生成できる状態を作ってから置き換える。両ファイルの更新途中に失敗してもAIイベントは失わず、保存状態をファイルごとに保持して再試行できるようにする。

MVPのMarkdownはアプリが管理する生成物として扱う。外部編集の自動検知は段3では実装しない。再起動後の過去会議の話者再編集UIも追加しない。

## 設定

`[ai]` がなければ新規送信の操作・ホットキー・外部起動を有効にしない。過去に送信済みの会議が登録されている場合は回答記録の回収だけ続ける。空の `[ai]` は既定値で有効。設定は録音開始時に固定し、途中の再読込では次の録音から適用する。保存先や参加者を進行中の質問で変更しない。

```toml
[ai]
cli = "codex"
# command = "/opt/homebrew/bin/codex"
# model = "gpt-6-astra"
address = "迅雷へ"
# cwd = "/Users/me/work/project"
extraArgs = []
prompt = "回答は会議で読める長さにし、必要な詳細を後ろへ置く"
notifySound = false

[ai.hotkey]
modifiers = ["ctrl", "alt", "cmd"]
key = "a"
```

| キー | 既定と検証 |
| --- | --- |
| cli | codex。codexまたはclaudeのみ。 |
| command | 省略時は選択CLIをPATHで解決し、絶対パスと実行可能性を検証する。指定時は空でない絶対パス。見つからなければ送信前に原因を示し、別CLIへ切り替えない。 |
| model | 省略時はCLIの既定。指定時は空でない文字列として該当CLIのモデル引数へ渡す。 |
| address | 迅雷へ。空・改行・制御文字を拒否。起動時の表示名にも使用する。 |
| cwd | 省略時は固定の `~/Library/Application Support/KIKIGAKI/ai-work/` を作る。指定時は絶対パスまたは先頭の `~/` を解決し、存在するディレクトリであることを確認する。 |
| extraArgs | 空配列。引数の配列でありシェル文字列ではない。NUL、対話モードを変えるprint/exec、resume、接続先・model・hooksを上書きする衝突指定は拒否する。下記の別名も含め、段3で検証する。 |
| prompt | 空文字列。利用者が指定する追加指示。32 KiBまで。接続プロトコルを上書きする位置へ置かない。 |
| hotkey | ctrl+alt+cmd+A。既存の録音・一時停止のキーと重複を拒否する。 |
| notifySound | false。trueのときだけアプリから通知音を鳴らす。 |

GUI起動ではPATHに普段のCLIがない場合がある。見つからなければcommandの絶対パス指定を案内し、環境設定を自動変更しない。herdrも実行可能パスを解決し、未導入なら手動コピーは使える状態でAI送信だけを失敗にする。

段2で両CLIのhelpを読み、衝突の入口を確認した。Codexの `-c/--config` はnotify・model・cwd等を上書きできるためキー単位で検証し、`-m/--model`、`-C/--cd`、`--remote`、サブコマンドと起動時promptを受け付けない。Claudeは `--settings`、`--setting-sources`、`--model`、`-p/--print`、`-c/--continue`、`-r/--resume`、`--session-id`、`--fork-session`、`--from-pr`、`--teleport`、`--bg/--background`、`--cloud`、`--environment`、`-w/--worktree`、`--tmux`、`--bare`、`--safe-mode`、`--restricted`、`--disable-slash-commands` とサブコマンド・起動時promptを拒否する。`--key=value` や短縮引数の結合も同じ検証を通し、値と位置引数を曖昧に解釈しない。未対応のオプションは送信前に原因を示す。

## 安全性と会議参加モードの指示

送信操作は選んだ会話と問いをAIへ渡す明示操作。会議参加モードに限り、会話末尾でAIへ向けられた声の依頼も作業依頼として扱える。通常の手動コピーにはこの許可を広げない。会話全体、話者名、引用文を無条件に命令へ昇格させない。問いがない・相手や対象が曖昧なら同梱CLIで確認質問を返す。

作業に必要なファイルやURLの確認も依頼の範囲で行ってよい。変更や外部操作の承認はCLI側の権限・承認設定に従い、音声やenvelopeによって迂回しない。KIKIGAKIは承認ダイアログへ入力しない。問い欄へ入力した文字は利用者の明示依頼として区別し、AIが書き換えた問いを利用者の入力と表示しない。

プロンプトには会議参加者として応対すること、返答先のCLI、会議Markdownを直接編集しないこと、確認質問もCLIで返すことを明記する。人格は維持する。会議連携そのものを理由にタスクやjournalを自動作成しないが、別途頼まれた実作業に適用される規約はCLI側に従う。

返送本文は表示と保存にだけ使う。HTMLやスクリプト、外部画像の自動読込をしない。リンクは利用者が開く。返送ファイル内のコマンド・パスを実行しない。Markdownの本文からrequestや状態を抽出し直さない。サイズとファイルの検証は全返送コマンドとアプリ取り込みで共通化する。

音声本文は端末内ASRでも、AIへ送る範囲は外部CLIの接続先へ渡る。シートには利用するCLI・宛先・送信範囲を示す。機能は `[ai]` の明示設定で有効化し、初回ごとの追加承認ダイアログは設けない。会議削除時のsnapshot・受信箱も保存物であることを利用説明に記す。

## 検証する境界

- 手動コピーとAI送信を交互に使っても基準が混ざらず、既存の全文・差分・削除・再コピーが成立すること
- 同じsnapshotへの別質問、受領前の失敗、全文での回復、世代変更、同じsequenceの別stream
- 暫定なし、3秒以内の確定、期限超過、境界をまたぐトークン、確定後の文字訂正、一時停止、待ち中の録音停止・取消
- 音声の問い、明示入力の優先、問いなし、曖昧な対象、確認質問への返答、文脈不足からの全文要求
- 日本語入力のEnter、Shift+Enter、Esc、連打、処理中の下書き、停止後の新質問
- CodexとClaudeの非フォーカス起動とラベル、ready確認、初回信頼ダイアログ、二回目送信、HERDR環境の非継承、command指定どおりの実行
- workspace作成応答喪失、prompt応答喪失、blocked、herdr停止、ペイン消失・置換、送信直前にCLIが終了する競合
- 受領前の回答、二重返送、同じIDの異なる本文、取消後・旧世代・旧会議の回答
- 欠損・不正JSON、未知版、サイズ上限前後、マルチバイト境界、symlink、通常ファイルでない入力、権限設定失敗
- inbox完成前の監視、書込み・公開・取り込みの各境界での失敗、アプリ終了中の返送、起動時再走査、outputDir変更
- フックの正本返送済み・未返送・後着・欠落・重複・相関不能、Claude既存hooksとの併合、Codex既存notifyの非連鎖
- CLIからの返送権限、承認待ちの可視化、返送失敗のペイン報告。Claudeは本番と同じ生成JSONの同梱CLI限定allowを使い、検証のために追加の権限を広げないこと
- 通常とrawの同一AI節、停止後の改名・統合・相槌省略、深夜の日付跨ぎ、到着後の保存失敗
- 未読・既読、音の既定無効と一回性、長文展開、リンク・コード・HTMLを含む回答、フォーカス・スクロール保持
- `[ai]`なし・空・不正、hotkey重複、command未発見、extraArgs衝突、設定再読込

## 実装順と完了条件

| 段 | 実施内容 | 完了条件 |
| --- | --- | --- |
| 1 | 本設計書とSkill改訂案。コード・現行Skillは変更しない。 | 本人が設計をレビューし、段2への進行を認める。 |
| 2 | Swift Processから実herdr、両CLI、フック、返送権限を検証するスパイク。使い捨ての入出力と専用workspaceを使う。 | 両CLIのready、command経路、payloadと相関の限界、Claude hooks併合、sandbox、処理中promptの挙動を実測記録。失敗は未解決として本人へ戻し、仕様を黙って緩めない。 |
| 3 | Coreの設定、会議IDと履歴、envelope、質問・イベント、重複排除、Markdown生成、永続化契約。 | 純粋な状態遷移と失敗系をテストし、既存手動コピー・通常/rawの保存契約を維持。 |
| 4 | アプリの接続管理、確定待ち、送信シート、チップ、カード、受信箱監視と旧会議回収。 | 実装前にモックを本人へ出し、本人経由でクロディーヌのレビューを受ける。模擬CLI・イベントで録音との直交とUIの全状態を確認する。 |
| 5 | 同梱CLI、フックadapter、Skill反映、make-app.sh・リリース同梱、CLAUDE.md・README・ai-handoff.md更新。 | Helpersの署名と同梱、両CLIで本物のaccept/reply、返送漏れ検知、通常Skillとの分岐を確認する。 |
| 6 | replayと実herdrで両CLIの往復と障害系を端から端で検証。 | 質問1を待つ間も会話が続き、回答1→質問2→回答2、停止後の改名でも両回答が同じMarkdownに残る。二重返送・終了中返送・返し忘れ・送達不明を確認し、本人が実機検分する。 |

段3〜5でコードを変更したら `swift build && swift test` を成功させてからその成果物で確認する。段4で本番CLIを先取りして作らず、同じ契約の模擬口で確認する。各段を本人へ報告し、レビュー後に次へ進む。

## 対象外と後続課題

- 録音中のarchiveチェックポイントと異常終了からの本文回復、「途中までの記録」の表示。段6以降の課題とし、今回のMVPには入れない。
- Markdownのdigest照合による外部編集の検知。段3では作らず、段6までに必要か本人が判断する。
- 完了済み会議の全件再走査。起動時は未完了の質問を持つ登録会議だけを回収する。

[^hooks]: [OpenAI公式のnotify仕様](https://learn.chatgpt.com/docs/config-file/config-advanced#notifications)、[Claude Code公式のStop仕様](https://code.claude.com/docs/en/hooks#stop)、[Claude Code公式のCLI設定](https://code.claude.com/docs/en/cli-reference)。実測は [段2の記録](ai-participant-spike.md)。
[^permissions]: [Claude Code公式の権限ルール](https://code.claude.com/docs/en/permissions)。allowは同梱CLIの起動に限定し、返送先・requestの制限は同梱CLIで検証する。
