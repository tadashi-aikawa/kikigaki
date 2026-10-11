import AppKit
import WebKit
import Testing
@testable import Kikigaki

@Suite(.serialized) @MainActor struct MermaidScaleTests {
    private let fixtures: [(String, String)] = [
        ("flowchart", """
        flowchart TB
          classDef now fill:#efe6f8,stroke:#9b72c6,stroke-width:3px
          classDef done fill:#e3f4e1,stroke:#2e8b57
          classDef hold fill:#fff1d6,stroke:#e67e22,stroke-width:2px,stroke-dasharray:5 3
          T1["T1 来期の料金体系"]
          T2["✅ T2 価格改定は10月から"]
          T3["T3 値上げ幅"]
          T4["🟠 T4 海外の扱い"]
          T1 --> T2
          T1 --> T3
          T3 --> T4
          class T2 done
          class T4 hold
          class T3 now
        """),
        ("mindmap", """
        mindmap
          root((来期の料金体系))
            国内の価格改定
              10月から変更
              値上げ幅を決める
            海外の扱い
              為替の影響を確認
              担当者と期限を決める
        """),
        ("timeline", """
        timeline
          title 価格改定までの流れ
          10月12日 : 料金改定の条件を確認する : 国内と海外の担当者を決める
          10月20日 : 値上げ幅の案を比較する
          11月1日 : お客様へ変更内容を案内する
        """),
        ("sequence", """
        sequenceDiagram
          participant A as タダシ
          participant B as 田中
          A->>B: 来期の価格改定について確認
          B-->>A: 国内は10月から変更します
          Note over A,B: 海外の扱いは次回確認する
        """)
    ]

    @Test func Mermaidは倍率変更と拡大中の再描画で文字位置と枠を保つ() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let document = MinutesWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
        let window = NSWindow(contentRect: document.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let output = ProcessInfo.processInfo.environment["KIKIGAKI_MERMAID_CAPTURE"].map { URL(fileURLWithPath: $0) }
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try ("# 会議の議事録\n\n## ボード\n\n" + fixtures.map {
                "### \($0.0)\n\n```mermaid\n\($0.1)\n```\n"
            }.joined(separator: "\n")).write(to: output.appendingPathComponent("minutes.md"), atomically: true, encoding: .utf8)
        }
        let web = document.webView
        var measurements: [[String: Any]] = []
        var baseline: [String: Any]?
        func wait(_ condition: () async throws -> Bool) async throws {
            for _ in 0..<500 {
                if try await condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CocoaError(.coderReadCorrupt)
        }
        func record(_ name: String, _ percent: Int, _ mode: String) async throws {
            try await Task.sleep(for: .milliseconds(150))
            let metrics = try #require(try await web.evaluateJavaScript("""
            [...document.querySelectorAll('.diagram svg')].map(svg => ({
              viewBox: svg.getAttribute('viewBox'), maxWidth: svg.style.maxWidth,
              positions: [...svg.querySelectorAll('text,tspan')].map(t => ({tag:t.tagName, text:t.textContent,
                x:t.getAttribute('x'),y:t.getAttribute('y'),dx:t.getAttribute('dx'),dy:t.getAttribute('dy'),
                font:getComputedStyle(t).fontSize, bbox:[t.getBBox().x,t.getBBox().y,t.getBBox().width,t.getBBox().height]})),
              texts: [...svg.querySelectorAll('text')].map(t => ({text:t.textContent,
                bbox:[t.getBBox().x,t.getBBox().y,t.getBBox().width,t.getBBox().height],
                font:getComputedStyle(t).fontSize, transform:t.parentElement.getAttribute('transform')})),
              rects: [...svg.querySelectorAll('rect')].map(r => [r.getAttribute('width'),r.getAttribute('height')])
            }))
            """) as? [[String: Any]])
            #expect(metrics.count == 1)
            let current = try #require(metrics.first)
            if let baseline {
                let viewBox = try #require(current["viewBox"] as? String).split(separator: " ").compactMap { Double($0) }
                let original = try #require(baseline["viewBox"] as? String).split(separator: " ").compactMap { Double($0) }
                #expect(viewBox.count == 4 && original.count == 4)
                #expect(zip(viewBox, original).allSatisfy { abs($0 - $1) < 0.05 }, "\(name) \(percent)% \(mode): 図の枠")
                let positions = try #require(current["positions"] as? [[String: Any]])
                let originalPositions = try #require(baseline["positions"] as? [[String: Any]])
                #expect(positions.count == originalPositions.count)
                for (position, originalPosition) in zip(positions, originalPositions) {
                    let box = try #require(position["bbox"] as? [Double])
                    let originalBox = try #require(originalPosition["bbox"] as? [Double])
                    // 横幅の微小な差はフォントの丸め。行の上端と高さで行間の崩れを検出する。
                    #expect(abs(box[1] - originalBox[1]) < 0.1 && abs(box[3] - originalBox[3]) < 0.1,
                        "\(name) \(percent)% \(mode): \(position["text"] ?? "")")
                }
            } else { baseline = current }
            measurements.append(["diagram": name, "percent": percent, "mode": mode, "metrics": metrics])
            if let output {
                let image = try await web.takeSnapshot(configuration: nil)
                let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: output.appendingPathComponent("\(name)-\(percent)-\(mode).png"))
            }
        }
        for (name, definition) in fixtures {
            baseline = nil
            let source = "## ボード\n\n### \(name)\n\n```mermaid\n\(definition)\n```\n"
            document.setTextScale(1)
            document.render(source, reset: true)
            try await wait { document.renderedText.contains(name) }
            for percent in [100, 125, 150, 200] {
                document.setTextScale(CGFloat(percent) / 100)
                try await record(name, percent, "existing")
            }
            for percent in [100, 125, 150, 200] {
                document.setTextScale(CGFloat(percent) / 100)
                // 同じ本文でも完了を識別するため、JSの描画Promiseを待つ。
                _ = try await web.callAsyncJavaScript("return await window.minutes.render(source, 'test', true, 999, null, true)",
                    arguments: ["source": source], in: nil, in: .page)
                try await record(name, percent, "redrawn")
            }
            document.setTextScale(1)
            try await record(name, 100, "returned")
        }
        if let output {
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(
                to: output.appendingPathComponent("measurements.json"))
        }
    }
}
