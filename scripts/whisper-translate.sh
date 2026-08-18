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

print "{\"modelFolder\":\"$MODEL_FOLDER\"}" > Bench/.whisper-translate.json
# 标记文件即门控，跑完必须删掉——留着会让下一次普通 ./scripts/test.sh
# 顺带跑一遍全量扫描，而且是在人没预期的时候。
trap 'rm -f "$ROOT/Bench/.whisper-translate.json"' EXIT

./scripts/test.sh --filter WhisperTranslateSweepTests "$@"
