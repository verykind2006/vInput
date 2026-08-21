#!/bin/zsh
# 生成 Resources/AppIcon.icns。
#
# 生成物不进版本库（.gitignore 里）——母版是 render-icon.swift，谁跑谁重生成。
# 用法：./scripts/make-icon.sh
set -euo pipefail

ROOT="${0:A:h:h}"
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"

swift "$ROOT/scripts/render-icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$ROOT/Resources/AppIcon.icns"
print "已生成 $ROOT/Resources/AppIcon.icns"
