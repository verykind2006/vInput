#!/bin/zsh
# 用基准集跑一次对照，输出三层指标。
#
# 用法：
#   ./scripts/bench-run.sh                                    # 用应用的默认模型
#   ./scripts/bench-run.sh openai_whisper-large-v3            # 指定模型
#   ./scripts/bench-run.sh openai_whisper-large-v3 -v         # 余下参数透传给 test.sh
#
# 报告写到 Bench/report.txt（最近一次）与 Bench/reports/<时间戳>-<模型>.txt
# （历次归档），同时打印到终端。两次运行的对比就是 diff 两份归档。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

# 第一个参数是模型名，**必须 shift 掉再透传余下参数**：直接把 "$@" 交给
# test.sh 会连模型名一起传下去，swift test 会把它当成测试名过滤器，
# 结果一条用例都不跑却报成功。
#
# 以 - 开头的第一个参数不当模型名——那是给 test.sh 的选项。
MODEL_NAME=""
if [[ $# -gt 0 && "$1" != -* ]]; then
  MODEL_NAME="$1"
  shift
fi

# 不带参数时解析出**应用会用的默认模型**（ModelPreference 的第一个本地已
# 存在项），而不是写 `{"modelFolder":null}`。
#
# 此前写 null，测试据此构造 `WhisperKitTranscriber(modelFolder: nil)`，落到
# `modelName` 的默认值 `"base"`——联网下载一个产品从不使用的模型跑完全集，
# 报告头只写「模型：默认」（2026-08-17 独立验收 F1）。**宁可拒绝执行也不
# 静默换模型**：跑一遍要几分钟，而错的报告会被拿去做决策。
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
print "{\"modelFolder\":\"$MODEL_FOLDER\"}" > Bench/.run-config.json

# 标记文件即门控，跑完必须删掉——留着会让下一次普通 ./scripts/test.sh
# 顺带跑一遍全量对照（几分钟），而且是在人没预期的时候。
trap 'rm -f "$ROOT/Bench/.run-config.json"' EXIT

./scripts/test.sh --filter BenchRunnerTests "$@"
