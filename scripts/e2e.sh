#!/bin/zsh
# 真实模型的端到端体检。
#
# 必须走 xcodebuild：SwiftPM 命令行无法编译 mlx-swift 的 Metal 着色器，
# 用 ./scripts/test.sh 跑会直接崩在 "Failed to load the default metallib"。
# 见 docs/dev-dependencies.md。
#
# 用法：./scripts/e2e.sh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

# 模型名可由第一个参数指定，缺省用 4B。名字写进标记文件，测试从那里读
# ——xcodebuild test 传不进环境变量（见 CorrectionE2ETests 的 E2EGate）。
MODEL_NAME="${1:-qwen3-4b-instruct-2507-4bit}"
[[ "$MODEL_NAME" == -* ]] && MODEL_NAME="qwen3-4b-instruct-2507-4bit" || shift 2>/dev/null || true
MODEL="$ROOT/Models/$MODEL_NAME"
if [[ ! -d "$MODEL" ]]; then
  print -u2 "校正模型不在默认位置：$MODEL"
  print -u2 "端到端需要真实模型，先下载再跑。"
  exit 1
fi

# 标记文件是门控开关。用它而非环境变量：xcodebuild test 不把父进程环境
# 传给测试运行器，实测会让整个套件被静默跳过而仍报 TEST SUCCEEDED。
MARKER="$ROOT/Testing/.e2e-enabled"
print "$MODEL_NAME" > "$MARKER"
trap 'rm -f "$MARKER"' EXIT

# 跑一套门控用例，并检查它**真的跑了**。判据见函数体里那两条。
#
# **两次 xcodebuild 各查一次。** 只查一次的话另一次照样能静默跳过，而这个
# 脚本里 `SharedModelContainerE2ETests` 是**唯一**验证「校正与翻译真的共用
# 同一份 2 GB 权重」的东西——16 GB 的 MacBook Air 上省不省得下那 2 GB 全靠它，
# 而验收文档已经把「共用同一份权重」当成既成事实写进依据。
run_gate() {
  local suite="$1"
  # **必须 shift。** 不 shift 的话 `"$@"` 里第一个还是套件名，会被原样交给
  # xcodebuild，它把它当成 build action → `Unknown build action`。
  shift
  local log
  log="$(mktemp -t e2e)"
  set +e
  xcodebuild test \
      -scheme vInput \
      -destination "platform=OS X" \
      -derivedDataPath "${DERIVED_DATA:-$ROOT/.xcbuild}" \
      -only-testing:"vInputTests/$suite" \
      "$@" 2>&1 | tee "$log"
  # 变量不能叫 status：zsh 里 `status` 是 `$?` 的只读别名，`local status=`
  # 会直接报 "read-only variable: status"。
  local gate_status=${pipestatus[1]}
  set -e

  # 判据两条，缺一条都能被骗过：
  # ① 数**逐条结果行**，不数那行汇总——suite 被 `.enabled(if:)` 跳过时
  #    Swift Testing 照样打 `✔ Test run with N tests … passed`，
  #    **跳过的用例计进那个 N**、退出码 0（原文见 scripts/translate-e2e.sh）；
  # ② **一条 skipped 都不许有**——只有 ① 的话，与门控套件同处一个源文件的
  #    普通用例会把计数顶上去（2026-08-19 实测，见 scripts/whisper-translate.sh
  #    里那一段）。门控脚本里跑的东西本就一条都不该被跳过。
  #    判据里那对引号是必需的：xcodebuild 的构建日志里有 "Metadata extraction
  #    skipped." 这类行，不限定成 Swift Testing 的 `Suite "…" skipped` 会误伤。
  local ran skipped
  ran=$(grep -cE '[✔✘] Test "' "$log" || true)
  skipped=$(grep -cE '(Test|Suite) ".*" skipped' "$log" || true)
  if [[ "$ran" -eq 0 || "$skipped" -ne 0 ]]; then
    print -u2 ""
    print -u2 "═══ $suite 门控没真的开：跑了 $ran 条、跳过 $skipped 条，这不是成功 ═══"
    if [[ "$skipped" -ne 0 ]]; then
      print -u2 "套件被 .enabled(if:) 跳过了：标记文件 $MARKER 或模型目录 $MODEL 没对上。"
    else
      print -u2 "一条用例都没被选中：-only-testing 是不是写成了 @Suite 的显示名（要类型名）？"
    fi
    rm -f "$log"
    exit 1
  fi
  rm -f "$log"
  [[ "$gate_status" -eq 0 ]] || exit "$gate_status"
}

run_gate CorrectionE2ETests "$@"

# 共用体检单独起一个进程跑，**不能和上面并在一次 xcodebuild 里**。
# 它量的是「第二层加载时进程物理内存涨了多少」，而 Swift Testing 默认跨
# suite 并行——校正那套同时在加载它自己的 2 GB，量出来的增量就成了别人的。
run_gate SharedModelContainerE2ETests "$@"
