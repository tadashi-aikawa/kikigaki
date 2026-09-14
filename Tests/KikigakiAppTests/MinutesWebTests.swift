import AppKit
import WebKit
import Darwin
import Testing
@testable import Kikigaki

@Suite(.serialized) @MainActor struct MinutesWebTests {
    @Test func WebKitのカーソル更新を親の矢印で上書きしない() throws {
        final class Parent: NSView {
            var updates = 0
            override func cursorUpdate(with event: NSEvent) {
                updates += 1
                NSCursor.arrow.set()
            }
        }
        let parent = Parent(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let document = MinutesWebView(frame: parent.bounds)
        parent.addSubview(document)
        defer { document.invalidate() }
        let previous = NSCursor.current
        defer { previous.set() }
        let event = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: NSPoint(x: 50, y: 50),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        // 本文・リンク・余白をWebKitが設定した後のAppKit更新を再現する。
        for cursor in [NSCursor.iBeam, .pointingHand, .arrow] {
            cursor.set()
            document.webView.cursorUpdate(with: event)
            #expect(NSCursor.current == cursor)
        }
        #expect(parent.updates == 0)
    }

    @Test func 検索メニューはWebKit本文から議事録ペインへ届く() async throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TranscriptWindowController(minutesDefaults: defaults)
        controller.window?.setFrameAutosaveName("")
        controller.show()
        if !controller.minutesSplit.isPreviewVisible { controller.toggleMinutes() }
        defer { controller.minutesSplit.preview.stop(); controller.window?.orderOut(nil) }
        let preview = controller.minutesSplit.preview
        #expect(controller.window?.makeFirstResponder(preview.document.webView) == true)
        let menu = ApplicationMenu.make()
        let edit = try #require(menu.items.first { $0.submenu?.title == "編集" }?.submenu)
        let action = try #require(edit.items.first { $0.keyEquivalent == "f" }?.action)
        // 非アクティブなテストプロセスでも、本文から実際のresponder chainをたどる。
        #expect(preview.document.webView.tryToPerform(action, with: nil))
        #expect(preview.searchField.currentEditor() != nil)
        #expect(!controller.searchOpen)
    }
    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("WebKitの表示が完了しません")
    }
    @Test func 目次の移動と中断と着地後の位置追従を扱う() async throws {
        let document = MinutesWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(contentRect: document.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let source = "# 親\n\n" + (1...35).map { "## 項目\($0)\n\n" + String(repeating: "会議の決定事項と担当者を確認します。\n\n", count: 3) }.joined()
        document.render(source, reset: true)
        try await wait { document.renderedText.contains("項目35") }
        let web = document.webView
        // WebKitは描画の依頼で作られ、制約で窓の大きさへ広がる。途中で幅が変わると見出しの位置がずれるため、窓の大きさに揃うまで待つ。
        try await wait { try await web.evaluateJavaScript("innerWidth === 700 && innerHeight === 500") as? Bool == true }
        // 手元のテストプロセスでは実フレームが進まない。CIで進むかどうかは失敗時の状態に添えて見分ける。
        let frames = try await web.callAsyncJavaScript("""
        return await Promise.race([new Promise(done => requestAnimationFrame(() => done('進む'))),
          new Promise(done => setTimeout(() => done('進まない'), 300))]);
        """, contentWorld: .page) as? String ?? "?"
        // CIでだけ落ちるときに原因を追えるよう、条件が成り立たなければ位置と目次の状態を添える。
        func check(_ condition: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let result = try await web.evaluateJavaScript("(() => { try { return \(condition); } catch (error) { return String(error); } })()")
            guard result as? Bool != true else { return }
            let state = try await web.evaluateJavaScript("""
            JSON.stringify({ result: \(String(describing: result).debugDescription), realFrames: \(frames.debugDescription), size: [innerWidth, innerHeight, devicePixelRatio],
              scrollY, scrollHeight: document.scrollingElement.scrollHeight, destination: window.destination,
              top: window.target?.getBoundingClientRect().top, animations: window.target?.getAnimations().length,
              current: [...(window.links ?? [])].findIndex(link => link.hasAttribute('aria-current')),
              frames: window.testFrames?.size })
            """) as? String ?? "?"
            Issue.record("\(condition)\n状態: \(state)", sourceLocation: sourceLocation)
        }
        // 描画自体は実WebKit。フレームの時計だけを固定し、端末負荷で0.25秒の検証が揺れないようにする。
        _ = try await web.evaluateJavaScript("""
        window.testFrames = new Map(); window.testFrameID = 0;
        window.requestAnimationFrame = callback => { const id = ++testFrameID; testFrames.set(id, callback); return id; };
        window.cancelAnimationFrame = id => testFrames.delete(id);
        window.tick = elapsed => { const callbacks = [...testFrames.values()]; testFrames.clear(); callbacks.forEach(f => f(testStart + elapsed)); };
        window.testStart = 10000;
        window.navigate = index => { testStart += 1000; links[index].click(); tick(0); };
        window.matchMedia = () => ({ matches:false });
        document.querySelector('#toc summary').click();
        window.links = document.querySelectorAll('#toc nav a');
        window.target = document.querySelectorAll('main h2')[24];
        navigate(25);
        window.destination = target.getBoundingClientRect().top + scrollY;
        tick(125);
        """)
        try await check("scrollY > destination * 0.8 && scrollY < destination && target.getAnimations().length === 0")
        _ = try await web.evaluateJavaScript("tick(250)")
        // 着地は上端ぴったりではなく、5文字分の75pxを上に残す。
        try await check("Math.abs(target.getBoundingClientRect().top - 75) < 2 && target.getAnimations()[0].effect.getTiming().duration === 1000 && links[25].getAttribute('aria-current') === 'location'")
        _ = try await web.evaluateJavaScript("navigate(10); tick(125); navigate(35); tick(250)")
        try await check("links[35].getAttribute('aria-current') === 'location' && document.querySelectorAll('main h2')[9].getAnimations().length === 0 && target.getAnimations().length === 0")
        _ = try await web.evaluateJavaScript("window.dispatchEvent(new Event('scroll')); tick(600)")
        try await check("links[35].getAttribute('aria-current') === 'location'")
        // scrollイベントを送るだけでは位置は変わらない。実スクロールで解除後、元の位置へ戻しても復活しないこと。
        _ = try await web.evaluateJavaScript("window.landedY = scrollY; scrollTo(0,0); window.dispatchEvent(new Event('scroll')); tick(600)")
        try await check("links[0].getAttribute('aria-current') === 'location'")
        _ = try await web.evaluateJavaScript("scrollTo(0,landedY); window.dispatchEvent(new Event('scroll')); tick(600)")
        try await check("document.querySelector('#toc [aria-current]') !== null && !links[35].hasAttribute('aria-current')")
        // スクロール量を変えずに遅延レイアウトで見出しが上下へ外れても、着地先を選択し続けない。
        for direction in [-1, 1] {
            _ = try await web.evaluateJavaScript("navigate(35); tick(250); window.lastHeading = document.querySelectorAll('main h2')[34]; lastHeading.style.transform = 'translateY(' + innerHeight * \(direction * 2) + 'px)'; window.dispatchEvent(new Event('resize')); tick(600)")
            try await check("scrollY === landedY && !links[35].hasAttribute('aria-current')")
            _ = try await web.evaluateJavaScript("lastHeading.style.transform = ''")
        }
        for event in ["wheel", "keydown", "touchstart"] {
            _ = try await web.evaluateJavaScript("navigate(10); tick(125); window.interruptedY = scrollY; window.dispatchEvent(new Event('\(event)')); tick(250)")
            try await check("scrollY === interruptedY && document.querySelectorAll('main h2')[9].getAnimations().length === 0")
        }
        // ヒットなし・表示位置を変えない検索も、残った移動が検索操作を打ち消さないこと。
        for search in ["window.minutes.search('存在しない語')", "window.minutes.search('決定事項', 0, false)"] {
            _ = try await web.evaluateJavaScript("navigate(10); tick(125); window.interruptedY = scrollY; \(search); tick(250)")
            try await check("scrollY === interruptedY && document.querySelectorAll('main h2')[9].getAnimations().length === 0")
        }
        _ = try await web.evaluateJavaScript("""
        window.matchMedia = () => ({ matches:true });
        document.querySelector('.heading-toggle').click(); links[25].click();
        """)
        try await check("!document.querySelector('.section-body').hidden && Math.abs(target.getBoundingClientRect().top - 75) < 2 && target.getAnimations()[0].effect.getTiming().duration === 1000 && links[25].getAttribute('aria-current') === 'location'")
        // root.containsのフレーム時ガードやrender後半の検索更新では遅い。DOMを入れ替える前に取消済みかを記録する。
        _ = try await web.evaluateJavaScript("""
        window.matchMedia = () => ({ matches:false }); navigate(10);
        window.pendingNavigation = testFrameID;
        const descriptor = Object.getOwnPropertyDescriptor(Element.prototype, 'innerHTML');
        Object.defineProperty(document.querySelector('main'), 'innerHTML', {
          configurable:true,
          get() { return descriptor.get.call(this); },
          set(value) { window.cancelledBeforeReplacement = !testFrames.has(pendingNavigation); descriptor.set.call(this, value); }
        });
        void 0;
        """)
        document.render("# 新しい議事録", reset: true)
        try await wait { document.renderedText.contains("新しい議事録") }
        try await check("cancelledBeforeReplacement")
        _ = try await web.evaluateJavaScript("tick(600)")
        try await check("scrollY === 0 && document.querySelector('main h1').getAnimations().length === 0")
    }
    @Test func AI依頼中の編集は基準との差分を累積で強調し置き直しと切替で消える() async throws {
        let preferences = MinutesTestDefaults()
        let preview = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 700, height: 600), defaults: preferences.value)
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = preview; window.orderFront(nil); preview.layoutSubtreeIfNeeded()
        defer { preview.stop(); window.orderOut(nil) }
        func capture(_ name: String, _ web: WKWebView) async throws {
            guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_MINUTES_CAPTURE"] else { return }
            let snapshot = try await web.takeSnapshot(configuration: WKSnapshotConfiguration())
            let data = try #require(snapshot.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        }
        let base = """
        # 体験会の議事録

        ## 決定事項

        - 開催日は9月18日
        """
        var text = base + "\n"
        preview.document.render(text, reset: true)
        try await wait { preview.document.renderedText.contains("開催日") }
        let web = preview.document.webView
        #expect(try await web.evaluateJavaScript("!CSS.highlights.has('updated')") as? Bool == true)
        // AIへ依頼を送った時点の本文を基準にする
        preview.markUpdateBaseline()
        for (index, line) in ["参加者は社内10名", "受付は佐藤さんが担当", "次回は10月2日"].enumerated() {
            text += "- " + line + "\n"
            preview.document.render(text, reset: false)
            try await wait { preview.document.renderedText.contains(line) }
            // 1依頼の中の編集は消えずに積み上がる
            #expect(try await web.evaluateJavaScript("CSS.highlights.get('updated').size") as? Int == index + 1)
        }
        try await capture("baseline-accumulated", web)
        // 変更を含む見出しは目次にも印が出る。直下が変わった「決定事項」は塗り、上位は輪郭。
        #expect(try await web.evaluateJavaScript("[...document.querySelectorAll('#toc nav a')].map(a => a.dataset.updated || '').join(',')") as? String == "descendant,self")
        try await Task.sleep(for: .milliseconds(4200))
        #expect(try await web.evaluateJavaScript("CSS.highlights.get('updated').size") as? Int == 3)
        // 次の依頼の送信か編集の開始で、それまでの強調を消して基準を置き直す
        preview.markUpdateBaseline()
        #expect(try await web.evaluateJavaScript("!CSS.highlights.has('updated')") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelector('#toc nav a[data-updated]') === null") as? Bool == true)
        try await capture("baseline-remarked", web)
        text += "- 会場は第2会議室\n"
        preview.document.render(text, reset: false)
        try await wait { preview.document.renderedText.contains("第2会議室") }
        #expect(try await web.evaluateJavaScript("CSS.highlights.get('updated').size") as? Int == 1)
        #expect(try await web.evaluateJavaScript("[...CSS.highlights.get('updated')].every(r => r.toString() === '会場は第2会議室')") as? Bool == true)
        // 表示対象の切替で基準を捨て、AI依頼のない更新は従来どおり4秒で消える
        preview.document.render(base + "\n- 別の議事録\n", reset: true)
        try await wait { preview.document.renderedText.contains("別の議事録") }
        #expect(try await web.evaluateJavaScript("!CSS.highlights.has('updated')") as? Bool == true)
        preview.document.render(base + "\n- 別の議事録\n- 人が足した行\n", reset: false)
        try await wait { preview.document.renderedText.contains("人が足した行") }
        #expect(try await web.evaluateJavaScript("CSS.highlights.get('updated').size") as? Int == 1)
        try await Task.sleep(for: .milliseconds(4200))
        #expect(try await web.evaluateJavaScript("!CSS.highlights.has('updated')") as? Bool == true)
    }
    @Test func 描く前に送った依頼の基準は最初の描画の後に効いて累積する() async throws {
        let preferences = MinutesTestDefaults()
        let preview = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 700, height: 600), defaults: preferences.value)
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = preview; window.orderFront(nil); preview.layoutSubtreeIfNeeded()
        defer { preview.stop(); window.orderOut(nil) }
        // 依頼を送った時点ではまだ議事録を描いていない。WebKitも作らない
        preview.markUpdateBaseline()
        #expect(preview.document.pendingBaseline && !preview.document.hasLoadedWebView)
        let base = "# 体験会の議事録\n\n- 開催日は9月18日\n"
        // AIが作った議事録の初回表示。対象切替の描画で基準を捨てず、描き終えた本文を基準にする
        preview.document.render(base, reset: true)
        try await wait { preview.document.renderedText.contains("開催日") }
        let web = preview.document.webView
        try await wait { !preview.document.pendingBaseline }
        #expect(try await web.evaluateJavaScript("!CSS.highlights.has('updated')") as? Bool == true)
        var text = base
        for (index, line) in ["参加者は社内10名", "受付は佐藤さんが担当"].enumerated() {
            text += "- " + line + "\n"
            preview.document.render(text, reset: false)
            try await wait { preview.document.renderedText.contains(line) }
            #expect(try await web.evaluateJavaScript("CSS.highlights.get('updated').size") as? Int == index + 1)
        }
        try await Task.sleep(for: .milliseconds(4200))
        #expect(try await web.evaluateJavaScript("CSS.highlights.get('updated').size") as? Int == 2)
    }
    @Test func HTMLの安全境界と折りたたみ脚注画像目次を組み合わせる() async throws {
        let preferences = MinutesTestDefaults()
        let preview = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 700, height: 600), defaults: preferences.value)
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = preview; window.orderFront(nil); preview.layoutSubtreeIfNeeded()
        defer { preview.stop(); window.orderOut(nil) }
        let fixture = """
        # 親

        ## 長い見出しで幅を測る対象

        隠れる本文[^one]。

        <span style="color:red;position:fixed;inset:0;background-image:url(https://example.invalid/evil);margin:-20px" onclick="window.INJECTED=true">赤いHTML</span>

        <div id="toc" class="heading-toggle" style="padding:8px;border:1px solid purple">HTMLの箱</div>

        <script>window.INJECTED=true</script>
        <iframe src="https://example.invalid"></iframe>
        <form><input autofocus onfocus="window.INJECTED=true"></form>
        <style>body{display:none}</style>

        :::{note}
        MySTの**本文**。
        :::

        ## 次の節

        次の本文。

        ~~~svg
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><rect width="100" height="50" fill="purple"/></svg>
        ~~~

        [^one]: 着地点の脚注。
        """
        preview.document.render(fixture, reset: true)
        try await wait { preview.document.renderedText.contains("着地点の脚注") }
        let web = preview.document.webView
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('main script,main iframe,main form,main style,main [onclick]').length === 0 && !window.INJECTED") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelector('main span[style]').style.color === 'red' && !document.querySelector('main span[style]').style.position && !document.querySelector('main span[style]').style.backgroundImage && !document.querySelector('main span[style]').style.margin") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#toc').length === 1 && document.getElementById('html-toc').className === ''") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelector('.callout strong').textContent === '本文' && !!document.querySelector('.callout-title svg')") as? Bool == true)
        let closedWidth = try #require(try await web.evaluateJavaScript("document.getElementById('toc').getBoundingClientRect().width") as? Double)
        _ = try await web.evaluateJavaScript("document.querySelector('#toc summary').click()")
        #expect(try await web.evaluateJavaScript("document.getElementById('toc').getBoundingClientRect().width") as? Double == closedWidth)
        _ = try await web.evaluateJavaScript("document.querySelectorAll('.heading-toggle')[1].click()")
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.section-body')[1].hidden && document.querySelectorAll('.section-body')[2].hidden === false") as? Bool == true)
        _ = try await web.evaluateJavaScript("window.minutes.search('隠れる本文')")
        #expect(try await web.evaluateJavaScript("!document.querySelectorAll('.section-body')[1].hidden") as? Bool == true)
        _ = try await web.evaluateJavaScript("window.originalMatchMedia = window.matchMedia; window.matchMedia = () => ({ matches:true }); document.querySelector('.footnote-ref a').click()")
        #expect(try await web.evaluateJavaScript("document.getElementById('fn1').getAnimations().length === 1") as? Bool == true)
        _ = try await web.evaluateJavaScript("document.querySelectorAll('.heading-toggle')[1].click(); document.querySelector('.footnote-backref').click()")
        #expect(try await web.evaluateJavaScript("!document.querySelectorAll('.section-body')[1].hidden && document.querySelector('.footnote-ref').getAnimations().length === 1") as? Bool == true)
        _ = try await web.evaluateJavaScript("window.matchMedia = window.originalMatchMedia; void 0;")
        try await wait { try await web.evaluateJavaScript("document.querySelector('main img').naturalWidth > 0") as? Bool == true }
        _ = try await web.evaluateJavaScript("document.querySelector('main img').click()")
        #expect(try await web.evaluateJavaScript("document.getElementById('image-modal').open && document.querySelector('#image-modal img').src === document.querySelector('main img').src") as? Bool == true)
        _ = try await web.evaluateJavaScript("document.querySelector('#image-modal button').click(); document.querySelectorAll('.heading-toggle')[1].click()")
        preview.document.render(fixture + "\n\n追記", reset: false)
        try await wait { preview.document.renderedText.contains("追記") }
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.section-body')[1].hidden && document.getElementById('toc').open && !document.getElementById('image-modal').open") as? Bool == true)
        _ = try await web.evaluateJavaScript("document.querySelectorAll('#toc nav a')[1].click()")
        #expect(try await web.evaluateJavaScript("!document.querySelectorAll('.section-body')[1].hidden || document.querySelectorAll('.heading-toggle')[1].getClientRects().length > 0") as? Bool == true)
        let paragraphs = (0..<80).map { "段落\($0)の本文" }.joined(separator: "\n\n")
        preview.document.render("# 更新位置\n\n" + paragraphs, reset: true)
        try await wait { preview.document.renderedText.contains("段落79") }
        _ = try await web.evaluateJavaScript("document.querySelectorAll('main p')[60].scrollIntoView({block:'start'})")
        let position = try #require(try await web.evaluateJavaScript("document.querySelectorAll('main p')[60].getBoundingClientRect().top") as? Double)
        preview.document.render("# 更新位置\n\n" + String(repeating: "上へ挿入\n\n", count: 10) + paragraphs, reset: false)
        try await wait { preview.document.renderedText.contains("上へ挿入") }
        let restored = try #require(try await web.evaluateJavaScript("document.querySelectorAll('main p')[70].getBoundingClientRect().top") as? Double)
        #expect(abs(position - restored) < 1)
        #expect(try await web.evaluateJavaScript("CSS.highlights.get('updated').size === 10") as? Bool == true)
        #expect(try await web.evaluateJavaScript("[...CSS.highlights.get('updated')].every(r => r.toString() === '上へ挿入')") as? Bool == true)
        if let capture = ProcessInfo.processInfo.environment["KIKIGAKI_MINUTES_CAPTURE"] {
            _ = try await web.evaluateJavaScript("scrollTo(0,0)")
            let screenshot = try await web.takeSnapshot(configuration:WKSnapshotConfiguration())
            let data = try #require(screenshot.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data:data))
            try #require(bitmap.representation(using:.png, properties:[:])).write(to:URL(fileURLWithPath:capture).appendingPathComponent("updated-lines.png"))
        }
        try await Task.sleep(for: .milliseconds(4200))
        #expect(try await web.evaluateJavaScript("!CSS.highlights.has('updated')") as? Bool == true)
        if let sample = ProcessInfo.processInfo.environment["KIKIGAKI_MINUTES_SAMPLE"],
           let capture = ProcessInfo.processInfo.environment["KIKIGAKI_MINUTES_CAPTURE"] {
            preview.update(path: sample, source: .human, active: true)
            try await wait { preview.document.renderedText.contains("MyST形式のnote") }
            #expect(try await web.evaluateJavaScript("document.querySelectorAll('.callout').length >= 6") as? Bool == true)
            try await wait { try await web.evaluateJavaScript("[...document.querySelectorAll('main img')].every(i => i.complete && i.naturalWidth > 0)") as? Bool == true }
            _ = try await web.evaluateJavaScript("document.querySelector('.callout').scrollIntoView({block:'start'})")
            let snapshot = try await web.takeSnapshot(configuration: WKSnapshotConfiguration())
            let imageData = try #require(snapshot.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: imageData))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: capture).appendingPathComponent("user-sample-callouts.png"))
            _ = try await web.evaluateJavaScript("document.querySelector('main img').click()")
            try await wait { try await web.evaluateJavaScript("document.querySelector('#image-modal img').naturalWidth > 0") as? Bool == true }
            // 非アクティブなWebKitのアニメーション時計は止まるため、完成状態を撮影する。
            _ = try await web.evaluateJavaScript("document.getElementById('image-modal').getAnimations().forEach(a => a.finish())")
            _ = try await web.callAsyncJavaScript("await document.querySelector('#image-modal img').decode(); return true", arguments: [:], in: nil, contentWorld: .page)
            try await Task.sleep(for: .milliseconds(150))
            #expect(try await web.evaluateJavaScript("document.querySelector('#image-modal img').getBoundingClientRect().top >= 0 && document.querySelector('#image-modal button').getBoundingClientRect().right <= innerWidth") as? Bool == true)
            let modal = try await web.takeSnapshot(configuration: WKSnapshotConfiguration())
            let modalData = try #require(modal.tiffRepresentation)
            let modalBitmap = try #require(NSBitmapImageRep(data: modalData))
            try #require(modalBitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: capture).appendingPathComponent("user-sample-image.png"))
        }
    }
    @Test func 図と画像と数式を実際のWebKitで描いて検索する() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("会場 図.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="240" height="70"><rect width="240" height="70" fill="tan"/><text x="20" y="40">会場</text></svg>"#.utf8).write(to: image)
        let file = root.appendingPathComponent("議事録.md")
        let fixture = """
        ---
        title: hidden
        ---
        # 体験会の準備会議

        9月18日の午後、社内10名を対象に試行する方針で合意しました。

        ## 決定事項 {#decisions}

        - [x] 社内で開催
          - **説明**と体験を合わせて30分
        - [ ] 受付担当を確認

        > [!NOTE] 開催条件
        > 接続テストを前日までに行います。

        | 担当 | 作業 | 期限 |
        | --- | --- | --- |
        | 佐藤 | 案内文の作成 | 9/10 |
        | 鈴木 | [[準備手順\\|確認事項]]の更新 | 9/11 |

        参加率は $r=\\frac{参加者数}{対象者数}$ とします。[^rate]

        [^rate]: 欠席の連絡も集計に含めます。

        ## 当日の流れ

        ~~~mermaid
        flowchart LR
          A[説明] --> B[体験] --> C[質問]
        ~~~

        ![[会場 図.svg|240]]

        ![絶対パスの図](<\(image.path)>)

        ~~~svg
        <svg xmlns="http://www.w3.org/2000/svg" width="240" height="70"><circle cx="35" cy="35" r="25" fill="purple"/><text x="75" y="40">受付</text></svg>
        ~~~

        <script>window.INJECTED = true</script>
        """
        try Data(fixture.utf8).write(to: file)
        let preferences = MinutesTestDefaults()
        let preview = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1500), defaults: preferences.value)
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = preview; window.orderFront(nil); preview.layoutSubtreeIfNeeded()
        defer { preview.stop(); window.orderOut(nil) }
        preview.update(path: file.path, source: .human, active: true)
        try await wait { preview.document.renderedText.contains("体験会の準備会議") }
        let web = preview.document.webView
        // チェックの有無で、本文に対する丸の縦位置が変わらないこと。
        let checkboxOffsets = try await web.evaluateJavaScript("[...document.querySelectorAll('.task-list-item-checkbox')].map(box => { const text = document.createRange(); text.selectNodeContents(box.nextSibling); return box.getBoundingClientRect().top - text.getBoundingClientRect().top; })") as? [Double]
        let offsets = try #require(checkboxOffsets)
        #expect(offsets.count == 2)
        #expect(abs(offsets[0] - offsets[1]) < 0.5)
        #expect(try await web.evaluateJavaScript("getComputedStyle(document.body).fontSize") as? String == "15px")
        #expect(try await web.evaluateJavaScript("!document.getElementById('toc').hidden && !document.getElementById('toc').open") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#toc nav a').length") as? Int == 3)
        window.setContentSize(NSSize(width: 1200, height: 400)); preview.layoutSubtreeIfNeeded()
        try await wait { try await web.evaluateJavaScript("innerHeight < 500") as? Bool == true }
        // 非アクティブなテスト窓ではrAFが抑止されるため、ここで調べる目次・検索の連携は縮退経路を使う。
        _ = try await web.evaluateJavaScript("window.originalMatchMedia = window.matchMedia; window.matchMedia = () => ({ matches:true }); document.querySelector('#toc summary').click(); document.querySelectorAll('#toc nav a')[2].click(); window.matchMedia = window.originalMatchMedia; void 0;")
        try await wait { try await web.evaluateJavaScript("document.querySelector('#toc a[aria-current]')?.textContent === '当日の流れ'") as? Bool == true }
        #expect(try await web.evaluateJavaScript("document.getElementById('toc').open && document.querySelector('#toc a[aria-current]').textContent === '当日の流れ'") as? Bool == true)
        _ = try await web.evaluateJavaScript("document.querySelector('main').dispatchEvent(new PointerEvent('pointerdown', {bubbles:true})); scrollTo(0,0)")
        #expect(try await web.evaluateJavaScript("document.getElementById('toc').open") as? Bool == true)
        window.setContentSize(NSSize(width: 1200, height: 1500)); preview.layoutSubtreeIfNeeded()
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.diagram svg').length") as? Int == 1)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.katex').length") as? Int == 1)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.callout').length") as? Int == 1)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.footnotes').length") as? Int == 1)
        #expect(try await web.evaluateJavaScript("window.INJECTED === undefined") as? Bool == true)
        try await wait {
            try await web.evaluateJavaScript("[...document.querySelectorAll('main img')].length === 3 && [...document.querySelectorAll('main img')].every(i => i.complete && i.naturalWidth > 0)") as? Bool == true
        }
        let state = try await web.evaluateJavaScript("window.minutes.state()") as? [String: Any]
        #expect(try #require(state?["width"] as? Double) > 720)
        let search = try await web.evaluateJavaScript("window.minutes.search('説明と体験')") as? [String: Int]
        #expect(search?["count"] == 1)
        #expect(try await web.evaluateJavaScript("CSS.highlights.get('matches').size") as? Int == 1)
        #expect(window.makeFirstResponder(preview.pathField))
        _ = try await web.evaluateJavaScript("document.querySelector('main').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))")
        try await wait { window.firstResponder === web }
        #expect(preview.hasSearchFocus)
        preview.showSearch()
        #expect(preview.searchField.currentEditor() != nil)
        preview.searchField.stringValue = "体験"; preview.search()
        #expect(preview.pathField.stringValue == file.path)
        preview.closeSearch()
        preview.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        #expect(web.bounds.width > 0 && web.bounds.height > 0)
        if let capture = ProcessInfo.processInfo.environment["KIKIGAKI_MINUTES_CAPTURE"] {
            _ = try await web.evaluateJavaScript("scrollTo(0, 0)")
            let snapshot = try await web.takeSnapshot(configuration: WKSnapshotConfiguration())
            let data = try #require(snapshot.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: capture).appendingPathComponent("markdown-features.png"))
        }
        window.setContentSize(NSSize(width: 440, height: 700)); preview.layoutSubtreeIfNeeded()
        try await wait { try await web.evaluateJavaScript("innerWidth < 500") as? Bool == true }
        #expect(try await web.evaluateJavaScript("document.documentElement.scrollWidth <= innerWidth") as? Bool == true)
        preview.showSearch(); preview.searchField.stringValue = "体験"; preview.search()
        _ = try await web.evaluateJavaScript("scrollTo(0, 300)")
        let before = try await web.evaluateJavaScript("scrollY") as? Double
        try Data((fixture + "\n\n追記を確認").utf8).write(to: file, options: .atomic)
        try await wait { preview.document.renderedText.contains("追記を確認") }
        try await Task.sleep(for: .milliseconds(150))
        let after = try await web.evaluateJavaScript("scrollY") as? Double
        #expect(abs(try #require(before) - #require(after)) < 2)
        preview.document.render(String(repeating: "# 見出し\n\n", count: 1000), reset: true)
        try await wait { try await web.evaluateJavaScript("document.querySelectorAll('main h1').length === 1000") as? Bool == true }
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#toc a').length") as? Int == 300)
        #expect(try await web.evaluateJavaScript("document.querySelector('#toc nav').textContent.includes('先頭300見出し')") as? Bool == true)
        preview.document.render("見出しなし", reset: true)
        try await wait { preview.document.renderedText == "見出しなし" }
        #expect(try await web.evaluateJavaScript("document.getElementById('toc').hidden") as? Bool == true)
    }
    @Test func 画像取得は通常ファイルと上限を守り非画像やFIFOを拒否する() throws {
        let preferences = MinutesTestDefaults()
        let preview = MinutesPreviewView(frame: .zero, defaults: preferences.value)
        preview.resetContext(); preview.stop()
        #expect(!preview.document.hasLoadedWebView)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("定例.md")
        #expect(MinutesResourceHandler.imageFile("notes.md", relativeTo: file) == nil)
        #expect(MinutesResourceHandler.imageFile("javascript:evil.png", relativeTo: file) == nil)
        #expect(MinutesResourceHandler.imageFile("写真 a.png", relativeTo: file)?.lastPathComponent == "写真 a.png")
        #expect(MinutesResourceHandler.imageFile("写真%20a.png", relativeTo: file)?.lastPathComponent == "写真%20a.png")
        let fifo = root.appendingPathComponent("fifo.png")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try MinutesResourceHandler.bytes(fifo) }
        let image = root.appendingPathComponent("x.png"); try Data(repeating: 1, count: 100).write(to: image)
        #expect(throws: (any Error).self) { try MinutesResourceHandler.bytes(image, limit: 99) }
    }
    @Test func 字下げのadmonitionを実WebKitでcalloutとして描く() async throws {
        let preferences = MinutesTestDefaults()
        let preview = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 700, height: 600), defaults: preferences.value)
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = preview; window.orderFront(nil); preview.layoutSubtreeIfNeeded()
        defer { preview.stop(); window.orderOut(nil) }
        let fixture = """
        !!! info "会議の下書き"

            **決めたこと**を1行目<br>2行目で残す。

            - 項目

        !!! question ""

            題のない枠。

        通常の段落。

            インデントコード
        """
        preview.document.render(fixture, reset: true)
        try await wait { preview.document.renderedText.contains("題のない枠") }
        let web = preview.document.webView
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('main aside.callout').length") as? Int == 2)
        // 題の帯とアイコンはMySTのcalloutと同じ作りで、既存のkinds外の種別語はnoteの顔へ寄せる。
        #expect(try await web.evaluateJavaScript("""
            document.querySelector('main .callout').dataset.kind === 'info' &&
            document.querySelector('main .callout').dataset.face === 'note' &&
            document.querySelector('main .callout-title').textContent === '会議の下書き' &&
            !!document.querySelector('main .callout-title svg') &&
            document.querySelectorAll('main .callout')[1].dataset.kind === 'question' &&
            document.querySelectorAll('main .callout')[1].querySelector('.callout-title') === null
            """) as? Bool == true)
        // 本文はMarkdownとして再分解し、`<br>` も実要素になる。
        #expect(try await web.evaluateJavaScript("""
            !!document.querySelector('main .callout strong') && !!document.querySelector('main .callout li') &&
            document.querySelectorAll('main .callout br').length === 1
            """) as? Bool == true)
        // `!!!` の直後でない字下げは従来どおりコードのまま。
        #expect(try await web.evaluateJavaScript(
            "document.querySelector('main pre code').textContent.trim() === 'インデントコード'") as? Bool == true)
    }
    @Test func Vault内のwikilinkを実WebKitでリンクとして描く() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let preferences = MinutesTestDefaults()
        let preview = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 700, height: 600), defaults: preferences.value)
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = preview; window.orderFront(nil); preview.layoutSubtreeIfNeeded()
        defer { preview.stop(); window.orderOut(nil) }
        preview.document.setFile(vault.appendingPathComponent("定例.md"))
        #expect(preview.document.vault == "Vault")
        final class Opened { var urls: [URL] = [] }
        let opened = Opened()
        preview.document.openURL = { opened.urls.append($0) }
        preview.document.render("[[議事/前回.md|前回]]の続き。\n", reset: true)
        try await wait { preview.document.renderedText.contains("前回の続き") }
        let web = preview.document.webView
        // DOMPurifyがdata-wikiを落とさず、hrefを持たないので勝手に遷移もしない。
        #expect(try await web.evaluateJavaScript(
            "document.querySelector('main a.wiki')?.dataset.wiki === '議事/前回.md' && !document.querySelector('main a.wiki').hasAttribute('href')") as? Bool == true)
        // 実クリックがObsidianのURIまで届く。末尾の `.md` は落ち、`/` も符号化する。
        _ = try await web.evaluateJavaScript("document.querySelector('main a.wiki').click()")
        try await wait { !opened.urls.isEmpty }
        #expect(opened.urls.map(\.absoluteString) == ["obsidian://open?vault=Vault&file=%E8%AD%B0%E4%BA%8B%2F%E5%89%8D%E5%9B%9E"])
        // Vault外へ切り替えると平文へ戻る。
        preview.document.setFile(root.appendingPathComponent("外.md"))
        #expect(preview.document.vault == nil)
        preview.document.render("[[議事/前回.md|前回]]だけ。\n", reset: true)
        try await wait { preview.document.renderedText.contains("前回だけ") }
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('main a.wiki').length === 0") as? Bool == true)
    }
    @Test func 表の列を内容幅に収めて短い表は狭く広い表は折り返す() async throws {
        let document = MinutesWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        let window = NSWindow(contentRect: document.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let wide = String(repeating: "案内文の作成と会場の確認を担当します。", count: 4)
        let task = String(repeating: "案内文を作成して会場を確認する。", count: 2)
        let items = String(repeating: "会場の鍵と配布資料一式、受付の名簿。", count: 2)
        document.render("""
        | 担当 | 期限 |
        | --- | --- |
        | 佐藤 | 9/10 |

        | 担当 | 作業 |
        | --- | --- |
        | 佐藤 | \(wide) |

        | 担当 | 次回までに行うこと | 準備物 |
        | --- | --- | --- |
        | 佐藤 | \(task) | \(items) |

        """, reset: true)
        try await wait { document.renderedText.contains("9/10") }
        let web = document.webView
        let measured = try await web.evaluateJavaScript("""
        const wraps = [...document.querySelectorAll('.table-wrap')];
        const tables = wraps.map(wrap => wrap.querySelector('table'));
        const cells = tables.map(table => [...table.querySelectorAll('td')]);
        ({ pane: document.querySelector('main').clientWidth,
           tables: tables.map(table => table.getBoundingClientRect().width),
           first: cells.map(row => row[0].getBoundingClientRect().width),
           firstHeight: cells.map(row => row[0].getBoundingClientRect().height),
           wrapped: cells[1][1].getBoundingClientRect().height,
           overflow: wraps.map(wrap => wrap.scrollWidth - wrap.clientWidth),
           fitted: tables.map(table => table.querySelectorAll(':scope > colgroup[data-fit]').length) })
        """) as? [String: Any]
        let sizes = try #require(measured)
        let pane = try #require(sizes["pane"] as? Double)
        let widths = try #require(sizes["tables"] as? [Double])
        let first = try #require(sizes["first"] as? [Double])
        let firstHeight = try #require(sizes["firstHeight"] as? [Double])
        let overflow = try #require(sizes["overflow"] as? [Double])
        let fitted = try #require(sizes["fitted"] as? [Double])
        // 短い表はペイン幅の半分未満に収まり、列幅を配らない。
        #expect(widths[0] < pane / 2)
        #expect(fitted[0] == 0)
        // 2文字の列は旧来の下限80ptまで広がらず、広い表でも内容の幅に留まる。
        #expect(first[0] < 60 && first[1] < 60)
        // 長い本文の表はペイン幅までで、超えた分はセル内で折り返す(1行では収まらない高さ)。
        #expect(widths[1] <= pane + 0.5)
        #expect(widths[1] > pane / 2)
        // 同じ1行の枡どうしを比べる: 折り返した本文の枡は、折り返さない短い表の枡より高い。
        let wrapped = try #require(sizes["wrapped"] as? Double)
        #expect(wrapped > firstHeight[0] * 1.5)
        // 長い列が2つある表は配分を置く。「担当」列は1文字ずつ折り返す幅まで潰れない。
        #expect(fitted[2] == 1)
        #expect(first[2] >= 36)
        #expect(widths[2] <= pane + 0.5)
        // 折り返し・配分で収まる表は横スクロールしない。
        #expect(overflow.allSatisfy { $0 <= 0.5 })
        // ペイン幅を狭めると配分をやり直す。
        document.setFrameSize(NSSize(width: 420, height: 600))
        document.layoutSubtreeIfNeeded()
        // 同じ頁で繰り返し測るため、変数を残さないよう即時関数で包む。
        let narrow = """
        (() => {
          const wrap = [...document.querySelectorAll('.table-wrap')][2], table = wrap.querySelector('table');
          return { pane: document.querySelector('main').clientWidth, table: table.getBoundingClientRect().width,
                   first: table.querySelector('td').getBoundingClientRect().width,
                   overflow: wrap.scrollWidth - wrap.clientWidth };
        })()
        """
        try await wait {
            guard let after = try await web.evaluateJavaScript(narrow) as? [String: Any] else { return false }
            return (after["pane"] as? Double ?? 700) < 420 && (after["table"] as? Double ?? 700) < 420
        }
        let after = try #require(try await web.evaluateJavaScript(narrow) as? [String: Any])
        let narrowPane = try #require(after["pane"] as? Double)
        #expect(try #require(after["table"] as? Double) <= narrowPane + 0.5)
        #expect(try #require(after["first"] as? Double) >= 36)
        #expect(try #require(after["overflow"] as? Double) <= 0.5)
    }
    @Test func Vaultの判定とwikilinkのObsidianURI() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let vault = root.appendingPathComponent("仕事 Vault")
        let notes = vault.appendingPathComponent("議事/定例")
        try manager.createDirectory(at: notes, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("外")
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        // `.obsidian` が無いうちはVault外。
        #expect(MinutesVault.name(forFile: notes.appendingPathComponent("a.md")) == nil)
        try manager.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        #expect(MinutesVault.name(forFile: notes.appendingPathComponent("a.md")) == "仕事 Vault")
        #expect(MinutesVault.name(forFile: vault.appendingPathComponent("a.md")) == "仕事 Vault")
        #expect(MinutesVault.name(forFile: outside.appendingPathComponent("a.md")) == nil)
        // 最も近い `.obsidian` を採る。
        let inner = notes.appendingPathComponent(".obsidian")
        try manager.createDirectory(at: inner, withIntermediateDirectories: true)
        #expect(MinutesVault.name(forFile: notes.appendingPathComponent("a.md")) == "定例")
        try manager.removeItem(at: inner)
        // `.obsidian` がファイル・シンボリックリンクのときは採らない。
        let fake = outside.appendingPathComponent(".obsidian")
        try Data().write(to: fake)
        #expect(MinutesVault.name(forFile: outside.appendingPathComponent("a.md")) == nil)
        try manager.removeItem(at: fake)
        try manager.createSymbolicLink(at: fake, withDestinationURL: vault.appendingPathComponent(".obsidian"))
        #expect(MinutesVault.name(forFile: outside.appendingPathComponent("a.md")) == nil)
        // 予約文字はすべて符号化する。`/` を素通しするとVault相対パスが壊れる。
        let url = try #require(MinutesVault.openURL(vault: "仕事 Vault", target: "議事/定例.md"))
        #expect(url.absoluteString == "obsidian://open?vault=%E4%BB%95%E4%BA%8B%20Vault&file=%E8%AD%B0%E4%BA%8B%2F%E5%AE%9A%E4%BE%8B")
        // 末尾の `.md` だけ落とし、見出し・ブロックは残して符号化する。
        #expect(MinutesVault.noteReference("ノート.md") == "ノート")
        #expect(MinutesVault.noteReference("ノート.MD#見出し") == "ノート#見出し")
        #expect(MinutesVault.noteReference("ノート#^abc") == "ノート#^abc")
        #expect(MinutesVault.noteReference("md") == "md")
        #expect(MinutesVault.openURL(vault: "v", target: "a#b")?.absoluteString == "obsidian://open?vault=v&file=a%23b")
        #expect(MinutesVault.openURL(vault: "v", target: "a#^b")?.absoluteString == "obsidian://open?vault=v&file=a%23%5Eb")
        #expect(MinutesVault.openURL(vault: "v", target: "#章") == nil)
        #expect(MinutesVault.openURL(vault: "v", target: "  ") == nil)
        #expect(MinutesVault.openURL(vault: "", target: "a") == nil)
        #expect(MinutesVault.openURL(vault: "v", target: "a\nb") == nil)
    }
    @Test func 外部エディタのパス引用とワークスペース選択() async throws {
        let path = "/tmp/日本語 ' $(touch nope) \u{0060}echo x\u{0060}.md"
        #expect(try MinutesExternalEditor.command(path: path, executable: "/bin/nvim") == "'/bin/nvim' -- '/tmp/日本語 '\\'' $(touch nope) \u{0060}echo x\u{0060}.md'")
        let uri = try #require(URLComponents(url: MinutesExternalEditor.obsidianURL(path: path), resolvingAgainstBaseURL: false))
        #expect(uri.queryItems?.first?.value == path)
        #expect(throws: (any Error).self) { try MinutesExternalEditor.command(path: "/tmp/a\nb.md", executable: "/bin/nvim") }
        actor Recorder {
            var calls: [[String]] = []
            func run(_ args: [String]) -> AIProcessOutput {
                calls.append(args)
                let text: String
                switch args.prefix(2).joined(separator: " ") {
                case "workspace list": text = #"{"result":{"workspaces":[{"workspace_id":"w1","focused":false},{"workspace_id":"w2","focused":true}]}}"#
                case "tab create": text = #"{"result":{"root_pane":{"pane_id":"w2:p3"}}}"#
                default: text = "{}"
                }
                return AIProcessOutput(status: 0, stdout: Data(text.utf8), stderr: Data())
            }
        }
        let recorder = Recorder()
        try await MinutesExternalEditor.launch(path: path, executable: "/bin/nvim", run: { await recorder.run($0) })
        let calls = await recorder.calls
        #expect(calls[1].contains("w2")); #expect(calls[1].contains("/tmp"))
        #expect(calls[2].prefix(3) == ["pane", "run", "w2:p3"])
    }
}
