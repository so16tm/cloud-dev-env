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

check_godot() {
  local v
  if v=$(godot --headless --version 2> /dev/null); then check_ok "Godot $v"; else check_ng "godot が動かない"; fi
  for v in 8 10; do
    if dotnet --list-sdks 2> /dev/null | grep -q "^$v\."; then check_ok ".NET SDK $v"; else check_ng ".NET SDK $v が無い"; fi
  done
}
