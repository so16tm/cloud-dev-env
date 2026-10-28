# ---- modules/base-cli.sh ----
# 既定イメージに無い CLI。git, gh, jq, yq, rg, tmux は既定で入っている
APT_PACKAGES+=(fd-find bat shellcheck tree unzip zip htop)

module_base_cli() {
  ln -sf /usr/bin/fdfind /usr/local/bin/fd &&
  ln -sf /usr/bin/batcat /usr/local/bin/bat
}
