# cloud-dev-env

Claude Code クラウド環境（claude.ai/code・デスクトップアプリのクラウドセッション）の setup script を管理する。
1つのクラウド環境を複数のプロジェクトで共通に使う前提で、ツールはすべてシステム側に入れ、リポジトリ固有の処理は持たない。

## 初回設定（環境ごとに1回だけ）

claude.ai/code で新しいクラウド環境を作り（または既存の環境を編集し）、次の2つを設定する。

1. **Setup script**: `dist/<env>.setup.sh` の中身を貼る。この起動スクリプトがセッション開始時に本体 `dist/<env>.sh` をこのリポジトリから取得して実行する
2. **Network access**: **Custom** にし、**Allowed domains** に `dist/<env>.domains.txt` の中身を貼り、**Also include default list of common package managers** にチェックを入れる（Trusted の既定リストも残すため）

setup は確認用の `cloud-env-check` も入れる。クラウド用の CLAUDE.md で、セッションの最初の依頼の前に Claude がこれを実行し、`NG`（setup の失敗、Environment variables の設定漏れなど）があれば対処と一緒に報告するよう指示している。setup の時点では Environment variables が未設定で、出力もセッションに表示されないため、確認はセッション内で行う。詳しいログは `/var/log/cloud-setup.log`。

## 更新の反映

- ツールの追加・変更は、このリポジトリの main に push するだけでよい。貼り直しは不要
- 反映されるのは環境キャッシュが作り直されたとき（約7日ごと）。すぐ反映したいときは、環境の Setup script の `# rev: 1` の数字を上げて保存し直す
- 許可ドメインを変えたときだけは、`dist/<env>.domains.txt` を貼り直す（claude.ai に設定用の API が無いため）

## 環境一覧

setup に入れるか、必要なときに入れるかは、使う頻度と所要時間で決める。setup に入れたものは環境キャッシュに載り、待つのはリポジトリごとの初回（約7日ごと）だけで、使わないタスクの起動も遅くならない。必要なときに入れたものはそのセッションにだけ残り、使うセッションのたびに待つ。このため、使う頻度が低く大きいものだけを必要なときに入れる。setup 全体は約5分に収める（超えるとキャッシュされない）。

| 環境 | setup で入れる | 必要なときに入れる |
|---|---|---|
| `godot` | CLI 追加分（fd, bat, shellcheck など）、Godot 4.7.2 .NET 版（GDScript・C# 両対応）、.NET SDK 8.0 / 10.0 | `cloud-prepare godot-export-templates`（約1GB。書き出すときだけ使う） |
| `react-native` | CLI 追加分、JDK 17、Android SDK（platform 37.0・build-tools 36/37・NDK 27.1・CMake 3.22.1 など） | なし（一覧に無い SDK パッケージは、ビルド時に Gradle が自動で取得する） |

`cloud-prepare` を引数なしで実行すると、準備できるものと用途が表示される。クラウド用の CLAUDE.md で、必要になったら Claude がこれを使うよう指示している。

`react-native` 環境では、Android SDK を `/opt/android-sdk` に入れ、`sdkmanager`・`avdmanager`・`adb` を `/usr/local/bin` に置く。セッションのシェルは setup で書いた設定ファイルを読まないため、環境の **Environment variables** に次の2行を設定する（Gradle が JDK 17 と SDK を使うために必要。`java -version` は既定イメージの 21 のままになる）。

```
ANDROID_HOME=/opt/android-sdk
JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
```

iOS のビルド（macOS が必要）とエミュレーターは扱わない。iOS は EAS Build（`npx eas-cli build`）を使う。EAS に必要な `EXPO_TOKEN` は環境変数に設定する（環境の利用者全員が読める点に注意）。CI で Expo の blank テンプレートから debug APK をビルドして確認し、ビルド中に SDK パッケージの追加取得が起きたら警告を出す。

`godot` 環境は GDScript のみ・C# のみ・混在のどのプロジェクトでも使える。CI で `tests/godot-mixed`（GDScript から C# のクラスを呼ぶ）を実行して確認している。

Godot のバージョンが違うプロジェクトや、Unity・Unreal Engine など重いエンジンは、環境を分ける（5分のキャッシュ制限に収めるため）。

全環境に `claude-config` モジュールを入れ、`claude/CLAUDE.md` を `/root/.claude/CLAUDE.md` に置く。クラウドでは手元の `~/.claude/CLAUDE.md` が読まれないため、これがユーザー規約になる。

