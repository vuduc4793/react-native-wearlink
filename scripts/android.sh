#!/usr/bin/env bash
# Đồng bộ project (Gradle root) sang MacBook Pro rồi chạy Gradle/adb ở đó.
#   scripts/android.sh build            # assembleDebug
#   scripts/android.sh install          # build + cài sample lên điện thoại + mở app
#   scripts/android.sh logcat           # xem log của SDK
#   scripts/android.sh gradle <task...> # chạy task tuỳ ý
set -euo pipefail

REMOTE=${REMOTE:-ducvu@cs-macbook-pro}
REMOTE_DIR=${REMOTE_DIR:-smart-wear-sdk}
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENV='export ANDROID_HOME=$HOME/Library/Android/sdk; export JAVA_HOME=$(/usr/libexec/java_home -v 17); export PATH=$ANDROID_HOME/platform-tools:$PATH'

sync() {
  # research/ không đồng bộ, trừ đúng một file firmware Y25 mà unit test OTA (RealtekImageTest/RealtekDfuTest) cần.
  rsync -az --delete \
    --include /sdks/gloryfit/research/ --include /sdks/gloryfit/research/firmware/ \
    --include /sdks/gloryfit/research/firmware/RB370L73AC_V001205.bin \
    --exclude '/sdks/gloryfit/research/firmware/*' --exclude '/sdks/gloryfit/research/*' \
    --exclude .gradle --exclude build --exclude .build --exclude .kotlin --exclude local.properties --exclude /.secrets \
    --exclude .venv --exclude .gstack --exclude apk --exclude research --exclude __pycache__ \
    --exclude node_modules --exclude Pods --exclude "/sdks/react-native" \
    --exclude "/sdks/*/ios" --exclude "/apps/ios" --exclude design \
    "$HERE/" "$REMOTE:$REMOTE_DIR/"
  ssh "$REMOTE" "echo sdk.dir=\$HOME/Library/Android/sdk > $REMOTE_DIR/local.properties"
}

remote() { ssh "$REMOTE" "$ENV; cd $REMOTE_DIR && $*"; }

case "${1:-build}" in
  build)   sync; remote ./gradlew --console=plain -q assembleDebug ;;
  test)    sync; remote ./gradlew --console=plain testDebugUnitTest ;;
  install) sync; remote ./gradlew --console=plain -q :app:installDebug
           remote adb shell am start -n com.smartwear.lab/.MainActivity ;;
  logcat)  remote adb logcat -v time -s SmartWear:V QRing:V Sample:V AndroidRuntime:E ;;
  gradle)  shift; sync; remote ./gradlew --console=plain "$@" ;;
  *)       echo "unknown command: $1" >&2; exit 2 ;;
esac
