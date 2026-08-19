#!/bin/zsh
# 拿 Whisper 自带的 task = .translate 跑基准集录音，报告出到
# Bench/whisper-translate.txt。
#
# **它测的是「翻译层能不能不要」**：Whisper 的解码器本身能直接从语音解出
# 英文，够用的话就一个额外模型都不加载、一次额外推理都不做。
# **它只能译成英文**，是模型的固有限制，最多解决六种目标语言里的一种。
#
# 用法：
#   ./scripts/whisper-translate.sh                      # 用应用的默认模型
#   ./scripts/whisper-translate.sh openai_whisper-base
#
# 转写层不碰 MLX，所以可以走 ./scripts/test.sh（SwiftPM）——
# 与 bench-run.sh 相同，与 translate-sweep.sh 不同。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

MODEL_NAME=""
if [[ $# -gt 0 && "$1" != -* ]]; then
  MODEL_NAME="$1"
  shift
fi

# 不带参数时解析出**应用会用的默认模型**，而不是让 WhisperKitTranscriber
# 落到 modelName 的默认值 "base"——那会联网下载一个产品从不使用的模型跑完
# 全集，而报告头看不出来（2026-08-17 独立验收 F1，见 scripts/bench-run.sh）。
if [[ -z "$MODEL_NAME" ]]; then
  MODEL_NAME="$("$ROOT/scripts/default-model.sh")"
  print "未指定模型，用应用的默认模型：$MODEL_NAME"
fi

MODEL_FOLDER="$ROOT/vendor/models/$MODEL_NAME"
if [[ ! -d "$MODEL_FOLDER" ]]; then
  print -u2 "模型目录不存在：$MODEL_FOLDER"
  print -u2 "可用的模型："
  ls "$ROOT/vendor/models" >&2 2>/dev/null || print -u2 "  （vendor/models 不存在）"
  exit 1
fi

MARKER="$ROOT/Bench/.whisper-translate.json"
print "{\"modelFolder\":\"$MODEL_FOLDER\"}" > "$MARKER"
LOG="$(mktemp -t whisper-translate)"
# 标记文件即门控，跑完必须删掉——留着会让下一次普通 ./scripts/test.sh
# 顺带跑一遍全量扫描，而且是在人没预期的时候。
trap 'rm -f "$MARKER" "$LOG"' EXIT

set +e
./scripts/test.sh --filter WhisperTranslateSweepTests "$@" 2>&1 | tee "$LOG"
STATUS=${pipestatus[1]}
set -e

# **「一条用例都没真跑」必须是失败**，判据有两条，缺一条都能被骗过。
#
# ① 数**逐条结果行**（`✔ Test "…"` / `✘ Test "…"`），不数那行汇总：
#    suite 被 `.enabled(if:)` 跳过时 Swift Testing 照样打
#    `✔ Test run with N tests … passed`，**跳过的用例计进那个 N**、退出码 0
#    （2026-08-19 实测，原文见 scripts/translate-e2e.sh 里的同一段）。
#
# ② **一条 skipped 都不许有。** 只有 ① 的话，凡是与门控套件同处一个源文件的
#    那几条普通用例会把计数顶上去——2026-08-19 实测：
#    `./scripts/test.sh --filter WhisperTranslateSweepTests` 在标记文件没写对
#    （被门控跳过）时打出 `➜ Suite "Whisper 直译对照" skipped.`，
#    而同文件的 `WhisperTranslateGateTests` 照跑 3 条、逐条结果行 3 行、
#    退出码 0——**只数 ① 的护栏在这里是绿的**。`swift test --filter` 选的是
#    整个源文件，不是那一个类型。门控脚本里跑的东西本就一条都不该被跳过，
#    所以这条判据没有误报空间。
#
#    **判据里那对引号是必需的。** Swift Testing 的跳过行长这样：
#    `➜ Suite "翻译扫描" skipped.`。不要引号的话 xcodebuild 那几万行构建日志
#    随时能撞进来——2026-08-19 实测 e2e 的日志里就有一行
#    `appintentsmetadataprocessor … warning: Metadata extraction skipped.`，
#    它这次恰好不含 Test/Suite，下次换个工具名就未必了。
RAN=$(grep -cE '[✔✘] Test "' "$LOG" || true)
SKIPPED=$(grep -cE '(Test|Suite) ".*" skipped' "$LOG" || true)
if [[ "$RAN" -eq 0 || "$SKIPPED" -ne 0 ]]; then
  print -u2 ""
  print -u2 "═══ 门控没真的开：跑了 $RAN 条、跳过 $SKIPPED 条，这不是成功 ═══"
  if [[ "$SKIPPED" -ne 0 ]]; then
    print -u2 "套件被 .enabled(if:) 跳过了：标记文件 $MARKER 没写进去，或模型目录没对上。"
  else
    print -u2 "一条用例都没被选中：--filter 是不是写错了类型名？"
  fi
  exit 1
fi

exit "$STATUS"
