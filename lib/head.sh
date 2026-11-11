# ---- lib/head.sh ----
# 制約: 非ゼロ終了でセッションが起動しない / 約5分を超えると環境キャッシュされない。
LOG=/var/log/cloud-setup.log
exec > >(tee -a "$LOG") 2>&1
export DEBIAN_FRONTEND=noninteractive
# 各モジュールが必要な apt パッケージを追記する。モジュール本体より先にまとめて入れる
APT_PACKAGES=()
failed=()
echo "[setup] start $(date -Is) modules: $MODULES"
# setup が途中で打ち切られても NG と分かるよう、最後に本物で置き換える仮の確認コマンドを先に置く
printf '#!/bin/bash\necho "NG  setup が最後まで終わっていない (/var/log/cloud-setup*.log を確認)"\nexit 1\n' > /usr/local/bin/cloud-env-check
chmod +x /usr/local/bin/cloud-env-check

# cloud-env-check の結果の出力。各モジュールは check_<name>() にセッション内で確かめる項目を書き、これで報告する
check_ok() { echo "OK  $*"; }
# shellcheck disable=SC2034 # NG は cloud-env-check の終了コードに使う
check_ng() { echo "NG  $*"; NG=1; }
