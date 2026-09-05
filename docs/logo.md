# ロゴの管理

採用デザインは「会話フクロウ」。朱色の角丸タイルに、2つの吹き出しで作った生成りの顔と金のくちばしを合わせる。

## 元画像と配布用アイコン

- `Resources/kikigaki.png`: 1024×1024の透過PNG。READMEと派生画像の共通の元画像。
- `Resources/kikigaki.icns`: 16・32・128・256・512ポイントの各1倍・2倍画像を格納したアプリアイコン。

`bash scripts/make-icon.sh` でPNGからICNSを再生成する。通常のアプリビルドはコミット済みのICNSを同梱するため、画像生成ツールは不要。

アプリは [AppleのCFBundleIconFile](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconfile) でICNSを参照する。

メニューバーの待機中アイコンも同じICNSを18ポイントで表示する。録音中・一時停止中・準備中・保存中は状態を示すシンボルに切り替える。画像を同梱しない `swift run` では待機中も波形シンボルを使う。

## owleryとparliament

owleryの `shared/images/projects/KIKIGAKI.webp` は元画像から256×256で書き出す。

```bash
cwebp -quiet -lossless -resize 256 256 Resources/kikigaki.png \
  -o /Users/tadashi-aikawa/work/owlery/shared/images/projects/KIKIGAKI.webp
```

owleryのプロジェクトノートはこの画像を埋め込む。parliamentは同じ画像をプロジェクト名から自動検出する。新規セッションのKIKIGAKI項目もこのパスを参照する。

## 制作

内蔵 `image_gen` で採用案Cを参照画像として背景を除去し、`sips` で1024×1024へ変換した。再生成のたびに外観が変わる可能性があるため、通常のビルドでは画像生成を行わない。

使用した背景除去プロンプト:

> Remove background from this approved red owl app icon. Return RGBA PNG with TRUE transparent alpha pixels outside the red rounded square. The background must be transparent using the actual alpha channel, NOT painted checkerboard squares, NOT white, NOT gray. DO NOT DRAW A CHECKERBOARD. Preserve the approved red rounded square, owl eyes, ivory speech bubbles and gold beak exactly. Only the area outside the red rounded square is to be transparent. This is production asset background extraction, not a preview of transparency.
