#!/bin/zsh
# 运行测试。参数会原样透传给 swift test，例如：
#   ./scripts/test.sh --filter AudioBuffer
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

# Swift Testing 的 Testing.framework 与 lib_TestingInterop.dylib 在
# 纯 Command Line Tools 环境下不在默认的 framework 搜索路径和 rpath 中
# （完整 Xcode 会自动配置，CLT 不会），导致 `swift test` 报
# "no such module 'Testing'"。这里检测到该情形时补上路径。
#
# 装了完整 Xcode 时 xcode-select -p 指向 Xcode.app，下面的目录不存在，
# EXTRA 保持为空，等价于原生的 swift test。
DEV_DIR="$(xcode-select -p)"
FRAMEWORKS="$DEV_DIR/Library/Developer/Frameworks"
LIBS="$DEV_DIR/Library/Developer/usr/lib"

EXTRA=()
if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
  EXTRA=(
    -Xswiftc -F -Xswiftc "$FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$LIBS"
  )
fi

exec swift test "${EXTRA[@]}" "$@"
