#!/bin/bash
# envs/<name>.env と modules/ から、dist/<name>.sh (本体)・<name>.setup.sh (貼り付け用起動スクリプト)・
# <name>.domains.txt (許可ドメイン) を生成する。
# 使い方: ./build.sh          (全環境)
#         ./build.sh godot    (指定環境のみ)
set -euo pipefail
cd "$(dirname "$0")"

# 起動スクリプトが本体を取得する場所 (public リポジトリの main)
RAW_BASE="https://raw.githubusercontent.com/so16tm/cloud-dev-env/main"

build() {
  local name=$1 env_file="envs/$1.env" modules m
  [ -f "$env_file" ] || { echo "not found: $env_file" >&2; return 1; }
  # shellcheck disable=SC2016
  modules=$(bash -c 'source "$1"; echo "$MODULES"' _ "$env_file")
  for m in $modules; do
    [ -f "modules/$m.sh" ] || { echo "$env_file: module not found: modules/$m.sh" >&2; return 1; }
  done

  mkdir -p dist
  {
    echo '#!/bin/bash'
    echo "# 生成物: ./build.sh $name で envs/$name.env と modules/ から生成。直接編集しない"
    echo '# module_* は lib/tail.sh から名前を組み立てて間接的に呼ぶため、到達不能の誤検知を抑止する'
    echo '# shellcheck disable=SC2317'
    echo
    echo "# 本体の取得元。モジュールが同じリポジトリのファイルを取得するときに使う"
    echo "RAW_BASE=\"$RAW_BASE\""
    echo
    cat "$env_file"
    echo
    cat lib/head.sh
    for m in $modules; do echo; cat "modules/$m.sh"; done
    echo
    cat lib/tail.sh
  } > "dist/$name.sh"
  echo "built dist/$name.sh ($(wc -c < "dist/$name.sh") bytes)"

  # 環境設定の Allowed domains に貼る一覧。コメント・空白を除き、重複は先勝ちで除く
  {
    cat domains/common.txt
    if [ -f "envs/$name.domains" ]; then cat "envs/$name.domains"; fi
  } | sed -e 's/#.*//' -e 's/[[:space:]]//g' | awk 'NF && !seen[$0]++' > "dist/$name.domains.txt"
  echo "built dist/$name.domains.txt ($(wc -l < "dist/$name.domains.txt") domains)"

  # 環境設定の Setup script に一度だけ貼る起動スクリプト。本体は起動時にリポジトリから取得する
  cat > "dist/$name.setup.sh" <<EOF
#!/bin/bash
# cloud-dev-env の $name 環境。本体 dist/$name.sh をリポジトリから取得して実行する
# リポジトリの更新は環境キャッシュの期限 (約7日) で反映される。すぐ反映したいときは rev を上げて保存し直す
# rev: 1
set -euo pipefail
# 取得に失敗したら非ゼロで終了し、ツールの無い状態が環境キャッシュに残らないようにする
curl -fsSL --retry 3 -o /tmp/cloud-setup.sh "$RAW_BASE/dist/$name.sh"
exec bash /tmp/cloud-setup.sh
EOF
  echo "built dist/$name.setup.sh"
}

if [ $# -gt 0 ]; then
  for n in "$@"; do build "$n"; done
else
  for f in envs/*.env; do build "$(basename "$f" .env)"; done
fi
