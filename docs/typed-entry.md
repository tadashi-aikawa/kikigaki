# 手入力で会話へ投稿する

会議中に共有されたURLなどを、音声の行と同じ会話へ投稿する。投稿者は4枡とは別の固定名「手入力」。受付は録音中・一時停止中のみとする。

## 操作と表示

本文とフッターの間に、placeholderが「会話に書き込む…」の1行入力欄を置く。送信先を選ぶ操作や設定は追加しない。投稿してもAIへの送信は始めず、会話への追加だけを行う。

地は常に紙色で、通常は区切り線色の1pt角丸5の枠、フォーカス時は墨、無効時は枠を40%に落として文字を薄墨にする。無効時のplaceholderは「録音中に書き込めます」。未投稿の下書きが残る場合は右端へ「未投稿」を出し、編集と選択を無効にする。

| 操作・状態 | 挙動 |
|---|---|
| 録音中・一時停止中 | 入力・投稿を有効にする |
| 待機中・準備中・保存中・保存済み | 入力・投稿を無効にする。セッション側でも拒否する |
| Enter | IMEの未確定文字がなければ投稿する。成功時だけ入力を空にしてフォーカスを保つ |
| IME変換中のEnter | 変換確定だけを行い、投稿しない |
| Shift+Enter | 改行せず、未確定文字がなければ投稿する |
| Esc | 未確定文字があれば通常の変換取消。なければフォーカスを外し、下書きを残す |
| 空白だけの入力 | 投稿しない |
| 複数行の貼り付け | 改行を空白に置換し、1行として扱う |
| 停止・ウィンドウを閉じる | 未投稿の下書きを保持する。停止後には投稿できない |
| 新しい会議を開始 | 前会議の未投稿下書きと投稿済み手入力をリセットする |

`AIQuestionEditor` と同じく、キー入力時に `hasMarkedText()` を確認する専用エディタを使う。入力欄は横方向にスクロールできる1行のプレーンテキストとし、長いURLでも高さを伸ばさない。貼り付け時と投稿受付時の両方で改行を正規化する。変換中の編集文字列は正規化で書き換えない。ウィンドウの `cancelOperation` へ先に流して検索を閉じるのではなく、入力欄がEscを処理する。

`TranscriptWindowController.onSubmitTyped: (String) -> Bool` を `AppDelegate` から `MeetingSession.submitTyped(_:)` へ接続する。成功した場合だけUIが下書きを消し、検索中や過去の行を読んでいる場合も末尾を見せる。一時停止中の投稿も録音中と同じ出現効果を使う。どちらもMainActor上で同期実行し、投稿受付の途中に `await` を置かない。停止操作が先なら拒否し、投稿受付が先ならその投稿を停止時の保存へ含める。

手入力の行は、墨の丸地に紙色の鉛筆 `pencil`、固定名「手入力」、時刻、本文で構成する。吹き出しの尾と話者未確定表示は付けず、名前・アバターからの改名操作を出さない。話者数にも加えない。

typed行だけ、`http` と `https` のURLをリンク属性にする。URL検出後にschemeを検査し、クリック時に既定ブラウザで開く。自動取得・プレビューは行わない。本文の選択・コピーとCmd+F検索を維持する。手入力の本文は `NSTextView` に載せ、`linkTextAttributes` で朱と下線を指定する。検索の背景色更新でリンク属性を落とさない。

## データの持ち方

### Utteranceの由来

`Utterance.Kind: String, Codable, Sendable` に `voice` と `typed` を定義し、`Utterance.kind` と `postedAt: Date?` を追加する。既存の音声イニシャライザ呼び出しは互換を保つ。typed専用の生成口は `speaker = nil`、`start = end` と投稿日時postedAtを保証する。voiceのpostedAtはnilとする。

