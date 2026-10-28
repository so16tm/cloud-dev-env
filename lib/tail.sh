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
