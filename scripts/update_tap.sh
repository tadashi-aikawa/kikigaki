#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-}"
ARCHIVE="$ROOT_DIR/dist/KIKIGAKI-$VERSION.zip"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Usage: scripts/update_tap.sh <version>" >&2
  exit 1
fi

if [[ -z "${TAP_GITHUB_TOKEN:-}" ]]; then
  echo "TAP_GITHUB_TOKEN is required." >&2
  exit 1
fi

SHA256=$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)
TAP_DIR="$(mktemp -d)/tap"

git clone "https://x-access-token:${TAP_GITHUB_TOKEN}@github.com/tadashi-aikawa/homebrew-tap.git" "$TAP_DIR"
cd "$TAP_DIR"
mkdir -p Casks

# Cask を毎回丸ごと書き出す。初回リリースで Cask が無くても作成でき、
# 文面の変更もこのリポジトリ側の修正だけで tap へ反映される。
# GitHub のリポジトリ名は kikigaku(アプリ名・Cask 名の kikigaki と異なる)
cat > Casks/kikigaki.rb <<EOF
cask "kikigaki" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/tadashi-aikawa/kikigaku/releases/download/v#{version}/KIKIGAKI-#{version}.zip"
  name "KIKIGAKI"
  desc "会議の発話を話者付きでリアルタイムに文字起こしする macOS 用ツール"
  homepage "https://github.com/tadashi-aikawa/kikigaku"

  # SpeechTranscriber が macOS 26 以降のため
  depends_on macos: :tahoe

  app "KIKIGAKI.app"

  # 自己署名(未公証)のため quarantine を外さないと Gatekeeper にブロックされる。
  # 公式 tap では禁止されている手法だが、自前 tap なので postflight で除去する。
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/KIKIGAKI.app"],
                   sudo: false
  end

  caveats <<~EOS
    KIKIGAKI は自己署名(未公証)アプリです。
    初回起動がブロックされた場合は以下で許可してください:
    システム設定 → プライバシーとセキュリティ → 「このまま開く」
  EOS
end
EOF

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add Casks/kikigaki.rb
git commit -m "kikigaki $VERSION"
git push

echo "Updated homebrew-tap: kikigaki $VERSION ($SHA256)"
