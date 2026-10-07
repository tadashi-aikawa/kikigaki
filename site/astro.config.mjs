// @ts-check
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

// トップ (/kikigaki/) は src/pages/index.astro のティザー。
// ドキュメントは src/content/docs/docs/ に置き、/kikigaki/docs/<slug>/ で配信する
export default defineConfig({
  site: "https://tadashi-aikawa.github.io",
  base: "/kikigaki",
  // Astroの既定の4321はnocturneが使う。devとpreviewを別の固定ポートにして衝突させない
  server: { port: 4330 },
  // ドキュメントの入口 /kikigaki/docs/ にはページを置かないので、最初のページへ送る
  redirects: {
    "/docs": "/kikigaki/docs/getting-started/",
  },
  integrations: [
    starlight({
      title: "KIKIGAKI 聞書",
      description:
        "会議の発話を聴いて、話者付きでリアルタイムに文字起こしし、Markdownで残すmacOSアプリ",
      defaultLocale: "root",
      locales: {
        root: { label: "日本語", lang: "ja" },
      },
      // ロゴと題はトップのヘッダーと揃えるため SiteTitle を差し替えて描く
      components: { SiteTitle: "./src/components/SiteTitle.astro" },
      favicon: "/favicon.png",
      head: [
        {
          tag: "link",
          attrs: { rel: "apple-touch-icon", href: "/kikigaki/apple-touch-icon.png" },
        },
      ],
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/tadashi-aikawa/kikigaki",
        },
      ],
      customCss: ["./src/styles/washi.css", "./src/styles/starlight.css"],
      // コードブロックは窓枠の飾りを外し、生成りの濃い地を罫で囲む。
      // 色はテーマごとに starlight.css の変数で切り替える。ec.config.mjs に関数で書くと、
      // ページが参照するCSSと書き出すCSSのハッシュが食い違ってスタイルが外れた
      expressiveCode: {
        defaultProps: { frame: "code" },
        styleOverrides: {
          borderRadius: "4px",
          borderColor: "var(--washi-code-rule)",
          codeBackground: "var(--washi-code-bg)",
          codeFontFamily: "var(--washi-font-mono)",
          uiFontFamily: "var(--washi-font)",
          // 枠の地はStarlightがテーマごとに上書きするので、starlight.css で枠の変数を差し替える
          frames: {
            frameBoxShadowCssValue: "none",
            terminalTitlebarDotsOpacity: "0",
          },
        },
      },
      // 404 はティザーと同じ見た目で src/pages/404.astro に置く。Starlight の 404 は
      // ドキュメントのサイドバー付きで出るうえ、上書き用の docs/404.md はslugルートと衝突する
      disable404Route: true,
      sidebar: [
        { label: "はじめに・インストール", slug: "docs/getting-started" },
        { label: "録音と書き起こし", slug: "docs/recording" },
        { label: "オンライン会議で相手の声を取り込む", slug: "docs/online-meetings" },
        { label: "AIエージェントを会議に参加させる", slug: "docs/ai-participant" },
        { label: "議事録とボード", slug: "docs/minutes-and-board" },
        { label: "データの行き先", slug: "docs/data" },
        { label: "設定リファレンス", slug: "docs/configuration" },
      ],
    }),
  ],
});
