#!/usr/bin/env bash
# swift build → KIKIGAKI.app 組み立て → 署名
# 使い方: ./scripts/make-app.sh [debug|release] [version]
set -euo pipefail

CONFIG="${1:-debug}"
VERSION="${2:-0.0.0-development}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/KIKIGAKI.app"
# KIKIGAKI_TRIAL=1: 話者補正の試験用。起動中の通常の .app を消さないよう別の固定パスへ組み、
# 識別子を分けてUserDefaults・マイク許可を本体と分ける。kikigaki:// のリンクも受け付けない。
# 自由なパスを rm -rf する口は作らない。詳細: docs/speaker-compare.md
TRIAL="${KIKIGAKI_TRIAL:-0}"
if [ "$TRIAL" = 1 ]; then
  APP="$ROOT/.build/trial/KIKIGAKI-Trial.app"
  mkdir -p "$ROOT/.build/trial"
fi

swift build --package-path "$ROOT" -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/Kikigaki"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/KIKIGAKI"
cp "$ROOT/.build/$CONFIG/kikigaki-cli" "$APP/Contents/Helpers/kikigaki-cli"
cp "$ROOT/Resources/kikigaki.icns" "$APP/Contents/Resources/"
cp -R "$ROOT/.build/$CONFIG/Kikigaki_Kikigaki.bundle" "$APP/Contents/Resources/"
# AI参加者用のSkillを同梱する。Caskはここへリンクを張るので、利用者が
# リポジトリをcloneしなくても導入でき、更新も.appの差し替えだけで届く。
# 署名前に置くので Contents/Resources のシールに含まれ、--deep --strict も通る。
mkdir -p "$APP/Contents/Resources/skills"
cp -R "$ROOT/skills/kikigaki" "$APP/Contents/Resources/skills/"
# 本体と第三者のライセンスを同梱する。依存の版に追従するよう、SwiftPMのcheckoutから毎回写す。
# 一覧は THIRD-PARTY-NOTICES.md。依存を足したらこことその一覧の両方へ足す。
LICENSES="$APP/Contents/Resources/licenses"
mkdir -p "$LICENSES/FluidAudio" "$LICENSES/TOMLKit"
cp "$ROOT/LICENSE" "$ROOT/THIRD-PARTY-NOTICES.md" "$LICENSES/"
cp "$ROOT/.build/checkouts/FluidAudio/LICENSE" "$LICENSES/FluidAudio/"
cp -R "$ROOT/.build/checkouts/FluidAudio/ThirdPartyLicenses" "$LICENSES/FluidAudio/"
cp "$ROOT/.build/checkouts/TOMLKit/LICENSE" "$LICENSES/TOMLKit/"
sed "s/0\.0\.0-development/$VERSION/" "$ROOT/Resources/Info.plist" >"$APP/Contents/Info.plist"
if [ "$TRIAL" = 1 ]; then
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier com.tadashi-aikawa.kikigaki.trial" \
    -c "Set :CFBundleName KIKIGAKI Trial" \
    -c "Set :CFBundleDisplayName KIKIGAKI Trial" \
    -c "Delete :CFBundleURLTypes" \
    "$APP/Contents/Info.plist"
fi

# 署名: CODESIGN_IDENTITY(デフォルト "kikigaki-dev")の自己署名証明書が Keychain に
# あればそれを使う(署名が固定され、マイクの TCC 許可が更新でも維持される)。
# なければ ad-hoc 署名(ローカル開発用。ビルドのたびにマイク許可を聞かれる)。
# 自己署名のコード署名証明書は「信頼」設定が無くても署名に使えるため、
# find-identity は -v(valid のみ)を付けずに検索する。
# --timestamp=none: 自己署名は Apple のタイムスタンプサーバを使えない
IDENTITY="${CODESIGN_IDENTITY:-kikigaki-dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY" &&
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP/Contents/Helpers/kikigaki-cli" 2>/dev/null &&
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP/Contents/Helpers/kikigaki-cli"
  codesign --force --sign - "$APP"
  echo "Signed with: ad-hoc"
fi

codesign --verify --strict "$APP/Contents/Helpers/kikigaki-cli"
codesign --verify --deep --strict "$APP"

echo "Built: $APP"
echo "Run:   open '$APP'"
