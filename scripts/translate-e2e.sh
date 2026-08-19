#!/bin/zsh
# 翻译层的真实模型端到端体检。
#
# 必须走 xcodebuild：SwiftPM 命令行无法编译 mlx-swift 的 Metal 着色器，
# 用 ./scripts/test.sh 跑会直接崩在 "Failed to load the default metallib"，
# 而单元测试照常通过——M4 期间踩过。见 docs/dev-dependencies.md。
#
# 用法：
#   ./scripts/translate-e2e.sh                            # 默认 4B
#   ./scripts/translate-e2e.sh qwen2.5-7b-instruct-4bit   # 换模型做对照
#
# 默认模型是 4B 而不是 7B，这是 M8 第 0 步实测定的：62 条译文上 4B 残留
# 汉字 0，7B 有 57 个残留汉字分布在 8 条上，而 4B 还快一到三倍。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

# 模型名可由第一个参数指定。名字写进标记文件，测试从那里读——xcodebuild
# test 传不进环境变量（见 TranslationE2EGate），传进去的表现是整套用例被
# 静默跳过而仍报 TEST SUCCEEDED、退出码 0。
MODEL_NAME="${1:-qwen3-4b-instruct-2507-4bit}"
if [[ "$MODEL_NAME" == -* ]]; then
  MODEL_NAME="qwen3-4b-instruct-2507-4bit"
else
  shift 2>/dev/null || true
fi

# 模型目录是 Models/（**大写 M**）。本机文件系统大小写不敏感，写成
# models/ 也能跑，但换台机器就找不到——同 scripts/translate-sweep.sh 的注记。
MODEL="$ROOT/Models/$MODEL_NAME"
if [[ ! -d "$MODEL" ]]; then
  print -u2 "翻译模型不在默认位置：$MODEL"
  print -u2 "可用模型："
  ls "$ROOT/Models" 2>/dev/null | sed 's/^/  /' >&2 || print -u2 "  （Models/ 不存在）"
  exit 1
fi

# 标记文件是门控开关。跑完由 trap 删掉，不留在工作区——留着的话，随后一次
# ./scripts/test.sh 会试图在 SwiftPM 下跑这套 MLX 用例，整个进程崩在
# "Failed to load the default metallib"。
MARKER="$ROOT/Testing/.translate-e2e-enabled"
LOG="$(mktemp -t translate-e2e)"
trap 'rm -f "$MARKER" "$LOG"' EXIT
print "$MODEL_NAME" > "$MARKER"

# -only-testing 要的是**类型名**（TranslationE2ETests），不是 @Suite 的显示名
# （「翻译端到端」）。写显示名会匹配不到任何用例，**而 xcodebuild 照样报
# TEST SUCCEEDED、退出码 0**——本仓库最容易骗过人的那种假绿灯。
set +e
xcodebuild test \
    -scheme vInput \
    -destination "platform=OS X" \
    -derivedDataPath "${DERIVED_DATA:-$ROOT/.xcbuild}" \
    -only-testing:vInputTests/TranslationE2ETests \
    "$@" 2>&1 | tee "$LOG"
STATUS=${pipestatus[1]}
set -e

# **「一条用例都没真跑」必须是失败。**
#
# 这一套是门控套件，默认跳过。它有三种「一条都没跑」的方式，而**三种都以
# TEST SUCCEEDED、退出码 0 收场**：
#
#   1. -only-testing 写成了 @Suite 的显示名，匹配不到任何用例；
#   2. 标记文件没写进去（或路径变了），`.enabled(if:)` 判成 false；
#   3. Models/ 下的目录名对不上，`isEnabled` 里那半个条件不成立。
#
# 一个永远跳过的门控套件是本仓库头号缺陷类型的终极形态——它连断言都不用写
# 就能永远绿。所以这里不看 xcodebuild 的退出码，自己数「真的跑完了几条」。
#
# **判据不能用那行汇总。** 第一版写的是 `Test run with [1-9][0-9]* test`，
# 2026-08-19 实测被 ② 打脸：suite 被 `.enabled(if:)` 跳过时，Swift Testing
# 照样打 `✔ Test run with 5 tests in 1 suite passed after 0.001 seconds`
# ——**跳过的用例计进了那个 5**，只有旁边一行 `➜ Suite "翻译端到端" skipped.`
# 露了馅。汇总行数的是「被选中的用例」，不是「跑过的用例」。
#
# 改成数逐条结果行（`✔ Test "…"` / `✘ Test "…"`）：跳过的用例不打这种行，
# 匹配不到用例时更是一行都没有。失败的用例照样计入——那时 STATUS 非 0，
# 由下面那行 exit 如实报出，不该被误报成「没跑」。
RAN=$(grep -cE '[✔✘] Test "' "$LOG" || true)
if [[ "$RAN" -eq 0 ]]; then
  print -u2 ""
  print -u2 "═══ 一条用例都没真跑，这不是成功 ═══"
  if grep -q 'Suite .*skipped' "$LOG"; then
    print -u2 "套件被 .enabled(if:) 跳过了：标记文件 $MARKER 或模型目录 $MODEL 没对上。"
  else
    print -u2 "一条用例都没被选中：-only-testing 是不是写成了 @Suite 的显示名（要类型名）？"
  fi
  exit 1
fi

exit "$STATUS"
