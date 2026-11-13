# ---- modules/game-voice.sh ----
# 日本語音声の生成 (Irodori-TTS の ONNX INT8 版を CPU で推論)。依存とモデルで約3.2GB、導入に約70秒かかる。
# 必要なときに入れると使うセッションのたびに取得し直すため、setup で入れて環境キャッシュに載せる。
# setup で失敗したときのために ON_DEMAND にも入れ、セッション内で cloud-prepare game-voice で入れ直せるようにする。
# so16tm/game-voice (private) から ONNX INT8 の CPU 推論だけを tools/game-voice に移植したもの
APT_PACKAGES+=(python3-venv)

about_game_voice() { echo "音声生成 game-voice (約3.2GB)。setup で失敗したときに入れ直す"; }

module_game_voice() {
  local dir=/opt/game-voice f
  # クラウドでは setup がこの導入の途中で止まることがある (原因は未特定)。止まっても setup を使い切らないよう、
  # 段階ごとに打ち切って再試行する。git (GitHub は専用のプロキシ経由) は既定で打ち切らないため、30秒ほぼ止まったら中断させる
  export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30
  # 使い方: gv_pip <段階名> <1回の上限秒> <試行回数> <pip install の引数>...
  gv_pip() {
    local stage=$1 limit=$2 tries=$3 i
    shift 3
    local rc
    for ((i = 1; i <= tries; i++)); do
      echo "[game-voice] $stage $(date -Is) (試行 $i)"
      # クラウドで止まったときにどのパッケージの取得かが分かるよう、-q を付けずに取得の経過をログに残す
      PIP_NO_CACHE_DIR=1 timeout "$limit" "$dir/venv/bin/pip" install --progress-bar off --timeout 30 "$@" && return 0
      rc=$?
      # 124 は timeout による打ち切り
      echo "[game-voice] $stage 失敗 $(date -Is) (終了コード $rc$([ "$rc" -eq 124 ] && echo "、${limit}秒で打ち切り"))"
    done
    return 1
  }
  # クラウドの pip の設定 (取得元の変更など) が CI と違う可能性があるため、設定のある場所と変数名だけを残す (値は出さない)
  echo "[game-voice] pip の環境変数: $(env | cut -d= -f1 | grep -i '^pip_' | tr '\n' ' ')"
  for f in /etc/pip.conf /etc/xdg/pip/pip.conf "$HOME/.pip/pip.conf" "$HOME/.config/pip/pip.conf"; do
    if [ -f "$f" ]; then echo "[game-voice] pip の設定ファイル: $f"; fi
  done
  rm -f "$dir/.installed"
  # venv は apt の python3-venv (Ubuntu 24.04 では python3.12-venv) と対になる 3.12 で作り、CI と揃える。
  # PATH の python3 はクラウドでは 3.13 で、pydub (silentcipher の依存) が 3.13 で削除された audioop を使うため透かしを読み込めない
  mkdir -p "$dir" &&
  /usr/bin/python3.12 -m venv --clear "$dir/venv" &&
  # torch は CPU 版を先に入れる (後の依存解決で CUDA 版を取りに行かないように)
  gv_pip torch 150 2 --index-url https://download.pytorch.org/whl/cpu torch==2.10.0 torchaudio==2.10.0 &&
  # PyPI の依存と GitHub の取得を分け、どちらで止まったかをログで分かるようにする。
  # silentcipher の依存 (requirements.txt) はここで入れ、本体は --no-deps で入れる
  gv_pip deps 150 2 \
    numpy==2.2.6 onnxruntime==1.23.2 "tokenizers>=0.22,<1" "huggingface_hub>=0.34,<2" \
    "soundfile>=0.12" "pyloudnorm>=0.1.1" "safetensors>=0.7" \
    "librosa>=0.10" "scipy>=1.11.4" "pyaml>=24.4" "Flask>=2.2.5" "pydub>=0.25.1" &&
  # irodori-tts は透かし・本文の正規化・トークン分割だけを使うため、学習用の重い依存は入れない
  gv_pip git 60 3 --no-deps \
    "silentcipher @ git+https://github.com/SesameAILabs/silentcipher.git@d46d7d0893a583d8968ab3a6626e2289faec9152" \
    "irodori-tts @ git+https://github.com/Aratako/Irodori-TTS.git@82c9980b6bfe8d4bbcc45f05b6ed729316694e7c" || return 1
  for f in game_voice.py presets.json LICENSE-muse-irodori-voice.txt; do
    curl -fsSL --retry 3 -o "$dir/$f" "$RAW_BASE/tools/game-voice/$f" || return 1
  done
  cat > /usr/local/bin/game-voice <<EOF
#!/bin/sh
export HF_HOME=$dir/hf
exec $dir/venv/bin/python $dir/game_voice.py "\$@"
EOF
  chmod +x /usr/local/bin/game-voice &&
  echo "[game-voice] models $(date -Is)" &&
  game-voice download &&
  touch "$dir/.installed" &&
  echo "[game-voice] end $(date -Is)"
}

check_game_voice() {
  # 印は導入とモデル・透かしの取得が最後まで通ったときだけ置く (ファイルの有無だけでは途中の失敗を見逃す)
  if [ -x /usr/local/bin/game-voice ] && [ -f /opt/game-voice/.installed ]; then
    check_ok "game-voice (音声生成。モデル取得済み)"
  else
    check_ng "game-voice の導入が完了していない。cloud-prepare game-voice で入れ直す (/var/log/cloud-setup-game-voice.log を確認)"
  fi
}
