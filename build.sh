#!/bin/bash
# envs/<name>.env と modules/ から、クラウド環境に貼る単一ファイル dist/<name>.sh を生成する。
# 使い方: ./build.sh          (全環境)
#         ./build.sh gamedev  (指定環境のみ)
set -euo pipefail
cd "$(dirname "$0")"

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
    echo
    cat "$env_file"
    echo
    cat lib/head.sh
    for m in $modules; do echo; cat "modules/$m.sh"; done
    echo
    cat lib/tail.sh
  } > "dist/$name.sh"
  echo "built dist/$name.sh ($(wc -c < "dist/$name.sh") bytes)"
}

if [ $# -gt 0 ]; then
  for n in "$@"; do build "$n"; done
else
  for f in envs/*.env; do build "$(basename "$f" .env)"; done
fi
