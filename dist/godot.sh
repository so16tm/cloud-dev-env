#!/bin/bash
# 生成物: ./build.sh godot で envs/godot.env と modules/ から生成。直接編集しない
# module_* は lib/tail.sh から名前を組み立てて間接的に呼ぶため、到達不能の誤検知を抑止する
# shellcheck disable=SC2317

# 本体の取得元。モジュールが同じリポジトリのファイルを取得するときに使う
RAW_BASE="https://raw.githubusercontent.com/so16tm/cloud-dev-env/main"

# ---- envs/godot.env ----
# Godot 開発用 (GDScript / C# 両対応)。Node.js / Python / Docker は既定イメージのものを使う
MODULES="claude-config base-cli godot"

# ${VAR-default} 形式にして、CI 等から上書きできるようにする
GODOT_VERSION="${GODOT_VERSION-4.7.2}"
GODOT_EXPORT_TEMPLATES="${GODOT_EXPORT_TEMPLATES-0}"

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

# ---- modules/godot.sh ----
# Godot の .NET 版を入れる。.NET 版は GDScript と C# の両方を扱えるため、混在・途中切り替えに対応できる。
# 変数: GODOT_VERSION (例 4.7.2), GODOT_EXPORT_TEMPLATES (1 で約1GBの .NET 版テンプレートも入れる)
# .NET SDK は Ubuntu 24.04 の標準フィードにある 8.0 (Godot 4.5 以降の最低要件・新規プロジェクトの既定) と
# 10.0 (LTS) を両方入れ、プロジェクトの TargetFramework がどちらでもビルドできるようにする。
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

  if [ "${GODOT_EXPORT_TEMPLATES:-0}" = "1" ]; then
    local tpl="$HOME/.local/share/godot/export_templates/${GODOT_VERSION}.stable.mono"
    mkdir -p "$tpl" &&
    curl -fsSL -o /tmp/tpl.tpz "$base/Godot_v${GODOT_VERSION}-stable_mono_export_templates.tpz" &&
    unzip -qo /tmp/tpl.tpz -d /tmp/tpl &&
    mv /tmp/tpl/templates/* "$tpl/" &&
    rm -rf /tmp/tpl /tmp/tpl.tpz
  fi
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
