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
failed=()
echo "[setup] start $(date -Is) modules: $MODULES"

# cloud-env-check の結果の出力。各モジュールは check_<name>() にセッション内で確かめる項目を書き、これで報告する
check_ok() { echo "OK  $*"; }
# shellcheck disable=SC2034 # NG は cloud-env-check の終了コードに使う
check_ng() { echo "NG  $*"; NG=1; }

# ---- modules/claude-config.sh ----
# クラウドでは手元の ~/.claude/CLAUDE.md が読まれないため、claude/CLAUDE.md をユーザー規約として置く。
# Claude Code は root で動くので /root/.claude/CLAUDE.md になる
module_claude_config() {
  mkdir -p "$HOME/.claude" &&
  curl -fsSL --retry 3 -o "$HOME/.claude/CLAUDE.md" "$RAW_BASE/claude/CLAUDE.md"
}

check_claude_config() {
  if [ -s "$HOME/.claude/CLAUDE.md" ]; then check_ok "ユーザー規約 ~/.claude/CLAUDE.md"; else check_ng "ユーザー規約 ~/.claude/CLAUDE.md が無い"; fi
}

# ---- modules/base-cli.sh ----
# 既定イメージに無い CLI。git, gh, jq, yq, rg, tmux は既定で入っている
APT_PACKAGES+=(fd-find bat shellcheck tree unzip zip htop)

module_base_cli() {
  ln -sf /usr/bin/fdfind /usr/local/bin/fd &&
  ln -sf /usr/bin/batcat /usr/local/bin/bat
}

check_base_cli() {
  local c missing=()
  for c in fd bat shellcheck tree unzip; do command -v "$c" > /dev/null || missing+=("$c"); done
  if [ ${#missing[@]} -eq 0 ]; then check_ok "CLI (fd, bat, shellcheck など)"; else check_ng "CLI が PATH に無い: ${missing[*]}"; fi
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

  # クラウドのセッションのシェルは profile.d も ~/.bashrc の末尾も読まないため、コマンドは PATH 上に置く。
  # JAVA_HOME と ANDROID_HOME は環境設定の Environment variables で渡す (README 参照)。profile.d はログインシェルと CI 用
  ln -sf "$sdk/cmdline-tools/latest/bin/sdkmanager" "$sdk/cmdline-tools/latest/bin/avdmanager" \
    "$sdk/platform-tools/adb" /usr/local/bin/
  cat > /etc/profile.d/android.sh <<EOF
export JAVA_HOME=$java17
export ANDROID_HOME=$sdk
EOF

  local sdkmanager="$sdk/cmdline-tools/latest/bin/sdkmanager"
  # ANDROID_SDK_PACKAGES は空白区切りの一覧をパッケージごとの引数に分けるため引用しない
  # shellcheck disable=SC2086
  yes | JAVA_HOME=$java17 "$sdkmanager" --licenses > /dev/null &&
  JAVA_HOME=$java17 "$sdkmanager" --install $ANDROID_SDK_PACKAGES > /dev/null
}

# JAVA_HOME と ANDROID_HOME は setup で設定できず、環境の Environment variables に手で書くため、設定漏れをここで検出する
check_android_sdk() {
  local c
  if [ "${ANDROID_HOME:-}" = /opt/android-sdk ]; then
    check_ok "ANDROID_HOME=$ANDROID_HOME"
  else
    check_ng "ANDROID_HOME が ${ANDROID_HOME:-未設定}。環境の Environment variables に ANDROID_HOME=/opt/android-sdk を追加する"
  fi
  if "${JAVA_HOME:-/nonexistent}/bin/java" -version 2>&1 | grep -q 'version "17'; then
    check_ok "JAVA_HOME が JDK 17"
  else
    check_ng "JAVA_HOME が JDK 17 でない (${JAVA_HOME:-未設定})。環境の Environment variables に JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 を追加する"
  fi
  for c in sdkmanager adb; do
    if command -v "$c" > /dev/null; then check_ok "$c"; else check_ng "$c が PATH に無い"; fi
  done
}

# ---- lib/tail.sh ----
# apt は並列実行するとロックで衝突するため、先に一括で入れてからモジュールを並列実行する。
if [ ${#APT_PACKAGES[@]} -gt 0 ]; then
  if apt-get update -qq && apt-get install -y -qq --no-install-recommends "${APT_PACKAGES[@]}"; then
    echo "[setup] apt: done"
  else
    echo "[setup] apt: FAILED (続行します)"
    failed+=(apt)
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
    failed+=("$m")
  fi
  cat "/tmp/setup-$m.log"
done

# setup の時点では環境の Environment variables が未設定で、出力もセッションに表示されないため、
# 確認はセッション内で cloud-env-check を実行して行う (クラウド用 CLAUDE.md で最初に実行するよう指示している)
{
  echo '#!/bin/bash'
  echo '# 生成物: cloud-dev-env の setup が書き出す。セッション内の状態を確認し、NG があれば終了コード 1'
  echo "SETUP_FAILED=\"${failed[*]}\""
  declare -f check_ok check_ng
  for m in $MODULES; do declare -f "check_${m//-/_}"; done
  cat <<'EOF'
NG=0
if [ -n "$SETUP_FAILED" ]; then check_ng "setup で失敗: $SETUP_FAILED (/var/log/cloud-setup.log を確認)"; else check_ok "setup"; fi
EOF
  for m in $MODULES; do
    if declare -F "check_${m//-/_}" > /dev/null; then echo "check_${m//-/_}"; fi
  done
  cat <<'EOF'
exit "$NG"
EOF
} > /usr/local/bin/cloud-env-check
chmod +x /usr/local/bin/cloud-env-check

echo "[setup] end $(date -Is)"
exit 0
