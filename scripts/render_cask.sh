#!/usr/bin/env bash
# Cask を標準出力へ書き出す。tap へ push せずに brew audit --cask などで検証できる。
# 使い方: ./scripts/render_cask.sh <version> <sha256>
set -euo pipefail

VERSION="${1:-}"
SHA256="${2:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ || ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Usage: scripts/render_cask.sh <version> <sha256>" >&2
  exit 1
fi

# GitHub のリポジトリは kikigaku から kikigaki へ改名済み。旧名はリダイレクトで通るが、新名で書く
cat <<EOF
cask "kikigaki" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/tadashi-aikawa/kikigaki/releases/download/v#{version}/KIKIGAKI-#{version}.zip"
  name "KIKIGAKI"
  desc "会議の発話を話者付きでリアルタイムに文字起こしする macOS 用ツール"
  homepage "https://github.com/tadashi-aikawa/kikigaki"

  # SpeechTranscriber が macOS 26 以降のため
  depends_on macos: :tahoe

  app "KIKIGAKI.app"

  # AI参加者用 Skill のリンク先。Claude Code は ~/.claude/skills、Codex は
  # ~/.codex/skills を読む。どちらも起動引数でセッション限定の置き場を指定できないため、
  # KIKIGAKI からは渡せず、この共通の置き場へ導入する。
  # 実体は .app の中を指すので、brew upgrade でリンクを張り直さなくても更新が届く。
  skill_homes = ["~/.claude/skills/kikigaki", "~/.codex/skills/kikigaki"].freeze

  # 自己署名(未公証)のため quarantine を外さないと Gatekeeper にブロックされる。
  # 公式 tap では禁止されている手法だが、自前 tap なので postflight_steps で除去する。
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/KIKIGAKI.app"]

    skill_source = "{{appdir}}/KIKIGAKI.app/Contents/Resources/skills/kikigaki"
    skill_homes.each do |home|
      # 参照先が .app 内の同梱 Skill なら自分が張ったリンクなので、掃除して張り直す。
      remove home, symlink_target_contains: "KIKIGAKI.app/Contents/Resources/skills/kikigaki"

      # 利用者が clone したリポジトリへ張ったリンクや自前の Skill がある場合は触らない。
      # 黙って奪うと、編集していた側の変更が以後まったく効かなくなるため。
      if_path_exists home do
        warn "#{home} が既にあるため、同梱 Skill へのリンクは張りませんでした。" \\
             "同梱版を使う場合は削除してから brew reinstall --cask kikigaki を実行してください。"
      end
      unless_path_exists home do
        # remove_on_uninstall はアンインストール時、自分が張ったリンク
        # (readlink が一致するもの)だけ外す。利用者が置いた実体や別のリンクは残す。
        symlink skill_source, home, remove_on_uninstall: true
      end
    end
  end

  caveats <<~EOS
    KIKIGAKI は自己署名(未公証)アプリです。
    初回起動がブロックされた場合は以下で許可してください:
    システム設定 → プライバシーとセキュリティ → 「このまま開く」

    会議へ AI を参加させる Skill は次の場所へリンクしました。
    既に同名のファイルがある場合は、上書きせず警告だけを出しています。
      ~/.claude/skills/kikigaki (Claude Code)
      ~/.codex/skills/kikigaki (Codex)
  EOS
end
EOF
