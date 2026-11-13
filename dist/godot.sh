#!/bin/bash
# 生成物: ./build.sh godot で envs/godot.env と modules/ から生成。直接編集しない
# module_* は lib/tail.sh から名前を組み立てて間接的に呼ぶため、到達不能の誤検知を抑止する
# shellcheck disable=SC2317

# 本体の取得元。モジュールが同じリポジトリのファイルを取得するときに使う (CI では検証中のコミットを指すよう上書きする)
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/so16tm/cloud-dev-env/main}"

# ---- envs/godot.env ----
# Godot 開発用 (GDScript / C# 両対応)。Node.js / Python / Docker は既定イメージのものを使う
MODULES="claude-config base-cli godot game-voice"
# 毎回は使わないもの。セッション内で cloud-prepare <名前> で入れる
ON_DEMAND="godot-export-templates game-voice"

# ${VAR-default} 形式にして、CI 等から上書きできるようにする
GODOT_VERSION="${GODOT_VERSION-4.7.2}"

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

# ---- modules/claude-config.sh ----
# クラウドでは手元の ~/.claude/CLAUDE.md が読まれないため、claude/CLAUDE.md をユーザー規約として置く。
# Claude Code は root で動くので /root/.claude/CLAUDE.md になる
module_claude_config() {
  mkdir -p "$HOME/.claude" &&
  curl -fsSL --retry 3 -o "$HOME/.claude/CLAUDE.md" "$RAW_BASE/claude/CLAUDE.md"
}

check_claude_config() {
  if [ -s "$HOME/.claude/CLAUDE.md" ]; then check_ok "ユーザー規約 ~/.claude/CLAUDE.md"; else check_ng "ユーザー規約 ~/.claude/CLAUDE.md が無い"; fi
}

# ---- modules/base-cli.sh ----
# 既定イメージに無い CLI。git, gh, jq, yq, rg, tmux は既定で入っている
APT_PACKAGES+=(fd-find bat shellcheck tree unzip zip htop)

module_base_cli() {
  ln -sf /usr/bin/fdfind /usr/local/bin/fd &&
  ln -sf /usr/bin/batcat /usr/local/bin/bat
}

