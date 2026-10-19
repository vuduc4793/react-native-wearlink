#!/usr/bin/env bash
# Thư viện React Native (sdks/react-native) + app mẫu: đồng bộ sang MacBook Pro rồi cài/build ở đó.
# Thư mục đích RIÊNG (~/smart-wear-sdk-rn), không đụng ~/smart-wear-sdk (Android) và ~/smart-wear-sdk-ios.
#
#   scripts/rn.sh install     # npm install cho app mẫu (+ codegen chạy khi build)
#   scripts/rn.sh typecheck   # tsc thư viện + app mẫu
#   scripts/rn.sh android     # build APK debug của app mẫu (kiến trúc mới)
#   scripts/rn.sh release     # build APK release (bundle JS sẵn, không cần Metro: cổng 8081/8082 MacBook là của dự án khác)
#                             # + cài lên điện thoại qua adb
#   scripts/rn.sh ios         # pod install + build cho iOS Simulator (không ký)
set -euo pipefail

REMOTE=${REMOTE:-ducvu@cs-macbook-pro}
REMOTE_DIR=${REMOTE_DIR:-smart-wear-sdk-rn}
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENVS='export PATH=/opt/homebrew/bin:/opt/homebrew/opt/ruby/bin:$PATH; export ANDROID_HOME=$HOME/Library/Android/sdk; export LANG=en_US.UTF-8'

sync() {
  rsync -az --delete \
    --exclude node_modules --exclude Pods --exclude build --exclude .gradle --exclude .kotlin --exclude research \
    --exclude .cxx --exclude '*.xcworkspace/xcuserdata' --exclude local.properties --exclude Podfile.lock \
    --include /sdks/ --include '/sdks/*.podspec' --include '/sdks/*/' --include '/sdks/*/android/***' \
    --include '/sdks/*/ios/***' --include '/sdks/react-native/***' --exclude '*' \
    "$HERE/" "$REMOTE:$REMOTE_DIR/"
}

remote() { ssh "$REMOTE" "$ENVS; cd $REMOTE_DIR/sdks/react-native && $*"; }

case "${1:-}" in
  install)   sync; remote "cd example && npm install --no-audit --no-fund 2>&1 | tail -3" ;;
  typecheck) sync; remote "cd example && npx tsc --noEmit -p . && cd .. && ./example/node_modules/.bin/tsc --noEmit -p . && echo TYPECHECK OK" ;;
  android)   sync; remote "cd example/android && echo sdk.dir=\$ANDROID_HOME > local.properties && ./gradlew :app:assembleDebug -q 2>&1 | grep -v '^w:' | tail -30; ls -la app/build/outputs/apk/debug/*.apk" ;;
  release)   sync; remote "cd example/android && echo sdk.dir=\$ANDROID_HOME > local.properties && ./gradlew :app:assembleRelease -q 2>&1 | grep -v '^w:' | tail -30; \$ANDROID_HOME/platform-tools/adb install -r app/build/outputs/apk/release/app-release.apk" ;;
  ios)       sync; remote "cd example/ios && pod install 2>&1 | tail -5 && xcodebuild -workspace SmartWearExample.xcworkspace -scheme SmartWearExample -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO -quiet build 2>&1 | grep -E 'error|BUILD' | head -30; echo xcodebuild=\${PIPESTATUS[0]}" ;;
  *) echo "usage: $0 install|typecheck|android|release|ios"; exit 1 ;;
esac
