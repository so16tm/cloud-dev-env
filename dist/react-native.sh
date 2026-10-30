#!/bin/bash
# 生成物: ./build.sh react-native で envs/react-native.env と modules/ から生成。直接編集しない
# module_* は lib/tail.sh から名前を組み立てて間接的に呼ぶため、到達不能の誤検知を抑止する
# shellcheck disable=SC2317

# 本体の取得元。モジュールが同じリポジトリのファイルを取得するときに使う
RAW_BASE="https://raw.githubusercontent.com/so16tm/cloud-dev-env/main"

# ---- envs/react-native.env ----
# React Native / Expo のスマホアプリ開発用 (Android はビルドまで)。Node.js は既定イメージのものを使う。
# iOS のビルドは macOS が必要なため扱わない (EAS Build のクラウドビルドを使う)
MODULES="claude-config base-cli android-sdk"

# ${VAR-default} 形式にして、CI 等から上書きできるようにする
# ANDROID_NDK 等の標準の変数名は CI ランナーが設定済みで衝突するため、独自の名前にする
ANDROID_CMDLINE_TOOLS_BUILD="${ANDROID_CMDLINE_TOOLS_BUILD-15859902}"
# Expo の blank テンプレートの debug ビルドで Gradle が使ったもの。CI でビルド中に追加取得が起きたら警告が出るので、それに合わせて更新する
ANDROID_SDK_PACKAGES="${ANDROID_SDK_PACKAGES-platform-tools platforms;android-37.0 build-tools;36.0.0 build-tools;37.0.0 ndk;27.1.12297006 cmake;3.22.1}"

# ---- lib/head.sh ----
# 制約: 非ゼロ終了でセッションが起動しない / 約5分を超えると環境キャッシュされない。
LOG=/var/log/cloud-setup.log
exec > >(tee -a "$LOG") 2>&1
export DEBIAN_FRONTEND=noninteractive
# 各モジュールが必要な apt パッケージを追記する。モジュール本体より先にまとめて入れる
APT_PACKAGES=()
echo "[setup] start $(date -Is) modules: $MODULES"

# ---- modules/claude-config.sh ----
# クラウドでは手元の ~/.claude/CLAUDE.md が読まれないため、claude/CLAUDE.md をユーザー規約として置く。
# Claude Code は root で動くので /root/.claude/CLAUDE.md になる
module_claude_config() {
  mkdir -p "$HOME/.claude" &&
  curl -fsSL --retry 3 -o "$HOME/.claude/CLAUDE.md" "$RAW_BASE/claude/CLAUDE.md"
}

# ---- modules/base-cli.sh ----
# 既定イメージに無い CLI。git, gh, jq, yq, rg, tmux は既定で入っている
APT_PACKAGES+=(fd-find bat shellcheck tree unzip zip htop)

module_base_cli() {
  ln -sf /usr/bin/fdfind /usr/local/bin/fd &&
  ln -sf /usr/bin/batcat /usr/local/bin/bat
}

# ---- modules/android-sdk.sh ----
# Android SDK (cmdline-tools と ANDROID_SDK_PACKAGES) と JDK 17。
# React Native・Expo は JDK 17 を推奨しているため、既定イメージの JDK 21 とは別に入れて JAVA_HOME で切り替える。
# ここに無い platform・NDK は、ライセンス同意済みなので Gradle がビルド時に自動で取得する
APT_PACKAGES+=(openjdk-17-jdk-headless unzip)

module_android_sdk() {
  local sdk=/opt/android-sdk java17=/usr/lib/jvm/java-17-openjdk-amd64
  mkdir -p "$sdk/cmdline-tools" &&
  curl -fsSL -o /tmp/cmdline-tools.zip \
    "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_BUILD}_latest.zip" &&
  rm -rf /tmp/cmdline-tools "$sdk/cmdline-tools/latest" &&
  unzip -qo /tmp/cmdline-tools.zip -d /tmp/cmdline-tools &&
  mv /tmp/cmdline-tools/cmdline-tools "$sdk/cmdline-tools/latest" &&
  rm -rf /tmp/cmdline-tools.zip /tmp/cmdline-tools || return 1

  cat > /etc/profile.d/android.sh <<EOF
export JAVA_HOME=$java17
export ANDROID_HOME=$sdk
export PATH="\$JAVA_HOME/bin:\$PATH:$sdk/cmdline-tools/latest/bin:$sdk/platform-tools"
EOF
  # setup script で設定した環境変数はセッションに引き継がれない。Claude Code の Bash は ~/.bashrc を読むため、そこから読み込む
  grep -qs /etc/profile.d/android.sh "$HOME/.bashrc" || echo '. /etc/profile.d/android.sh' >> "$HOME/.bashrc"

  local sdkmanager="$sdk/cmdline-tools/latest/bin/sdkmanager"
  yes | JAVA_HOME=$java17 "$sdkmanager" --licenses > /dev/null &&
  # shellcheck disable=SC2086 # 空白区切りの一覧をパッケージごとの引数に分ける
  JAVA_HOME=$java17 "$sdkmanager" --install $ANDROID_SDK_PACKAGES > /dev/null
}

# ---- lib/tail.sh ----
# apt は並列実行するとロックで衝突するため、先に一括で入れてからモジュールを並列実行する。
if [ ${#APT_PACKAGES[@]} -gt 0 ]; then
  if apt-get update -qq && apt-get install -y -qq --no-install-recommends "${APT_PACKAGES[@]}"; then
    echo "[setup] apt: done"
  else
    echo "[setup] apt: FAILED (続行します)"
  fi
fi

declare -A pids
for m in $MODULES; do
  "module_${m//-/_}" > "/tmp/setup-$m.log" 2>&1 &
  pids[$m]=$!
done

for m in $MODULES; do
  if wait "${pids[$m]}"; then
    echo "[setup] $m: done"
  else
    echo "[setup] $m: FAILED (続行します)"
  fi
  cat "/tmp/setup-$m.log"
done

echo "[setup] end $(date -Is)"
exit 0
