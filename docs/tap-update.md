# Homebrew tapの更新

`release.yml`が`TAP_GITHUB_TOKEN`をsemantic-releaseへ渡し、`release.config.cjs`の`successCmd`が`scripts/update_tap.sh <version>`を呼ぶ。更新には`dist/KIKIGAKI-<version>.zip`を使う。

- 認証は`GIT_ASKPASS`で行う。
    - 受け渡し: usernameは`x-access-token`、passwordは環境変数`TAP_GITHUB_TOKEN`からGitの要求時に返す。
    - 制限: トークンをclone URL・remote URL・引数・一時スクリプトの本文へ埋め込まない。credential helperを空にし、端末の対話入力を無効にする。
    - 詳細: [Git公式の認証仕様](https://git-scm.com/docs/gitcredentials)
- `mktemp -d`の領域を`EXIT`のtrapで削除する。
    - 対象: 成功、clone・commit・pushの失敗、INT・TERMによる終了。
    - 限界: SIGKILLやマシン停止ではtrapを実行できない。一時スクリプトにはトークンそのものを保存しない。
- テストはGitを差し替え、`TAP_GITHUB_TOKEN=dummy`で成功・clone失敗・push失敗の後始末を確認する。
    - 実通信: ローカルではdummyと接続できないproxyを使い、cloneの失敗後に一時領域が空になることを確認する。実トークンや実tapへのpushは使わない。
