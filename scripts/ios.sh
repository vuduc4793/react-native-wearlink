#!/usr/bin/env bash
# Đồng bộ phần iOS (sdks/Package.swift, sdks/*/ios, apps/ios) sang MacBook Pro rồi build/test/cài ở đó.
# Thư mục đích RIÊNG (~/smart-wear-sdk-ios), KHÔNG dùng ~/smart-wear-sdk (Android sync --delete vào đó).
#
#   scripts/ios.sh test                  # swift test cho SmartWearKit (chạy trên macOS)
#   scripts/ios.sh gen                   # xcodegen sinh apps/ios/SmartWearLab.xcodeproj
#   scripts/ios.sh build                 # build app cho iPhone (Debug, ký tự động)
#   scripts/ios.sh install               # build + cài lên iPhone
#   scripts/ios.sh run [args...]         # mở app, gắn console (stdout), vd:
#        scripts/ios.sh run -autoConnect 32:35:45:37:4E:00,COROS -measure HEART_RATE -autoExit YES
#   scripts/ios.sh screenshot [name]     # kéo ảnh chụp app tự lưu (Documents/<name>.png) về ./build/ios-shots
#   scripts/ios.sh devices               # liệt kê thiết bị devicectl
set -euo pipefail

REMOTE=${REMOTE:-ducvu@cs-macbook-pro}
REMOTE_DIR=${REMOTE_DIR:-smart-wear-sdk-ios}
DEVICE=${DEVICE:-4664B375-1E03-5A2A-857F-D16A56592905}   # iPhone 11 "iPhone của Đức"
BUNDLE_ID=com.smartwear.lab
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED=build/DerivedData
APP=$DERIVED/Build/Products/Debug-iphoneos/SmartWearLab.app

sync() {
  rsync -az --delete \
    --exclude .build --exclude .swiftpm --exclude /build --exclude '*.xcodeproj' --exclude .DS_Store \
    --exclude /apps/ios/SmartWearLab/Info.plist \
    --include /sdks/ --include /sdks/Package.swift --include '/sdks/*/' --include '/sdks/*/ios/***' \
    --include /apps/ --include '/apps/ios/***' --include /apps/shared/ --include '/apps/shared/***' \
    --include /scripts/ --include /scripts/ios.sh \
    --include /docs/ --include '/docs/***' \
    --exclude '*' \
    "$HERE/" "$REMOTE:$REMOTE_DIR/"
}

remote() { ssh "$REMOTE" "cd $REMOTE_DIR && $*"; }

gen() { remote "cd apps/ios && /opt/homebrew/bin/xcodegen generate --quiet"; }

# Khoá keychain: qua ssh, login keychain bị khoá nên codesign báo errSecInternalComponent.
# Nếu có file ~/.smartwear-keychain-password (chmod 600, chứa mật khẩu đăng nhập Mac) trên MacBook thì mở khoá trước khi build.
unlock() {
  remote 'if [ -f ~/.smartwear-keychain-password ]; then
      security unlock-keychain -p "$(cat ~/.smartwear-keychain-password)" ~/Library/Keychains/login.keychain-db
    fi'
}

build() {
  gen
  unlock
  remote "set -o pipefail; xcodebuild -project apps/ios/SmartWearLab.xcodeproj -scheme SmartWearLab -configuration Debug \
    -destination generic/platform=iOS -derivedDataPath $DERIVED -allowProvisioningUpdates \
    -quiet build 2>&1 | grep -v '^note:'; codesign -v $APP && echo 'BUILD OK (signed): $APP'"
}

case "${1:-build}" in
  test)    sync; remote "cd sdks && swift test 2>&1 | tail -40" ;;
  gen)     sync; gen ;;
  build)   sync; build ;;
  install) sync; build
           remote "xcrun devicectl device install app --device $DEVICE $APP" ;;
  run)     shift
           remote "xcrun devicectl device process launch --device $DEVICE --console --terminate-existing $BUNDLE_ID $*" ;;
  screenshot)
           name=${2:-screen}
           mkdir -p "$HERE/build/ios-shots"
           remote "xcrun devicectl device copy from --device $DEVICE --domain-type appDataContainer \
             --domain-identifier $BUNDLE_ID --source Documents/$name.png --destination /tmp/$name.png >/dev/null"
           scp -q "$REMOTE:/tmp/$name.png" "$HERE/build/ios-shots/$name.png"
           echo "$HERE/build/ios-shots/$name.png" ;;
  sim)     # Ảnh chụp trên máy ảo (không cần ký, không có Bluetooth): scripts/ios.sh sim <26|18> <name> [args...]
           os=${2:-26}; name=${3:-sim}; shift 3 || true
           sync; gen
           remote "set -o pipefail; xcodebuild -project apps/ios/SmartWearLab.xcodeproj -scheme SmartWearLab -configuration Debug \
             -destination 'generic/platform=iOS Simulator' -derivedDataPath $DERIVED CODE_SIGNING_ALLOWED=NO -quiet build 2>&1 | grep -v '^note:' | tail -5"
           rt=$(ssh "$REMOTE" "xcrun simctl list runtimes | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS-$os-[0-9]*' | tail -1")
           sim=$(ssh "$REMOTE" "xcrun simctl list devices | grep 'SmartWearLab-$os ' | grep -oE '[0-9A-F-]{36}' | head -1")
           [ -n "$sim" ] || sim=$(ssh "$REMOTE" "xcrun simctl create SmartWearLab-$os 'iPhone 16' $rt")
           ssh "$REMOTE" "xcrun simctl boot $sim 2>/dev/null; xcrun simctl bootstatus $sim -b >/dev/null; \
             xcrun simctl ui $sim appearance dark; \
             xcrun simctl install $sim $REMOTE_DIR/$DERIVED/Build/Products/Debug-iphonesimulator/SmartWearLab.app && \
             xcrun simctl launch --terminate-running-process $sim $BUNDLE_ID $* >/dev/null && sleep 6 && \
             xcrun simctl io $sim screenshot /tmp/$name.png >/dev/null"
           mkdir -p "$HERE/build/ios-shots"; scp -q "$REMOTE:/tmp/$name.png" "$HERE/build/ios-shots/$name.png"
           echo "$HERE/build/ios-shots/$name.png" ;;
  sim-off) ssh "$REMOTE" 'for s in $(xcrun simctl list devices | grep "SmartWearLab-" | grep -oE "[0-9A-F-]{36}"); do xcrun simctl shutdown $s 2>/dev/null; done; true' ;;
  devices) ssh "$REMOTE" "xcrun devicectl list devices" ;;
  *)       echo "unknown command: $1" >&2; exit 2 ;;
esac
