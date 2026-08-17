#!/bin/zsh
# 打印「应用会用的默认 Whisper 模型」目录名。bench 类脚本不带模型参数时用它。
#
# 存在的理由（2026-08-17 独立验收 F1）：`bench-run.sh` 不带参数时曾写
# `{"modelFolder":null}`，`BenchRunnerTests` 据此构造
# `WhisperKitTranscriber(modelFolder: nil)`，落到 `modelName` 的默认值
# `"base"`——WhisperKit 会**联网下载 base** 跑完整个基准集，而应用的默认是
# turbo。报告头当时只写「模型：默认」，事后无从发现跑的是什么。
# 偏偏 M5 计划把不带参数的 `./scripts/bench-run.sh` 写成了验收命令，
# 照文档执行的人拿到的是一份与产品无关的报告，且无任何提示。
#
# **偏好顺序从 ModelPreference.swift 解析，不在脚本里抄一份。** 抄一份就会
# 像 `Bench.swift` 里那份 prompt 副本一样漂掉（同一天的 F2 正是这么发生的：
# 注释写着「改一处要改两处」，两次都只改了一处）。
#
# 解析不出来时**宁可失败也不猜**：静默换一个模型跑出来的报告是负资产。
set -euo pipefail

ROOT="${0:A:h:h}"
MODELS="$ROOT/vendor/models"
SOURCE="$ROOT/Sources/vInput/Transcribe/ModelPreference.swift"

NAME="$(python3 - "$SOURCE" "$MODELS" <<'PY'
import os
import re
import sys

source, models = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
body = re.search(r"preferredModels\s*=\s*\[(.*?)\]", text, re.S)
if body is None:
    sys.exit(f"从 {source} 里解析不出 preferredModels，它的写法变了？")
# 应用的选法就是「按偏好顺序取第一个本地已存在的」，这里必须照抄这条规则，
# 见 ModelPreference 的注释。
for name in re.findall(r'"([^"]+)"', body.group(1)):
    if os.path.isdir(os.path.join(models, name)):
        print(name)
        break
PY
)"

if [[ -z "$NAME" ]]; then
  print -u2 "ModelPreference 里的模型在 $MODELS 下一个都没有，定不出默认模型。"
  print -u2 "先拉一个：./scripts/fetch-model.sh openai_whisper-large-v3-v20240930_turbo"
  print -u2 "当前可用的模型："
  ls "$MODELS" >&2 2>/dev/null || print -u2 "  （vendor/models 不存在）"
  exit 1
fi

print "$NAME"
