#!/bin/zsh
# 云端翻译的真实联网体检。**会把三句写死的中文发到 Google 的服务器上。**
#
# 前置：把 API key 存进 Keychain（-w 后不带值，交互式输入，key 不进 shell
# 历史，也不进本仓库）：
#
#   security add-generic-password -a vInput -s vinput-gemini-api-key -w
#
# 用法：
#   ./scripts/gemini-e2e.sh                    # 默认 gemini-2.0-flash
#   ./scripts/gemini-e2e.sh gemini-2.5-flash   # 换模型
#
# 为什么走 xcodebuild 而不是 ./scripts/test.sh：整个测试目标链着 MLX，
# SwiftPM 命令行编译不了 mlx-swift 的 Metal 着色器，进程会崩在
# "Failed to load the default metallib"。见 docs/dev-dependencies.md。
# 这套用例自己不碰 MLX，但它和碰 MLX 的用例在同一个二进制里。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

# 模型名写进标记文件，测试从那里读——xcodebuild test 传不进环境变量
# （见 GeminiE2EGate），传进去的表现是整套用例被静默跳过而仍报
# TEST SUCCEEDED、退出码 0。
MODEL_NAME="${1:-}"
if [[ "$MODEL_NAME" == -* ]]; then
  MODEL_NAME=""
else
  shift 2>/dev/null || true
fi

# **这里刻意不检查 Keychain 里有没有 key。**
# 检查了就得决定「没有时怎么办」，而唯一说得通的答案是「照跑，让它红」：
# 「有没有配对 key」正是用户跑这套东西最想知道的事，脚本先一步 exit 1 的话
# 他得到的是脚本的判断，不是那条真实路径的判断。缺 key 时套件第一条用例会红，
# 并把存 key 的命令打出来。

MARKER="$ROOT/Testing/.gemini-e2e-enabled"
LOG="$(mktemp -t gemini-e2e)"
# 标记文件跑完就删，不留在工作区：留着的话随后一次 ./scripts/test.sh 会
# 试图真的联网，而单元测试不该联网。
trap 'rm -f "$MARKER" "$LOG"' EXIT
print "$MODEL_NAME" > "$MARKER"

# -only-testing 要的是**类型名**（GeminiE2ETests），不是 @Suite 的显示名
# （「云端翻译端到端」）。写显示名会匹配不到任何用例，**而 xcodebuild 照样
# 报 TEST SUCCEEDED、退出码 0**——本仓库最容易骗过人的那种假绿灯。
set +e
xcodebuild test \
    -scheme vInput \
    -destination "platform=OS X" \
    -derivedDataPath "${DERIVED_DATA:-$ROOT/.xcbuild}" \
    -only-testing:vInputTests/GeminiE2ETests \
    "$@" 2>&1 | tee "$LOG"
STATUS=${pipestatus[1]}
set -e

# **「一条用例都没真跑」必须是失败。**
#
# 门控套件有三种「一条都没跑」的方式，而三种都以 TEST SUCCEEDED、退出码 0
# 收场：-only-testing 写成了显示名；标记文件没写进去或路径变了；
# suite 被 .enabled(if:) 判成 false。
#
# **判据不能用那行汇总。** 2026-08-19 在 translate-e2e.sh 上实测过：
# suite 被 .enabled(if:) 跳过时，Swift Testing 照样打
# `✔ Test run with 5 tests in 1 suite passed`——**跳过的用例计进了那个 5**，
# 只有旁边一行 `➜ Suite "…" skipped.` 露了馅。汇总行数的是「被选中的用例」，
# 不是「跑过的用例」。所以这里数**逐条结果行**（`✔ Test "…"` / `✘ Test "…"`）：
# 跳过的用例不打这种行，匹配不到用例时更是一行都没有。
RAN=$(grep -cE '[✔✘] Test "' "$LOG" || true)
if [[ "$RAN" -eq 0 ]]; then
  print -u2 ""
  print -u2 "═══ 一条用例都没真跑，这不是成功 ═══"
  if grep -q 'Suite .*skipped' "$LOG"; then
    print -u2 "套件被 .enabled(if:) 跳过了：标记文件 $MARKER 没写进去？"
  else
    print -u2 "一条用例都没被选中：-only-testing 是不是写成了 @Suite 的显示名（要类型名）？"
  fi
  exit 1
fi

exit "$STATUS"
