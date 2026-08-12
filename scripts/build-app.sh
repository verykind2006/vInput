#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="vInput"
CONFIGURATION="${CONFIGURATION:-debug}"
APP_DIR="$ROOT/dist/$APP_NAME.app"

cd "$ROOT"
swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"

case "$APP_DIR" in
  "$ROOT/dist/"*.app) ;;
  *) print -u2 "拒绝清理非预期路径: $APP_DIR"; exit 1 ;;
esac

rm -rf -- "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
ditto --norsrc --noextattr --noqtn --noacl "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
ditto --norsrc --noextattr --noqtn --noacl "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

codesign --force --sign - --timestamp=none "$APP_DIR"

print "已构建: $APP_DIR"
