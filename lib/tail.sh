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
