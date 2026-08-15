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

xcodebuild test \
    -scheme vInput \
    -destination "platform=OS X" \
    -derivedDataPath "${DERIVED_DATA:-$ROOT/.xcbuild}" \
    -only-testing:vInputTests/CorrectionE2ETests \
    "$@"