check_base_cli() {
  local c missing=()
  for c in fd bat shellcheck tree unzip; do command -v "$c" > /dev/null || missing+=("$c"); done
  if [ ${#missing[@]} -eq 0 ]; then check_ok "CLI (fd, bat, shellcheck など)"; else check_ng "CLI が PATH に無い: ${missing[*]}"; fi
}

# ---- modules/godot.sh ----
# Godot の .NET 版を入れる。.NET 版は GDScript と C# の両方を扱えるため、混在・途中切り替えに対応できる。
# 変数: GODOT_VERSION (例 4.7.2)
# .NET SDK は Ubuntu 24.04 の標準フィードにある 8.0 (Godot 4.5 以降の最低要件・新規プロジェクトの既定) と
# 10.0 (LTS) を両方入れ、プロジェクトの TargetFramework がどちらでもビルドできるようにする。
# エクスポートテンプレート (約1GB) は書き出すときしか使わないため cloud-prepare godot-export-templates で入れる
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
}

check_godot() {
  local v
  if v=$(godot --headless --version 2> /dev/null); then check_ok "Godot $v"; else check_ng "godot が動かない"; fi
  for v in 8 10; do
    if dotnet --list-sdks 2> /dev/null | grep -q "^$v\."; then check_ok ".NET SDK $v"; else check_ng ".NET SDK $v が無い"; fi
  done
}

# ---- modules/game-voice.sh ----
# 日本語音声の生成 (Irodori-TTS の ONNX INT8 版を CPU で推論)。依存とモデルで約3.2GB、導入に約70秒かかる。
# 必要なときに入れると使うセッションのたびに取得し直すため、setup で入れて環境キャッシュに載せる。
# setup で失敗したときのために ON_DEMAND にも入れ、セッション内で cloud-prepare game-voice で入れ直せるようにする。
# so16tm/game-voice (private) から ONNX INT8 の CPU 推論だけを tools/game-voice に移植したもの
APT_PACKAGES+=(python3-venv)

about_game_voice() { echo "音声生成 game-voice (約3.2GB)。setup で失敗したときに入れ直す"; }

module_game_voice() {
  local dir=/opt/game-voice f rc
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
      # 再試行で取得済みのパッケージを取り直さないよう、導入中だけ pip のキャッシュを使う (最後に消す)
      PIP_CACHE_DIR=/tmp/game-voice-pip timeout "$limit" "$dir/venv/bin/pip" install --progress-bar off --timeout 30 "$@" && return 0
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
  # silentcipher の依存 (requirements.txt) はここで入れ、本体は --no-deps で入れる。
  # クラウドでは PyPI の取得が遅いため量を減らす: librosa は silentcipher の server.py が import するだけで使っておらず、
  # 依存 (llvmlite・numba・scikit-learn など約110MB) が大きいため入れずに空のモジュールで代える。Flask は server.py が使わない
  gv_pip deps 150 2 \
    numpy==2.2.6 onnxruntime==1.23.2 "tokenizers>=0.22,<1" "huggingface_hub>=0.34,<2" \
    "soundfile>=0.12" "pyloudnorm>=0.1.1" "safetensors>=0.7" \
    "scipy>=1.11.4" "pyaml>=24.4" "pydub>=0.25.1" &&
  # irodori-tts は透かし・本文の正規化・トークン分割だけを使うため、学習用の重い依存は入れない
  gv_pip git 60 3 --no-deps \
    "silentcipher @ git+https://github.com/SesameAILabs/silentcipher.git@d46d7d0893a583d8968ab3a6626e2289faec9152" \
    "irodori-tts @ git+https://github.com/Aratako/Irodori-TTS.git@82c9980b6bfe8d4bbcc45f05b6ed729316694e7c" &&
  echo '# 空のモジュール: silentcipher が import するだけで使わない librosa の代わり (cloud-dev-env の game-voice モジュールが置く)' \
    > "$("$dir/venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')/librosa.py"
  rc=$?
  rm -rf /tmp/game-voice-pip
  [ "$rc" -eq 0 ] || return 1
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

# ---- lib/tail.sh ----
# apt は並列実行するとロックで衝突するため、先に一括で入れてからモジュールを並列実行する。
if [ ${#APT_PACKAGES[@]} -gt 0 ]; then
  if apt-get update -qq && apt-get install -y -qq --no-install-recommends "${APT_PACKAGES[@]}"; then
    echo "[setup] apt: done"
  else
    echo "[setup] apt: FAILED (続行します)"
    failed+=(apt)
  fi
fi

declare -A pids
# モジュールのログは /var/log に直接書く (setup が途中で打ち切られても、どこまで進んだか残るように)
for m in $MODULES; do
  "module_${m//-/_}" > "/var/log/cloud-setup-$m.log" 2>&1 &
  pids[$m]=$!
done

for m in $MODULES; do
  if wait "${pids[$m]}"; then
    echo "[setup] $m: done $(date -Is)"
  else
    echo "[setup] $m: FAILED $(date -Is) (続行します)"
    failed+=("$m")
  fi
  cat "/var/log/cloud-setup-$m.log"
done

# setup の時点では環境の Environment variables が未設定で、出力もセッションに表示されないため、
# 確認はセッション内で cloud-env-check を実行して行う (クラウド用 CLAUDE.md で最初に実行するよう指示している)
{
  echo '#!/bin/bash'
  echo '# 生成物: cloud-dev-env の setup が書き出す。セッション内の状態を確認し、NG があれば終了コード 1'
  echo "SETUP_FAILED=\"${failed[*]}\""
  declare -f check_ok check_ng
  for m in $MODULES; do declare -f "check_${m//-/_}"; done
  cat <<'EOF'
NG=0
if [ -n "$SETUP_FAILED" ]; then check_ng "setup で失敗: $SETUP_FAILED (/var/log/cloud-setup.log を確認)"; else check_ok "setup"; fi
EOF
  for m in $MODULES; do
    if declare -F "check_${m//-/_}" > /dev/null; then echo "check_${m//-/_}"; fi
  done
  cat <<'EOF'
exit "$NG"
EOF
} > /usr/local/bin/cloud-env-check
chmod +x /usr/local/bin/cloud-env-check

# 毎回は使わないツールは setup に入れず (リポジトリごとの初回の待ち時間を短くするため)、
# セッション内で必要になったときに cloud-prepare <名前> で入れる。ON_DEMAND のモジュールは
# APT_PACKAGES と環境の変数を使わず、module_<name>() だけで完結させる (setup の外で動くため)
{
  echo '#!/bin/bash'
  echo '# 生成物: cloud-dev-env の setup が書き出す。毎回は使わないツールを必要なときに入れる'
  echo "ON_DEMAND=\"${ON_DEMAND:-}\""
  # 取得元はこのリポジトリの main。CI では検証中のコミットを指すよう上書きする
  echo "RAW_BASE=\"\${RAW_BASE:-$RAW_BASE}\""
  for m in ${ON_DEMAND:-}; do declare -f "about_${m//-/_}" "module_${m//-/_}"; done
  cat <<'EOF'
if [ $# -eq 0 ]; then
  echo "使い方: cloud-prepare <名前>... (時間がかかるものはバックグラウンドで実行する)"
  for m in $ON_DEMAND; do echo "  $m: $("about_${m//-/_}")"; done
  exit 0
fi
rc=0
for m in "$@"; do
  case " $ON_DEMAND " in
    *" $m "*) ;;
    *) echo "$m: 不明 (使えるもの: ${ON_DEMAND:-なし})"; rc=1; continue ;;
  esac
  if "module_${m//-/_}"; then echo "$m: done"; else echo "$m: FAILED"; rc=1; fi
done
exit "$rc"
EOF
} > /usr/local/bin/cloud-prepare
chmod +x /usr/local/bin/cloud-prepare

echo "[setup] end $(date -Is)"
exit 0