| データ | 取り扱い |
|---|---|
| 旧JSONにkindがない | 独自の `init(from:)` で `.voice` として読む |
| 新JSON | voiceもtypedもkindを文字列で保存する |
| 未知のkind | デコードエラー。voiceへ黙って読み替えない |
| typedなのにspeakerが指定されている | 不正なデータとして拒否する |
| typedの時刻が非有限・負値・startとendが異なる | 不正なデータとして拒否する |
| typedにpostedAtがない・非有限の日時 | 不正なデータとして拒否する。旧形式のtypedは存在しない |
| voiceのpostedAt | nil。日時が指定されたJSONは拒否する |
| voiceでspeakerがnil | 従来どおり不明話者「?」 |
| 同じ本文・同じ音声位置のtypedが複数ある | 別々の投稿として保持し、重複排除しない |

archiveに含まれる `Utterance` 配列もこのデコード規則で読む。`SessionSnapshot` 自体はCodableではない。AIのsnapshotはレンダリング済みの行を保存するため、AI envelopeのschemaや履歴IDに変更は要らない。既存の保存済みMarkdownは変換しない。

共有の表示名取得口として `SpeakerNames.displayName(for: Utterance)` を用意する。typedは「手入力」、voiceは従来の `name(for: speaker)` を返す。`TranscriptRenderer`、`TranscriptRow`、`TranscriptWindowSearch` がこの口を使う。既存の `name(for: Int?)` は変えず、nilの意味を上書きしない。

由来の判定は名前ではなくkindで行う。音声の話者名に同じ「手入力」が設定されていても音声として扱い、既存の話者名設定へ新しい禁止条件は足さない。

### セッションでの保持

`MeetingSession` が `private var typedEntries: [Utterance]` を投稿順に保持する。`snapshot.utterances` は音声と手入力を併合した表示結果であり、投稿の正本にはしない。開始時に `liveSource`・`finalTokens` と一緒に空へ戻す。

`submitTyped(_:)` は受付状態を確認し、前後の空白を除き、改行を空白へ正規化して空なら拒否する。本文の内部スペースやURLの文字列は保つ。改行はCR・LFだけでなくUnicodeの改行も対象にし、AI文脈の検証で拒否されるNULは投稿時点で拒否する。`pause.audioTime` を1回読んで `start = end` に設定し、同じ受付で `Date()` をpostedAtとして固定する。受理後は `refreshLive()` と `emit()` を呼ぶため、ASRの次回更新を待たずに画面とコピー範囲へ反映される。

音声消費が遅れていると、手入力のstartは `snapshot.elapsed` より先になる。投稿自体を遅らせず、既存の音声消費位置は書き換えない。受け渡し範囲の終端表示だけは、最後の手入力位置も含む位置にする。`snapshot.elapsed` を収録位置へ変更するとAI確定待ちなど別の意味を壊すため、表示用の終端と処理済み位置を分ける。

## 併合の位置

Coreへ `TranscriptEntries.merge(voice:typed:timeline:pendingVoiceRows:)` を置き、併合済み発話と、併合後の話者未確定行の添字を返す。既定のpending集合は空とする。

入力列へ別のkindが混ざっても本番を停止させず、kindで声と手入力へ振り分け直す。voice列に混ざったtypedも投稿として保持し、未確定の印は元のvoice列にある声だけへ付ける。

順序はstart昇順。同じstartで声と手入力を比較するときだけ、typed.postedAtとvoiceの `timeline.date(at: start)` を比べ、早いほうを先にする。時計まで同値ならvoiceを先にする。voice同士は元の順、typed同士は投稿順を保つ。音声行の途中に手入力の時刻が入っても音声行を分割せず、その音声行の後ろへ置く。本文一致による削除や相槌判定は行わない。

| 呼び出し位置 | 併合するもの・維持するもの |
|---|---|
| `refreshLive()` | `LiveTranscript.utterances` とtypedEntriesを併合。pendingSpeakerRowsを音声側の添字から変換する。typedをpendingにしない |
| 投稿直後 | 同じ `refreshLive()` を通す。再描画のたびに前回の併合済み配列へ追加しない |
| `stop()` | `MeetingResult.make` が声だけを最終判定してから、originalとprocessedの両方へtypedEntriesを併合する |
| 停止後の `rename` | 併合済みarchiveのnamesだけを更新し、再保存する |
| 停止後の `setSpeakerMapping` | 音声tokens・segmentsだけでMeetingResultを再計算し、archiveのtypedを残して置換する |
| `save()`・AIの返事による再保存 | 既に併合済みのarchiveを保存する。二重に併合しない |

