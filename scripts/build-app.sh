#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="vInput"
APP_DIR="$ROOT/dist/$APP_NAME.app"
DERIVED="${DERIVED_DATA:-$ROOT/.xcbuild}"

cd "$ROOT"

# 必须用 xcodebuild，不能用 swift build。
#
# SwiftPM 命令行**无法编译 Metal 着色器**——这是 mlx-swift 自己 README 里
# 写明的限制。它不编译、不警告，构建照样报 Build complete，只是产物里没有
# default.metallib，MLX 一初始化就崩：
#     Failed to load the default metallib. library not found
#
# 这个坑极隐蔽：全部单元测试照常通过（它们不碰真实模型），打包也「成功」，
# 只有用户开启校正说第一句话时才崩。M4 期间实际踩过。
print "用 xcodebuild 构建（SwiftPM 无法编译 Metal 着色器）…"
xcodebuild -scheme "$APP_NAME" \
    -destination "platform=OS X" \
    -derivedDataPath "$DERIVED" \
    -quiet \
    build

PRODUCTS="$DERIVED/Build/Products/Debug"
BIN_PATH="$PRODUCTS/$APP_NAME"

if [[ ! -x "$BIN_PATH" ]]; then
  print -u2 "构建产物缺失: $BIN_PATH"
  exit 1
fi

case "$APP_DIR" in
  "$ROOT/dist/"*.app) ;;
  *) print -u2 "拒绝清理非预期路径: $APP_DIR"; exit 1 ;;
esac

rm -rf -- "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
ditto --norsrc --noextattr --noqtn --noacl "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
ditto --norsrc --noextattr --noqtn --noacl "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# App 图标：icns 是生成物（.gitignore 里，母版是 render-icon.swift），缺了就
# 现做——保证换机器 clone 下来第一次构建也能出对的图标，而不是无声地打出
# 一个没有图标的空白应用包。
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  "$ROOT/scripts/make-icon.sh"
fi
ditto --norsrc --noextattr --noqtn --noacl \
    "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# 资源 bundle 必须一并打包，否则应用跑起来找不到它们。
#
# mlx-swift_Cmlx.bundle 里是 default.metallib（那 42 个着色器的编译产物）。
# 少了它，校正功能一启动就崩——而这在开发机上不会暴露，因为测试是从
# DerivedData 里直接跑的，bundle 就在二进制旁边。
BUNDLE_COUNT=0
for bundle in "$PRODUCTS"/*.bundle; do
  [[ -e "$bundle" ]] || continue
  ditto --norsrc --noextattr --noqtn --noacl \
      "$bundle" "$APP_DIR/Contents/Resources/${bundle:t}"
  BUNDLE_COUNT=$((BUNDLE_COUNT + 1))
done

if [[ ! -e "$APP_DIR/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]]; then
  print -u2 "缺少 default.metallib——校正功能会在运行时崩溃"
  print -u2 "检查 xcodebuild 是否真的编译了 Metal 着色器（日志中应有 CompileMetalFile）"
  exit 1
fi
print "已打包 $BUNDLE_COUNT 个资源 bundle（含 default.metallib）"

# 优先用固定的自签名身份签名。ad-hoc 签名（--sign -）的指纹随二进制内容
# 变化，macOS 因此认定每次构建都是「另一个应用」，把辅助功能与输入监控
# 授权全部作废——开发期每改一行代码就要重授权一次。
#
# 固定身份的指纹不变，授权一次即可长期有效。创建方法见 docs/dev-signing.md。
# 没有该身份时退回 ad-hoc，保证脚本在任何机器上都能跑通。
SIGN_ID="vInput Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --deep --sign "$SIGN_ID" --timestamp=none "$APP_DIR"
  print "已用固定身份签名: $SIGN_ID"
else
  codesign --force --deep --sign - --timestamp=none "$APP_DIR"
  print "已 ad-hoc 签名（每次构建都会重置系统授权，见 docs/dev-signing.md）"
fi

print "已构建: $APP_DIR"
