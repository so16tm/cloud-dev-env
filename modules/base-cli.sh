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