`MeetingArchive.replaceResult(_:)` は `original.utterances` のtypedだけを退避し、渡された声の再計算結果のoriginal・processedそれぞれへ併合する。rawの所有権と省略失敗状態は現状どおり維持する。この方式ならarchive復元後も手入力が残り、archiveへ独立したtyped配列を二重保存する必要がない。

`MeetingResult.make`、`Aligner`、`SpeakerFreeze`、`RepeatedBackchannels`、`SpeakerMapping` は引き続き音声だけを扱う。processedがnilならnilを維持し、手入力を理由に `.raw.md` を新設しない。

行ビューの識別子 `RowID` はkindを含め、同じstartの声と手入力を別に数える。声の再分割によってtypedのビューを声の行へ流用しない。typed内の同時刻の並びには投稿順のoccurrenceを使い、永続IDは増やさない。

## 保存とAI文脈

### Markdownとコピー

会議Markdownと、省略が有効な会議の `.raw.md` に次の行が入る。

```markdown
- [14:05:40] 佐藤: URLを送ります。
- [14:05:42] 手入力: https://example.com/meeting
- [14:05:45] 鈴木: こちらのページですね。
```

Markdownのメタ情報にある4枡の「話者」には手入力を含めない。raw保存に失敗して音声の省略を止めた場合も、通常Markdown・画面の両方に手入力を残す。typedだけで声が一度も確定しなかった会議も保存できる。

手動コピーは既に `snapshot.utterances` → `TranscriptRenderer.lines` を通るので、併合結果がそのまま入る。手入力後に遅れた音声が途中へ挿入された場合は、既存の最長共通接頭部分による訂正範囲を使う。過去の固定済み会話ファイルや再コピー対象は変更しない。

### AI送信は別経路への対応が必要

現在の `submitAI` は画面の配列を使わず、`AICapture` が音声tokensから会話を再構築する。Rendererの表示名変更だけでは手入力が入らない。

1. `submitAI` の呼び出し時点で、cutoff・names・timelineとともにtypedEntriesの値コピーを固定する。最初の `await` より前に行う。
2. `AICapture` にtypedの引数を追加する。確定した声の行を作った後、固定したtypedのうち `start <= cutoff` の行を併合し、`TranscriptRenderer.lines` へ渡す。
3. 確定待ちの再試行でも同じtypedの値コピーを渡す。待ち中に投稿された行は、同じ音声位置であっても今回の送信には混ぜない。
4. `voice`・`voiceUtteranceStart`・`tail`・`needsConfirmation` は声だけから導く。手入力のURLを「空欄なら声の末尾」の問いへ転用しない。
5. 停止後の送信経路にも固定したtypedを渡す。AIプレビューは既に併合済みsnapshotを使うため、実送信と手入力の有無がずれないようにする。

同時刻のtypedを含める `<=` は、声のtokensを切る既存の `< cutoff` とは意図的に異なる。typedは投稿時点で全文が確定しており、一時停止中は音声位置が進まないため、等号を落とすと投稿が次回も送られない。

`AIRequest.voiceAnchorIndex` はkindがvoiceの行だけを候補にする。現在は同じstartの最後の行を選ぶため、修正しないと声の送信印がtypedへ付く。Markdownとウィンドウの両方が同じアンカー関数を使う。

既存の `AIParticipantContext.QuestionSource.typed` はAI送信シートへ書いた問いの由来であり、今回の `Utterance.Kind.typed` とは別の情報である。envelopeや作業許可の契約は変えない。手入力のみの会議をAIへ送る場合は、シートに問いを入力する既存の経路を使う。

## 音声位置と投稿日時

並び順の第一キーは音声位置start、typedの時計表示はpostedAtとする。一時停止中も実際に投稿した日時を保持し、再開の操作で投稿時刻を書き換えない。

`TranscriptRenderer.date(for:timeline:)` でtypedはpostedAt、voiceは従来の `timeline.date(at: start)` を返す。`TranscriptRenderer.clock(for:timeline:seconds:timeZone:)` を時計文字列の単一の口とし、画面のtimeLabel、Markdown、AI会話ファイルが共用する。書式は画面がHH:mm、保存とAI文脈がHH:mm:ss。タイムゾーンの扱いは従来と同じ。

