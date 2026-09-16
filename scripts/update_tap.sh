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
# 本文は render_cask.sh が持つ。push せずに手元で audit / install 検証できるようにするため
"$SCRIPT_DIR/render_cask.sh" "$VERSION" "$SHA256" >Casks/kikigaki.rb

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add Casks/kikigaki.rb
git commit -m "kikigaki $VERSION"
git push

echo "Updated homebrew-tap: kikigaki $VERSION ($SHA256)"
