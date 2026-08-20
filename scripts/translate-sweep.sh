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
#   --corpus PATH    换一份语料跑。默认 Bench/manifest.json（26 条标准文本，
#                    **一个 ASCII 数字都没有**）。Bench/translate-digits.json
#                    是补的数字语料，纯文本无录音，专门喂「数字丢失」那一列。
#                    路径可以是相对仓库根的。文件读不到会让整轮报错，
#                    不会悄悄退回 manifest。
#   --rewrite-numerals
#                    翻译前先做数词改写（ChineseNumerals.rewriteAsDigits，
#                    与生产 TranslationPipeline 同一个函数）。默认关——
#                    开关两轮对照才是「改写有没有用」的证据。
#   --variant NAME   提示词变体：english-language-name（生产默认）或
#                    chinese-language-name（对照）。名字写错会让整轮不跑，
#                    不会悄悄退回默认值——退回默认值就会写出一份标着
#                    「中文语言名」、实际跑的是英文语言名的报告。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

usage() {
  print -u2 "用法：$0 <模型目录名> [语言码…] [--limit N] [--max-tokens N] [--variant NAME] [--corpus PATH]"
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
CORPUS=""
REWRITE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)       LIMIT="$2"; shift 2 ;;
    --max-tokens)  MAX_TOKENS="$2"; shift 2 ;;
    --variant)     VARIANT="$2"; shift 2 ;;
    --corpus)      CORPUS="$2"; shift 2 ;;
    --rewrite-numerals) REWRITE=1; shift ;;
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
[[ -n "$REWRITE" ]]    && FIELDS="$FIELDS,\"rewriteNumerals\":true"
if [[ -n "$CORPUS" ]]; then
  # 存进标记文件的必须是绝对路径：测试进程的 cwd 不是仓库根（M4 踩过），
  # 相对路径会变成「文件不存在」。
  [[ "$CORPUS" != /* ]] && CORPUS="$ROOT/$CORPUS"
  if [[ ! -f "$CORPUS" ]]; then
    print -u2 "语料文件不存在：$CORPUS"
    exit 1
  fi
  FIELDS="$FIELDS,\"corpus\":\"$CORPUS\""
fi

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
LOG="$(mktemp -t translate-sweep)"
# 标记文件与日志一起收。上面那个 trap 只管标记文件，覆盖它要连标记文件一起写。
trap 'rm -f "$MARKER" "$LOG"' EXIT

set +e
xcodebuild test \
    -scheme vInput \
    -destination "platform=OS X" \
    -derivedDataPath "${DERIVED_DATA:-$ROOT/.xcbuild}" \
    -only-testing:vInputTests/TranslationSweepTests 2>&1 | tee "$LOG"
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
RAN=$(grep -cE '[✔✘] Test "' "$LOG" || true)
SKIPPED=$(grep -cE '(Test|Suite) ".*" skipped' "$LOG" || true)
if [[ "$RAN" -eq 0 || "$SKIPPED" -ne 0 ]]; then
  print -u2 ""
  print -u2 "═══ 门控没真的开：跑了 $RAN 条、跳过 $SKIPPED 条，这不是成功 ═══"
  if [[ "$SKIPPED" -ne 0 ]]; then
    print -u2 "套件被 .enabled(if:) 跳过了：标记文件 $MARKER 没对上。"
  else
    print -u2 "一条用例都没被选中：-only-testing 是不是写成了 @Suite 的显示名（要类型名）？"
  fi
  exit 1
fi

exit "$STATUS"
