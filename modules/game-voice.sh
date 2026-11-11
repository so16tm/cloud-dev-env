# ---- modules/game-voice.sh ----
# 日本語音声の生成 (Irodori-TTS の ONNX INT8 版を CPU で推論)。依存とモデルで約3.2GB、導入に約70秒かかる。
# 必要なときに入れると使うセッションのたびに取得し直すため、setup で入れて環境キャッシュに載せる。
# so16tm/game-voice (private) から ONNX INT8 の CPU 推論だけを tools/game-voice に移植したもの
APT_PACKAGES+=(python3-venv)

module_game_voice() {
  local dir=/opt/game-voice f
  # torch は CPU 版を先に入れる (後の依存解決で CUDA 版を取りに行かないように)。
  # irodori-tts は透かし・本文の正規化・トークン分割だけを使うため、学習用の重い依存は入れない
  # 工程ごとの時刻を残す (クラウドで setup が打ち切られたときに、どこで時間がかかったか分かるように)
  echo "[game-voice] torch $(date -Is)"
  mkdir -p "$dir" &&
  python3 -m venv "$dir/venv" &&
  PIP_NO_CACHE_DIR=1 "$dir/venv/bin/pip" install -q --index-url https://download.pytorch.org/whl/cpu \
    torch==2.10.0 torchaudio==2.10.0 &&
  echo "[game-voice] deps $(date -Is)" &&
  PIP_NO_CACHE_DIR=1 "$dir/venv/bin/pip" install -q \
    numpy==2.2.6 onnxruntime==1.23.2 "tokenizers>=0.22,<1" "huggingface_hub>=0.34,<2" \
    "soundfile>=0.12" "pyloudnorm>=0.1.1" "safetensors>=0.7" \
    "silentcipher @ git+https://github.com/SesameAILabs/silentcipher.git@d46d7d0893a583d8968ab3a6626e2289faec9152" &&
  PIP_NO_CACHE_DIR=1 "$dir/venv/bin/pip" install -q --no-deps \
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
  echo "[game-voice] end $(date -Is)"
}

check_game_voice() {
  if [ -x /usr/local/bin/game-voice ] && [ -d /opt/game-voice/hf/hub/models--Ryoppi--Irodori-TTS-v4.1-Small-MF-ONNX-int8 ]; then
    check_ok "game-voice (音声生成。モデル取得済み)"
  else
    check_ng "game-voice が無いかモデルが未取得 (/var/log/cloud-setup.log を確認)"
  fi
}