たとえば14:00開始・音声60秒で一時停止し、14:02と14:03に投稿して14:05に再開した場合、typedのstartは両方60だが時計は14:02・14:03で固定される。再開後のstartが60の声の時計だけが14:05となる。手入力へtimelineの停止時間を二重に足さない。

AI印と発話の位置を比較する `AIMarkdown` とウィンドウも、発話の日時取得口を使う。声の時計変換や録音時間自体は変えない。

## 検証項目

| 層 | 必須のケース |
|---|---|
| Core互換 | kindなしの旧Utteranceと旧archiveを読む。voice・typedのJSON往復。未知kindとtypedの不正speakerを拒否 |
| 名前 | voiceのnilは「?」、typedは「手入力」。声の名前変更でtypedが変わらない |
| 併合 | 声の前・間・末尾、同時刻の声とtyped、同時刻の複数typed、同文の連投、声の再分割、pending行の添字変換 |
| archive | original・processed両方へ残る。改名・統合・統合解除・JSON復元後の再保存・raw保存失敗でも消えず重複しない |
| コピー | 初回、手入力追加、遅着の音声による途中訂正、改名後、全体コピー、再コピーの固定ファイル不変 |
| AICapture | cutoffと同時刻は含め、後は除外。確定待ち中の追加投稿は除外。声の末尾・暫定末尾・確定待ち条件がtypedで変わらない |
| AI印 | 同時刻や再分割時でも送信印は声に付く。typedしかないときに声のアンカーを作らない |
| セッション | 録音中と一時停止中の受付、停止との先後、空白拒否、開始時リセット、publishLiveで保持、停止後の再構成とAI返事の再保存 |
| UI | IME確定Enterで未投稿、次のEnterで1回投稿、Escで下書き保持、複数行貼り付け、長いURL、投稿拒否時の下書き保持 |
| UIの行 | 鉛筆と尾なし、改名不可、URLクリックと選択、名前「手入力」と本文の検索、検索強調後もURLが開ける |
| 時刻 | 一時停止中の同時刻連投、再開してもtypedの時計不変、voiceの従来の時計変換、postedAtのJSON往復、収録位置と処理位置がずれた場合のコピー範囲終端 |

段3では投稿直後・声の行の間・一時停止中の投稿・停止後の4画面を実ビューで撮影して目視確認する。段4では既存replayへ開発用の投稿タイミング指定を加え、本番の `submitTyped` を通す。入力値はreplay時だけ解釈し、通常起動には影響させない。URL中の `:` を壊さない形式を使う。

replay検証は専用の出力先で行い、同じURLが通常Markdown・省略前 `.raw.md`・手動コピーの会話ファイル・AI送信用の会話ファイルに現れることを比較する。改名・統合の後にも比較し、行の保持だけでなく声との順序も確認する。実時間の一時停止中に投稿して再開し、声の時計だけが停止時間分ずれる区間も含める。IMEの操作は実ビューの検証で補う。

## 実装の段取りと文書更新

- 段2: Utterance.kind、表示名、併合とpendingの変換、archive、AICapture、声のアンカーとCoreテスト。
- 段3: セッションでの独立保持、AI送信時の固定、入力欄、行表示と検索、コールバックの配線、実画面検証。
- 段4: replayから投稿・停止・保存・改名・統合を通し、各出力を検証する。

実録での段4の結果は [手入力の端から端の検証](typed-entry-verification.md) に記録した。

実装時に `skills/kikigaki/SKILL.md` へ「`手入力` は声ではなく利用者が入力欄から投稿した行。URLの共有などに使う」を追記する。会話一般をすべて音声認識結果とする説明もvoiceに限定し、手入力が新しい権限を与えるようには書かない。

`README.md` と `CLAUDE.md` に操作と受付状態、`docs/ai-handoff.md` に行の意味とコピー契約を追加する。同文書の古い全幅ボタンと旧表題の説明は、既に統合された固定幅・「続きをコピー」に合わせる。AI送信の別経路を扱うため `docs/ai-participant.md` にも送信時点で手入力を固定する規則を追記する。