Node.js・Python（uv, ruff）・Docker・git・gh・jq・ripgrep はクラウドの既定イメージに入っているため扱わない。
`dotnet restore`・`npm install` などプロジェクト固有の準備は、各リポジトリの SessionStart hook に書くかセッション内で実行する。

## ユーザー規約の更新

正本は手元の `~/.codex/AGENTS.md` と `~/.claude/rules/*.md`。変更したら `./sync-claude.sh` を実行し、`claude/CLAUDE.md` をコミットして push する。

- `@` で始まる import 行は除く（手元のパスを指し、クラウドで解決できないため）
- 手元では settings の `language` と hook で指定している日本語の指示を、代わりに書き足す
- `paths` の frontmatter を持つルールは混ぜない
- public リポジトリなので、コミット前に差分で秘密情報・個人のパスが無いか確認する
- 反映は他のツールと同じく環境キャッシュの作り直し時（すぐ反映するなら `rev` を上げる）

## 構成

| パス | 役割 |
|---|---|
| `modules/<name>.sh` | ツール単位の部品。`APT_PACKAGES+=(...)` と `module_<name>()` を定義する |
| `envs/<env>.env` | 環境ごとの定義。setup で入れるモジュール（`MODULES`）、必要なときに入れるモジュール（`ON_DEMAND`）と変数 |
| `envs/<env>.domains` | 環境ごとに追加で許可するドメイン（任意） |
| `domains/common.txt` | 全環境共通で許可するドメイン（Trusted の既定リストに無いもの） |
| `lib/head.sh`, `lib/tail.sh` | 本体の共通前後処理（ログ、apt 一括導入、モジュールの並列実行） |
| `build.sh` | `dist/` を生成する |
| `sync-claude.sh` | 手元のユーザー規約から `claude/CLAUDE.md` を生成する |
| `claude/CLAUDE.md` | クラウドに配るユーザー規約（生成物） |
| `dist/<env>.sh` | 本体。起動スクリプトが取得して実行する |
| `dist/<env>.setup.sh` | 環境の Setup script に貼る起動スクリプト |
| `dist/<env>.domains.txt` | 環境の Allowed domains に貼る一覧 |

`dist/` は生成物なので直接編集しない。CI で元ファイルとの一致を検査する。

ユーザー規約は「GitHub Actions をテストに使わない」としているが、このリポジトリは public（標準ランナーは無料）のため例外として CI で smoke テストを行う。

## 新しいツール・環境を足す

- ツール: `modules/<name>.sh` を作り、`module_<name>()`（`-` は `_` に置換）を定義する。apt で入るものは `APT_PACKAGES` に追記する。セッション内で確かめる項目があれば `check_<name>()` を定義し、`check_ok` / `check_ng` で報告する（`cloud-env-check` に組み込まれる）
- 毎回は使わないツール: `ON_DEMAND` に入れ、`about_<name>()`（用途の1行説明）と `module_<name>()` を定義する。setup の外で動くため、`APT_PACKAGES` と環境の変数は使わず、apt もモジュールの中で実行する
- 環境: `envs/<env>.env` を作り、`MODULES`・`ON_DEMAND` と必要な変数を書く。変数は `VAR="${VAR-既定値}"` 形式にする
- ドメイン: 全環境で使うものは `domains/common.txt`、特定環境だけなら `envs/<env>.domains` に1行1ドメインで書く（`#` 以降はコメント）
- `./build.sh` を実行して `dist/` ごとコミットし、main に push する

## 制約（Anthropic ホストのクラウド環境）

- setup script が非ゼロ終了するとセッションが起動しない。本体は失敗したモジュールをログに残して続行するが、起動スクリプトは本体の取得に失敗したら非ゼロで終了する（ツールの無い状態が環境キャッシュに残るのを防ぐため）
- 約5分を超えると環境キャッシュされず、毎回 setup script が走る
- 環境キャッシュは環境とリポジトリの組み合わせごとに作られる（実機で確認）。リポジトリごとに初回のセッションと、キャッシュの作り直し（rev の変更・約7日の期限）の後の初回で setup の時間だけ待つ。setup の時点でセッションのリポジトリは clone 済みで、private リポジトリ内のスクリプトも setup から実行できるため
- 共通のツールはリポジトリに依存させず、このリポジトリ（public）から取得する。リポジトリ固有の準備は、各リポジトリの SessionStart hook かリポジトリ内のスクリプトで行う
- 起動スクリプトは main の最新を root で実行する。このリポジトリへの push 権限を守る（GitHub の2段階認証）
- 環境変数・setup script は環境の利用者全員が読めるため、秘密情報は書かない（API キーはネットワークシークレットを使う）

詳細: https://code.claude.com/docs/en/cloud-environments
