#!/bin/bash
# 生成物: ./build.sh default で envs/default.env と modules/ から生成。直接編集しない
# module_* は lib/tail.sh から名前を組み立てて間接的に呼ぶため、到達不能の誤検知を抑止する
# shellcheck disable=SC2317

# 本体の取得元。モジュールが同じリポジトリのファイルを取得するときに使う (CI では検証中のコミットを指すよう上書きする)
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/so16tm/cloud-dev-env/main}"

# ---- envs/default.env ----
# 特定の開発用ツールを入れない汎用の環境 (claude.ai の Default 環境に貼る)。ユーザー規約と CLI 追加分だけを入れる。
# Network access は Trusted のままでよい (取得先の raw.githubusercontent.com と Ubuntu の apt は既定リストに含まれる)
MODULES="claude-config base-cli"

# ---- lib/head.sh ----
# 制約: 非ゼロ終了でセッションが起動しない / 約5分を超えると環境キャッシュされない。
LOG=/var/log/cloud-setup.log
exec > >(tee -a "$LOG") 2>&1
export DEBIAN_FRONTEND=noninteractive
# 各モジュールが必要な apt パッケージを追記する。モジュール本体より先にまとめて入れる
APT_PACKAGES=()
failed=()
echo "[setup] start $(date -Is) modules: $MODULES"
# setup が途中で打ち切られても NG と分かるよう、最後に本物で置き換える仮の確認コマンドを先に置く
printf '#!/bin/bash\necho "NG  setup が最後まで終わっていない (/var/log/cloud-setup*.log を確認)"\nexit 1\n' > /usr/local/bin/cloud-env-check
chmod +x /usr/local/bin/cloud-env-check

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
# モジュールのログは /var/log に直接書く (setup が途中で打ち切られても、どこまで進んだか残るように)
for m in $MODULES; do
  "module_${m//-/_}" > "/var/log/cloud-setup-$m.log" 2>&1 &
  pids[$m]=$!
done

for m in $MODULES; do
  if wait "${pids[$m]}"; then
    echo "[setup] $m: done $(date -Is)"
  else
    echo "[setup] $m: FAILED $(date -Is) (続行します)"
    failed+=("$m")
  fi
  cat "/var/log/cloud-setup-$m.log"
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
  # 取得元はこのリポジトリの main。CI では検証中のコミットを指すよう上書きする
  echo "RAW_BASE=\"\${RAW_BASE:-$RAW_BASE}\""
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
