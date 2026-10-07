// @ts-check
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

// トップ (/kikigaki/) は src/pages/index.astro のティザー。
// ドキュメントは src/content/docs/docs/ に置き、/kikigaki/docs/<slug>/ で配信する
export default defineConfig({
  site: "https://tadashi-aikawa.github.io",
  base: "/kikigaki",
  // ドキュメントの入口 /kikigaki/docs/ にはページを置かないので、最初のページへ送る
  redirects: {
    "/docs": "/kikigaki/docs/getting-started/",
  },
  integrations: [
    starlight({
      title: "KIKIGAKI",
      description:
        "会議の発話を聴いて、話者付きでリアルタイムに文字起こしし、Markdownで残すmacOSアプリ",
      defaultLocale: "root",
      locales: {
        root: { label: "日本語", lang: "ja" },
      },
      logo: { src: "./src/assets/kikigaki.png", alt: "KIKIGAKIのロゴ" },
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
      customCss: ["./src/styles/starlight.css"],
      // 404 はティザーと同じ見た目で src/pages/404.astro に置く。Starlight の 404 は
      // ドキュメントのサイドバー付きで出るうえ、上書き用の docs/404.md はslugルートと衝突する
      disable404Route: true,
      sidebar: [
        { label: "はじめに・インストール", slug: "docs/getting-started" },
        { label: "録音と書き起こし", slug: "docs/recording" },
        { label: "オンライン会議で相手の声を取り込む", slug: "docs/online-meetings" },
        { label: "AIを会議に参加させる", slug: "docs/ai-participant" },
        { label: "議事録とボード", slug: "docs/minutes-and-board" },
        { label: "データの行き先", slug: "docs/data" },
        { label: "設定リファレンス", slug: "docs/configuration" },
      ],
    }),
  ],
});
