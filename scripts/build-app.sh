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

# 优先用固定的自签名身份签名。ad-hoc 签名（--sign -）的指纹随二进制内容
# 变化，macOS 因此认定每次构建都是「另一个应用」，把辅助功能与输入监控
# 授权全部作废——开发期每改一行代码就要重授权一次。
#
# 固定身份的指纹不变，授权一次即可长期有效。创建方法见 docs/dev-signing.md。
# 没有该身份时退回 ad-hoc，保证脚本在任何机器上都能跑通。
SIGN_ID="vInput Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" --timestamp=none "$APP_DIR"
  print "已用固定身份签名: $SIGN_ID"
else
  codesign --force --sign - --timestamp=none "$APP_DIR"
  print "已 ad-hoc 签名（每次构建都会重置系统授权，见 docs/dev-signing.md）"
fi

print "已构建: $APP_DIR"
