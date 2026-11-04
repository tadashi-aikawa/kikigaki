// @ts-check
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import { satteri } from "@astrojs/markdown-satteri";
import { joinJa } from "./src/mdast/join-ja.mjs";

// ドキュメントの本文の画像を押すと、ブラウザ標準のdialogで元の大きさに拡大する。依存は足さない
const imageZoomScript = `
const zoomable = ".sl-markdown-content img:not(a img)";
function openImageZoom(source) {
  const dialog = document.createElement("dialog");
  dialog.className = "image-zoom";
  const image = document.createElement("img");
  image.src = source.currentSrc || source.src;
  image.alt = source.alt;
  dialog.append(image);
  dialog.addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () => { dialog.remove(); source.focus(); });
  document.body.append(dialog);
  dialog.showModal();
}
document.addEventListener("DOMContentLoaded", () => {
  for (const image of document.querySelectorAll(zoomable)) {
    image.tabIndex = 0;
    image.role = "button";
  }
});
document.addEventListener("click", (event) => {
  const image = event.target.closest?.(zoomable);
  if (image) openImageZoom(image);
});
document.addEventListener("keydown", (event) => {
  if (event.key !== "Enter" && event.key !== " ") return;
  const image = event.target.closest?.(zoomable);
  if (!image) return;
  event.preventDefault();
  openImageZoom(image);
});
`;

// 脚注の番号にマウスを載せるかフォーカスすると、脚注の中身を吹き出しで出す。
// 吹き出しへマウスを移しても閉じないので、中のリンクも押せる。押したときの移動はそのまま残す
const footnotePopupScript = `
let popup = null;
let hideTimer = 0;
let showTimer = 0;
function hideFootnote() {
  clearTimeout(hideTimer);
  clearTimeout(showTimer);
  popup?.remove();
  popup = null;
}
function scheduleHide() {
  clearTimeout(showTimer);
  clearTimeout(hideTimer);
  hideTimer = setTimeout(hideFootnote, 150);
}
// マウスは通りすがりで開かないよう、少し留まってから出す
function scheduleShow(ref) {
  clearTimeout(showTimer);
  clearTimeout(hideTimer);
  showTimer = setTimeout(() => showFootnote(ref), 350);
}
function showFootnote(ref) {
  const note = document.getElementById(decodeURIComponent(ref.hash.slice(1)));
  if (!note) return;
  hideFootnote();
  popup = document.createElement("div");
  popup.className = "footnote-popup";
  popup.role = "tooltip";
  for (const child of note.children) popup.append(child.cloneNode(true));
  popup.querySelectorAll("[data-footnote-backref]").forEach((link) => link.remove());
  popup.addEventListener("pointerenter", () => clearTimeout(hideTimer));
  popup.addEventListener("pointerleave", scheduleHide);
  document.body.append(popup);
  const rect = ref.getBoundingClientRect();
  const gutter = 16;
  const left = Math.min(Math.max(gutter, rect.left - 24), innerWidth - popup.offsetWidth - gutter);
  // 下に収まれば下、収まらなければ上と下の広いほうへ出す
  const below = rect.bottom + 6;
  const above = rect.top - popup.offsetHeight - 6;
  const fitsBelow = below + popup.offsetHeight <= innerHeight - gutter;
  const top = !fitsBelow && rect.top > innerHeight - rect.bottom ? Math.max(gutter, above) : below;
  popup.style.left = left + scrollX + "px";
  popup.style.top = top + scrollY + "px";
  const shown = popup;
  requestAnimationFrame(() => shown.classList.add("is-open"));
}
const footnoteRef = "a[data-footnote-ref]";
document.addEventListener("pointerover", (event) => {
  const ref = event.target.closest?.(footnoteRef);
  if (ref) scheduleShow(ref);
});
document.addEventListener("pointerout", (event) => {
  const ref = event.target.closest?.(footnoteRef);
  // キーボードで番号を選んでいる間は、マウスが離れても閉じない
  if (ref && !ref.matches(":focus-visible")) scheduleHide();
});
// 開くのはキーボードで選んだときだけ。脚注の戻るリンクを押すと番号へフォーカスが移るが、そこでは開かない
document.addEventListener("focusin", (event) => {
  const ref = event.target.closest?.(footnoteRef);
  if (ref?.matches(":focus-visible")) showFootnote(ref);
  else if (!popup?.contains(event.target)) hideFootnote();
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") hideFootnote();
});
// 押して脚注へ移ったら、元の位置に残った吹き出しを閉じる
document.addEventListener("click", (event) => {
  if (event.target.closest?.(footnoteRef)) hideFootnote();
});
`;

// トップ (/kikigaki/) は src/pages/index.astro のティザー。
// ドキュメントは src/content/docs/docs/ に置き、/kikigaki/docs/<slug>/ で配信する
export default defineConfig({
  site: "https://tadashi-aikawa.github.io",
  base: "/kikigaki",
  // Astroの既定の4321はnocturneが使う。devとpreviewを別の固定ポートにして衝突させない
  server: { port: 4330 },
  // 脚注の見出しは目次と狭い画面の現在位置にも出るので、日本語にする
  markdown: {
    processor: satteri({
      mdastPlugins: [joinJa],
      features: {
        gfm: { footnotes: { label: "脚注", backLabel: "本文の脚注{reference}へ戻る" } },
      },
    }),
  },
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
        // Starlightは og:image を出さないので、トップと同じ横長の画像を全ページに付ける。
        // 元は site/ogp/ogp.html。twitter:card は Starlight が summary_large_image で出す
        {
          tag: "meta",
          attrs: {
            property: "og:image",
            content: "https://tadashi-aikawa.github.io/kikigaki/ogp.webp",
          },
        },
        { tag: "meta", attrs: { property: "og:image:width", content: "1200" } },
        { tag: "meta", attrs: { property: "og:image:height", content: "630" } },
        { tag: "script", content: imageZoomScript },
        { tag: "script", content: footnotePopupScript },
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
        { label: "オンライン会議で使う", slug: "docs/online-meetings" },
        { label: "AIエージェントを会議に参加させる", slug: "docs/ai-participant" },
        { label: "議事録とボード", slug: "docs/minutes-and-board" },
        { label: "データの行き先", slug: "docs/data" },
        { label: "設定リファレンス", slug: "docs/configuration" },
      ],
    }),
  ],
});
