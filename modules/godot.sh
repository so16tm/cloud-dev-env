# ---- modules/godot.sh ----
# 変数: GODOT_VERSION (例 4.7.2), GODOT_EXPORT_TEMPLATES (1 で約1GBのテンプレートも入れる)
APT_PACKAGES+=(unzip fontconfig libfontconfig1)

module_godot() {
  local base="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable"
  local dir=/opt/godot
  mkdir -p "$dir" &&
  curl -fsSL -o /tmp/godot.zip "$base/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" &&
  unzip -qo /tmp/godot.zip -d "$dir" &&
  ln -sf "$dir/Godot_v${GODOT_VERSION}-stable_linux.x86_64" /usr/local/bin/godot &&
  rm -f /tmp/godot.zip || return 1

  if [ "${GODOT_EXPORT_TEMPLATES:-0}" = "1" ]; then
    local tpl="$HOME/.local/share/godot/export_templates/${GODOT_VERSION}.stable"
    mkdir -p "$tpl" &&
    curl -fsSL -o /tmp/tpl.tpz "$base/Godot_v${GODOT_VERSION}-stable_export_templates.tpz" &&
    unzip -qo /tmp/tpl.tpz -d /tmp/tpl &&
    mv /tmp/tpl/templates/* "$tpl/" &&
    rm -rf /tmp/tpl /tmp/tpl.tpz
  fi
}
