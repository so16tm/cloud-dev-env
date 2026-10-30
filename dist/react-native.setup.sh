#!/bin/bash
# cloud-dev-env の react-native 環境。本体 dist/react-native.sh をリポジトリから取得して実行する
# リポジトリの更新は環境キャッシュの期限 (約7日) で反映される。すぐ反映したいときは rev を上げて保存し直す
# rev: 1
set -euo pipefail
# 取得に失敗したら非ゼロで終了し、ツールの無い状態が環境キャッシュに残らないようにする
curl -fsSL --retry 3 -o /tmp/cloud-setup.sh "https://raw.githubusercontent.com/so16tm/cloud-dev-env/main/dist/react-native.sh"
exec bash /tmp/cloud-setup.sh
