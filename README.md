# cloud-dev-env

Claude Code クラウド環境（claude.ai/code・デスクトップアプリのクラウドセッション）の setup script を管理する。

## 構成

| パス | 役割 |
|---|---|
| `modules/<name>.sh` | ツール単位の部品。`APT_PACKAGES+=(...)` と `module_<name>()` を定義する |
| `envs/<env>.env` | 環境ごとの定義。使うモジュール（`MODULES`）と変数 |
| `lib/head.sh`, `lib/tail.sh` | 共通の前後処理（ログ、apt 一括導入、モジュールの並列実行、常に exit 0） |
| `build.sh` | `envs/<env>.env` から貼り付け用の単一ファイル `dist/<env>.sh` を生成 |
| `dist/<env>.sh` | 生成物。**直接編集しない** |

クラウド環境の setup script は環境設定画面に貼り付ける方式で、リポジトリを参照しない。
そのため生成物 `dist/` もコミットし、CI で `envs/`・`modules/` との一致を検査する。

## 環境一覧

| 環境 | 内容 |
|---|---|
| `godot` | CLI 追加分（fd, bat, shellcheck など）、Godot 4.7.2 |

Unity・Unreal Engine など重いエンジンは、5分のキャッシュ制限に収めるためエンジンごとに環境を分ける。

Node.js・Python（uv, ruff）・Docker・git・gh・jq・ripgrep はクラウドの既定イメージに入っているため扱わない。

## 使い方

```bash
./build.sh            # 全環境を生成
./build.sh godot      # 指定環境のみ
```

1. claude.ai/code で対象のクラウド環境を編集し、**Setup script** に `dist/<env>.sh` を読み込む（Choose file、64KB まで）
2. ネットワークアクセスは既定の **Trusted** でよい
3. 新しいセッションで `/var/log/cloud-setup.log` を確認する

スクリプトを変更して貼り直すと、次のセッションで環境キャッシュが作り直される。

## 新しいツール・環境を足す

- ツール: `modules/<name>.sh` を作り、`module_<name>()`（`-` は `_` に置換）を定義する。apt で入るものは `APT_PACKAGES` に追記する
- 環境: `envs/<env>.env` を作り、`MODULES` と必要な変数を書く。変数は `VAR="${VAR-既定値}"` 形式にする
- `./build.sh` を実行して `dist/` ごとコミットする

## 制約（Anthropic ホストのクラウド環境）

- 非ゼロ終了でセッションが起動しないため、失敗したモジュールはログに残して続行する
- 約5分を超えると環境キャッシュされず、毎回 setup script が走る。重いモジュールは環境を分ける
- Trusted の許可ドメイン外から取得するものは、環境を Custom にして許可ドメインを足すか、Docker Hub など許可済みの経路を使う
- 環境変数・setup script は環境の利用者全員が読めるため、秘密情報は書かない（API キーはネットワークシークレットを使う）
詳細: https://code.claude.com/docs/en/cloud-environments
