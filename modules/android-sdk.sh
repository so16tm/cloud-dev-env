# ---- modules/android-sdk.sh ----
# Android SDK (cmdline-tools と ANDROID_SDK_PACKAGES) と JDK 17。
# React Native・Expo は JDK 17 を推奨しているため、既定イメージの JDK 21 とは別に入れて JAVA_HOME で切り替える。
# ここに無い platform・NDK は、ライセンス同意済みなので Gradle がビルド時に自動で取得する
APT_PACKAGES+=(openjdk-17-jdk-headless unzip)

module_android_sdk() {
  local sdk=/opt/android-sdk java17=/usr/lib/jvm/java-17-openjdk-amd64
  mkdir -p "$sdk/cmdline-tools" &&
  curl -fsSL -o /tmp/cmdline-tools.zip \
    "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_BUILD}_latest.zip" &&
  rm -rf /tmp/cmdline-tools "$sdk/cmdline-tools/latest" &&
  unzip -qo /tmp/cmdline-tools.zip -d /tmp/cmdline-tools &&
  mv /tmp/cmdline-tools/cmdline-tools "$sdk/cmdline-tools/latest" &&
  rm -rf /tmp/cmdline-tools.zip /tmp/cmdline-tools || return 1

  # クラウドのセッションのシェルは profile.d も ~/.bashrc の末尾も読まないため、コマンドは PATH 上に置く。
  # JAVA_HOME と ANDROID_HOME は環境設定の Environment variables で渡す (README 参照)。profile.d はログインシェルと CI 用
  ln -sf "$sdk/cmdline-tools/latest/bin/sdkmanager" "$sdk/cmdline-tools/latest/bin/avdmanager" \
    "$sdk/platform-tools/adb" /usr/local/bin/
  cat > /etc/profile.d/android.sh <<EOF
export JAVA_HOME=$java17
export ANDROID_HOME=$sdk
EOF

  local sdkmanager="$sdk/cmdline-tools/latest/bin/sdkmanager"
  # ANDROID_SDK_PACKAGES は空白区切りの一覧をパッケージごとの引数に分けるため引用しない
  # shellcheck disable=SC2086
  yes | JAVA_HOME=$java17 "$sdkmanager" --licenses > /dev/null &&
  JAVA_HOME=$java17 "$sdkmanager" --install $ANDROID_SDK_PACKAGES > /dev/null
}
