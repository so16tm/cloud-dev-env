# ---- modules/game-voice.sh ----
# ON_DEMAND (cloud-prepare game-voice)。依存とモデルで数GBあり、台詞を作るときしか使わないため setup には入れない。
# so16tm/game-voice (private) から ONNX INT8 の CPU 推論だけを tools/game-voice に移植したもの
about_game_voice() { echo "日本語音声の生成 game-voice (Irodori-TTS の ONNX INT8 版、CPU で推論)。依存とモデルで数GB。ゲームの台詞を WAV で作るときに使う"; }

module_game_voice() {
  local dir=/opt/game-voice f
  # torch は CPU 版を先に入れる (後の依存解決で CUDA 版を取りに行かないように)。
  # irodori-tts は透かし・本文の正規化・トークン分割だけを使うため、学習用の重い依存は入れない
  mkdir -p "$dir" &&
  python3 -m venv "$dir/venv" &&
  PIP_NO_CACHE_DIR=1 "$dir/venv/bin/pip" install -q --index-url https://download.pytorch.org/whl/cpu \
    torch==2.10.0 torchaudio==2.10.0 &&
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
  game-voice download
}
