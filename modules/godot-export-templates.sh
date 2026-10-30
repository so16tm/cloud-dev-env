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
