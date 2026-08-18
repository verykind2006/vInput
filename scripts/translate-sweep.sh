#!/bin/zsh
# 拿真实模型跑多种语言的翻译对照，报告出到 Bench/translate-sweep.txt。
#
# **必须用 xcodebuild**：SwiftPM 命令行无法编译 mlx-swift 的 Metal 着色器，
# 产物里没有 default.metallib，用 ./scripts/test.sh 跑会崩在
# "Failed to load the default metallib"。同 scripts/e2e.sh，
# 见 docs/dev-dependencies.md。
#
# 用法：
#   ./scripts/translate-sweep.sh <模型目录名> [语言码…] [选项…]
#
#   ./scripts/translate-sweep.sh qwen2.5-7b-instruct-4bit
#   ./scripts/translate-sweep.sh qwen2.5-7b-instruct-4bit en --limit 3
#   ./scripts/translate-sweep.sh qwen2.5-7b-instruct-4bit en es --variant chinese-language-name
#
# 选项：
#   --limit N        每种语言只跑基准集前 N 条。全量一轮 26×6=156 次推理、
#                    几十分钟，探底先用 --limit 3。
#   --max-tokens N   覆盖 MLXTranslator.defaultMaxTokens。**调小是有意义的**：
#                    撞上限的表现是「静默返回半截译文、成功返回不报错」，
#                    把它调到必然撞上限、看报告里「疑似截断」是不是大面积
#                    亮起来，是证明那条判据不是空判据的唯一办法。
#   --variant NAME   提示词变体：english-language-name（生产默认）或
#                    chinese-language-name（对照）。名字写错会让整轮不跑，
#                    不会悄悄退回默认值——退回默认值就会写出一份标着
#                    「中文语言名」、实际跑的是英文语言名的报告。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

usage() {
  print -u2 "用法：$0 <模型目录名> [语言码…] [--limit N] [--max-tokens N] [--variant NAME]"
  print -u2 "可用模型："
  ls "$ROOT/Models" 2>/dev/null | sed 's/^/  /' >&2 || print -u2 "  （Models/ 不存在）"
  exit 1
}

[[ $# -lt 1 ]] && usage

MODEL_NAME="$1"; shift
# 模型目录是 Models/（大写 M，见 .gitignore 与 scripts/e2e.sh）。
# 本机文件系统大小写不敏感，写成 models/ 也能跑——但换台机器就找不到，
# 而找不到的表现是「模型目录不存在」，排查起来白花时间。
MODEL="$ROOT/Models/$MODEL_NAME"
if [[ ! -d "$MODEL" ]]; then
  print -u2 "模型目录不存在：$MODEL"
  usage
fi

LANGS=()
LIMIT=""
MAX_TOKENS=""
VARIANT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)       LIMIT="$2"; shift 2 ;;
    --max-tokens)  MAX_TOKENS="$2"; shift 2 ;;
    --variant)     VARIANT="$2"; shift 2 ;;
    -h|--help)     usage ;;
    -*)            print -u2 "未知选项：$1"; usage ;;
    *)             LANGS+=("$1"); shift ;;
  esac
done

# 默认跑全部六种拉丁字母语种（zh 不在其中：它的含义是「不翻译」）。
if [[ ${#LANGS[@]} -eq 0 ]]; then
  LANGS=(en es de pt fr it)
fi
TARGETS=$(printf '"%s",' "${LANGS[@]}"); TARGETS="${TARGETS%,}"

FIELDS="\"modelDirectory\":\"$MODEL\",\"targets\":[$TARGETS]"
[[ -n "$LIMIT" ]]      && FIELDS="$FIELDS,\"limit\":$LIMIT"
[[ -n "$MAX_TOKENS" ]] && FIELDS="$FIELDS,\"maxTokens\":$MAX_TOKENS"
[[ -n "$VARIANT" ]]    && FIELDS="$FIELDS,\"promptVariant\":\"$VARIANT\""

MARKER="$ROOT/Bench/.translate-sweep.json"
print "{$FIELDS}" > "$MARKER"
# 标记文件即门控，跑完必须删掉——留着会让下一次普通测试顺带跑一遍全量扫描。
trap 'rm -f "$MARKER"' EXIT

print "模型：$MODEL_NAME"
print "配置：{$FIELDS}"

# -only-testing 要的是**类型名**（TranslationSweepTests），不是 @Suite 的
# 显示名（「翻译扫描」）。同 scripts/e2e.sh 用 CorrectionE2ETests 而不是
# 「校正端到端」。写显示名会匹配不到任何用例，而 xcodebuild 照样报
# TEST SUCCEEDED、退出码 0——又一个假绿灯。
xcodebuild test \
    -scheme vInput \
    -destination "platform=OS X" \
    -derivedDataPath "${DERIVED_DATA:-$ROOT/.xcbuild}" \
    -only-testing:vInputTests/TranslationSweepTests
