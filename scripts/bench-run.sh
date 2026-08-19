#!/bin/zsh
# 用基准集跑一次对照，输出三层指标。
#
# 用法：
#   ./scripts/bench-run.sh                                    # 用应用的默认模型
#   ./scripts/bench-run.sh openai_whisper-large-v3            # 指定模型
#   ./scripts/bench-run.sh openai_whisper-large-v3 -v         # 余下参数透传给 test.sh
#   ./scripts/bench-run.sh openai_whisper-large-v3 en         # 顺带跑翻译段
#   ./scripts/bench-run.sh openai_whisper-large-v3 en --translate-model qwen2.5-7b-instruct-4bit
#
# **第二个参数是目标语言码，可选。不给它时，这个脚本与从前逐字一样**：
# 标记文件里只写 modelFolder，报告里没有任何与翻译有关的东西。
# 给了它才多跑一段：每条转写输出再译一遍，逐条打印残留汉字 / 术语保留 /
# 数字丢失 / 长度比，报告尾部给汇总。
#
# 语言码不在这里校验，**故意的**：可用语言在 TranslationTarget 里，脚本里
# 抄一份迟早对不上（同 scripts/default-model.sh 不抄 ModelPreference 的理由）。
# 认不出来的语言码由 BenchTranslationSection.make 在跑转写**之前**抛掉。
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

# 第二个位置参数＝目标语言码。同样只认不以 - 开头的。
TRANSLATE_TO=""
if [[ $# -gt 0 && "$1" != -* ]]; then
  TRANSLATE_TO="$1"
  shift
fi

# 翻译用的本地模型。默认值是 M8 第 0 步实测定下来的那个（62 条译文上 4B
# 残留汉字 0，7B 有 57 个残留汉字分布在 8 条上，而 4B 还快一到三倍），
# 与 scripts/translate-e2e.sh 的默认值保持一致。
TRANSLATE_MODEL="qwen3-4b-instruct-2507-4bit"
REST=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --translate-model) TRANSLATE_MODEL="$2"; shift 2 ;;
    *)                 REST+=("$1"); shift ;;
  esac
done

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
if [[ -z "$TRANSLATE_TO" ]]; then
  print "{\"modelFolder\":\"$MODEL_FOLDER\"}" > Bench/.run-config.json
else
  # 翻译模型目录是 Models/（**大写 M**，见 .gitignore 与 scripts/e2e.sh）。
  # 本机文件系统大小写不敏感，写成 models/ 也能跑——换台机器就找不到。
  TRANSLATE_FOLDER="$ROOT/Models/$TRANSLATE_MODEL"
  if [[ ! -d "$TRANSLATE_FOLDER" ]]; then
    print -u2 "翻译模型目录不存在：$TRANSLATE_FOLDER"
    print -u2 "可用的翻译模型："
    ls "$ROOT/Models" >&2 2>/dev/null | sed 's/^/  /' >&2 || print -u2 "  （Models/ 不存在）"
    exit 1
  fi
  print "{\"modelFolder\":\"$MODEL_FOLDER\",\"translateTo\":\"$TRANSLATE_TO\",\"translationModelFolder\":\"$TRANSLATE_FOLDER\"}" \
    > Bench/.run-config.json
fi

# 标记文件即门控，跑完必须删掉——留着会让下一次普通 ./scripts/test.sh
# 顺带跑一遍全量对照（几分钟），而且是在人没预期的时候。
trap 'rm -f "$ROOT/Bench/.run-config.json"' EXIT

if [[ -z "$TRANSLATE_TO" ]]; then
  # **不带语言码的路径与从前逐字一致**：SwiftPM 跑得动 WhisperKit，
  # 而它比 xcodebuild 快得多。
  ./scripts/test.sh --filter BenchRunnerTests "${REST[@]}"
  exit $?
fi

# 带翻译时**必须走 xcodebuild**：SwiftPM 命令行编译不出 mlx-swift 的 Metal
# 着色器，产物里没有 default.metallib，MLXTranslator 一初始化就崩
# （同 scripts/translate-e2e.sh / translate-sweep.sh，见 docs/dev-dependencies.md）。
print "翻译段：$TRANSLATE_TO · $TRANSLATE_MODEL（走 xcodebuild，MLX 需要）"

# -only-testing 要的是**类型名**（BenchRunnerTests），不是 @Suite 的显示名
# （「基准集对照」）。写显示名会匹配不到任何用例，而 xcodebuild 照样报
# TEST SUCCEEDED、退出码 0。
LOG="$(mktemp -t bench-run)"
trap 'rm -f "$ROOT/Bench/.run-config.json" "$LOG"' EXIT
set +e
xcodebuild test \
    -scheme vInput \
    -destination "platform=OS X" \
    -derivedDataPath "${DERIVED_DATA:-$ROOT/.xcbuild}" \
    -only-testing:vInputTests/BenchRunnerTests \
    "${REST[@]}" 2>&1 | tee "$LOG"
STATUS=${pipestatus[1]}
set -e

# **「一条用例都没真跑」必须是失败。**
#
# 判据是逐条结果行，不是那行汇总：suite 被 `.enabled(if:)` 跳过时 Swift
# Testing 照样打 `Test run with N tests … passed`，**跳过的用例计进那个 N**
# （2026-08-19 实测，见 scripts/translate-e2e.sh 里的同一段）。
RAN=$(grep -cE '[✔✘] Test "' "$LOG" || true)
if [[ "$RAN" -eq 0 ]]; then
  print -u2 ""
  print -u2 "═══ 一条用例都没真跑，这不是成功 ═══"
  if grep -q 'Suite .*skipped' "$LOG"; then
    print -u2 "套件被 .enabled(if:) 跳过了：标记文件 Bench/.run-config.json 没对上。"
  else
    print -u2 "一条用例都没被选中：-only-testing 是不是写成了 @Suite 的显示名（要类型名）？"
  fi
  exit 1
fi

exit "$STATUS"
