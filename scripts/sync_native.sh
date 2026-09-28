#!/bin/sh
#
# Builds the native SDKs from their sibling repos and makes them available
# to this plugin:
#   - Android: publishes com.pgsdk:paymentsdk to the local Maven repo (~/.m2)
#   - iOS:     builds PGPaymentSDK.xcframework and copies it to ios/Frameworks
#
# Run after cloning, and again whenever either native SDK changes.
#
# Usage: scripts/sync_native.sh [android|ios]   (default: both)
# Env:   PG_ANDROID_SDK_DIR  (default: ../pg_sdk_android)
#        PG_IOS_SDK_DIR      (default: ../pg_ios_sdk)

set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_SDK_DIR="${PG_ANDROID_SDK_DIR:-$ROOT_DIR/../pg_sdk_android}"
IOS_SDK_DIR="${PG_IOS_SDK_DIR:-$ROOT_DIR/../pg_ios_sdk}"
TARGET="${1:-all}"

if [ "$TARGET" = "all" ] || [ "$TARGET" = "android" ]; then
  echo "Publishing Android SDK from $ANDROID_SDK_DIR to mavenLocal..."
  (cd "$ANDROID_SDK_DIR" && ./gradlew :paymentsdk:publishToMavenLocal)
fi

if [ "$TARGET" = "all" ] || [ "$TARGET" = "ios" ]; then
  # xcodebuild needs a full Xcode, not just the Command Line Tools.
  if [ -z "${DEVELOPER_DIR:-}" ] && xcode-select -p | grep -q CommandLineTools \
      && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
  echo "Building iOS XCFramework from $IOS_SDK_DIR..."
  "$IOS_SDK_DIR/Scripts/build-xcframework.sh"
  rm -rf "$ROOT_DIR/ios/Frameworks/PGPaymentSDK.xcframework"
  mkdir -p "$ROOT_DIR/ios/Frameworks"
  cp -R "$IOS_SDK_DIR/build/PGPaymentSDK.xcframework" "$ROOT_DIR/ios/Frameworks/"
fi

echo "Native SDKs synced."
