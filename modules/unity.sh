# ---- modules/unity.sh ----
# 変数: UNITY_IMAGE (GameCI の unityci/editor イメージ。空なら何もしない)
# Unity 公式の配布ドメインは Trusted の許可リストに無いため、許可済みの Docker Hub から取得する。

module_unity() {
  [ -n "$UNITY_IMAGE" ] || return 0
  # セットアップ時に dockerd が動いていない場合に備えて起動する。pull したイメージは
  # /var/lib/docker に残り、環境キャッシュ (ファイルシステムのスナップショット) に含まれる。
  if ! docker info >/dev/null 2>&1; then
    (dockerd >/var/log/dockerd.log 2>&1 &)
    for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
  fi
  docker pull -q "$UNITY_IMAGE" || return 1

  # カレントディレクトリをマウントして Unity をバッチモードで実行するラッパー。
  # 例: unity -projectPath /project -runTests -testPlatform EditMode
  # ライセンスは環境変数 UNITY_LICENSE (.ulf の中身) などで渡す。
  cat > /usr/local/bin/unity <<EOF
#!/bin/bash
docker info >/dev/null 2>&1 || { (dockerd >/var/log/dockerd.log 2>&1 &); sleep 5; }
exec docker run --rm -v "\$PWD":/project -w /project \\
  -e UNITY_LICENSE -e UNITY_EMAIL -e UNITY_PASSWORD -e UNITY_SERIAL \\
  "$UNITY_IMAGE" unity-editor -batchmode -nographics -logFile - "\$@"
EOF
  chmod +x /usr/local/bin/unity
}
