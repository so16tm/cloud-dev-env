#!/bin/bash
# 生成物: ./build.sh godot で envs/godot.env と modules/ から生成。直接編集しない
# module_* は lib/tail.sh から名前を組み立てて間接的に呼ぶため、到達不能の誤検知を抑止する
# shellcheck disable=SC2317

# 本体の取得元。モジュールが同じリポジトリのファイルを取得するときに使う
RAW_BASE="https://raw.githubusercontent.com/so16tm/cloud-dev-env/main"

# ---- envs/godot.env ----
# Godot 開発用 (GDScript / C# 両対応)。Node.js / Python / Docker は既定イメージのものを使う
MODULES="claude-config base-cli godot"
# 毎回は使わないもの。セッション内で cloud-prepare <名前> で入れる
ON_DEMAND="godot-export-templates"

# ${VAR-default} 形式にして、CI 等から上書きできるようにする
GODOT_VERSION="${GODOT_VERSION-4.7.2}"

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

# ---- modules/godot.sh ----
# Godot の .NET 版を入れる。.NET 版は GDScript と C# の両方を扱えるため、混在・途中切り替えに対応できる。
# 変数: GODOT_VERSION (例 4.7.2)
# .NET SDK は Ubuntu 24.04 の標準フィードにある 8.0 (Godot 4.5 以降の最低要件・新規プロジェクトの既定) と
# 10.0 (LTS) を両方入れ、プロジェクトの TargetFramework がどちらでもビルドできるようにする。
# エクスポートテンプレート (約1GB) は書き出すときしか使わないため cloud-prepare godot-export-templates で入れる
APT_PACKAGES+=(unzip fontconfig libfontconfig1 dotnet-sdk-8.0 dotnet-sdk-10.0)

module_godot() {
  local base="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable"
  local name="Godot_v${GODOT_VERSION}-stable_mono_linux_x86_64"
  mkdir -p /opt/godot &&
  curl -fsSL -o /tmp/godot.zip "$base/$name.zip" &&
  unzip -qo /tmp/godot.zip -d /opt/godot &&
  rm -f /tmp/godot.zip || return 1

  # GodotSharp/ は実行ファイルと同じ場所に必要なため、シンボリックリンクではなく実体を exec する
  cat > /usr/local/bin/godot <<EOF
#!/bin/bash
exec "/opt/godot/$name/Godot_v${GODOT_VERSION}-stable_mono_linux.x86_64" "\$@"
EOF
  chmod +x /usr/local/bin/godot
}

check_godot() {
  local v
  if v=$(godot --headless --version 2> /dev/null); then check_ok "Godot $v"; else check_ng "godot が動かない"; fi
  for v in 8 10; do
    if dotnet --list-sdks 2> /dev/null | grep -q "^$v\."; then check_ok ".NET SDK $v"; else check_ng ".NET SDK $v が無い"; fi
  done
}

# ---- modules/godot-export-templates.sh ----
# ON_DEMAND (cloud-prepare godot-export-templates)。約1GB あり、エクスポートするときしか使わないため setup には入れない
about_godot_export_templates() { echo "Godot .NET 版のエクスポートテンプレート (約1GB)。ゲームを書き出すときに使う"; }

module_godot_export_templates() {
  # 環境の変数を使えないため、入っている Godot から版を求める (例 4.7.2.stable.mono.official.xxx → 4.7.2)
  local v ver base tpl
  v=$(godot --headless --version) || return 1
  ver=${v%%.stable*}
  base="https://github.com/godotengine/godot/releases/download/${ver}-stable"
  tpl="$HOME/.local/share/godot/export_templates/${ver}.stable.mono"
  mkdir -p "$tpl" &&
  curl -fsSL -o /tmp/tpl.tpz "$base/Godot_v${ver}-stable_mono_export_templates.tpz" &&
  rm -rf /tmp/tpl &&
  unzip -qo /tmp/tpl.tpz -d /tmp/tpl &&
  mv /tmp/tpl/templates/* "$tpl/" &&
  rm -rf /tmp/tpl /tmp/tpl.tpz
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

# 毎回は使わないツールは setup に入れず (リポジトリごとの初回の待ち時間を短くするため)、
# セッション内で必要になったときに cloud-prepare <名前> で入れる。ON_DEMAND のモジュールは
# APT_PACKAGES と環境の変数を使わず、module_<name>() だけで完結させる (setup の外で動くため)
{
  echo '#!/bin/bash'
  echo '# 生成物: cloud-dev-env の setup が書き出す。毎回は使わないツールを必要なときに入れる'
  echo "ON_DEMAND=\"${ON_DEMAND:-}\""
  for m in ${ON_DEMAND:-}; do declare -f "about_${m//-/_}" "module_${m//-/_}"; done
  cat <<'EOF'
if [ $# -eq 0 ]; then
  echo "使い方: cloud-prepare <名前>... (時間がかかるものはバックグラウンドで実行する)"
  for m in $ON_DEMAND; do echo "  $m: $("about_${m//-/_}")"; done
  exit 0
fi
rc=0
for m in "$@"; do
  case " $ON_DEMAND " in
    *" $m "*) ;;
    *) echo "$m: 不明 (使えるもの: ${ON_DEMAND:-なし})"; rc=1; continue ;;
  esac
  if "module_${m//-/_}"; then echo "$m: done"; else echo "$m: FAILED"; rc=1; fi
done
exit "$rc"
EOF
} > /usr/local/bin/cloud-prepare
chmod +x /usr/local/bin/cloud-prepare

echo "[setup] end $(date -Is)"
exit 0
