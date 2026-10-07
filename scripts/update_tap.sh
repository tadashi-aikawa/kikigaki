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

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kikigaki-tap.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
TAP_DIR="$WORK_DIR/tap"

# トークン自体をURL・引数・ファイルへ書かず、Gitの認証要求にだけ環境変数から返す。
# CIでも対話入力や利用者のcredential helperへ依存しない。
cat > "$WORK_DIR/askpass" <<'ASKPASS'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *Password*) printf '%s\n' "$TAP_GITHUB_TOKEN" ;;
  *) exit 1 ;;
esac
ASKPASS
chmod 700 "$WORK_DIR/askpass"
export GIT_ASKPASS="$WORK_DIR/askpass"
export GIT_TERMINAL_PROMPT=0
export LC_ALL=C

SHA256=$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)

git -c credential.helper= clone "https://github.com/tadashi-aikawa/homebrew-tap.git" "$TAP_DIR"
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
git -c credential.helper= push

echo "Updated homebrew-tap: kikigaki $VERSION ($SHA256)"
