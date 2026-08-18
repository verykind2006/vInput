#!/bin/zsh
# initial prompt 候选对照：一次加载模型，跑多个 prompt 候选 × 全基准集。
#
# 本想当临时脚手架用完即删，但 2026-08-17 那轮证明它值得留：九个候选扫下来
# 才发现「更短反而更好」，靠单个候选逐次试是试不出来的。prompt 迭代还会继续
# （M5-Backlog 记着几项），留着它下次省一天。
#
#   ./scripts/prompt-sweep.sh openai_whisper-large-v3-v20240930_turbo
#
# 候选写在 Bench/prompt-candidates.json 里，报告出到 Bench/prompt-sweep.txt。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

# ── 中间产物为什么不放 /tmp ───────────────────────────────────────────
# `/tmp` 会被系统定期清空，而这批合成音频是跨轮复用的缓存（同一批 wav
# 给 long-audio.sh / decode-sweep.sh 共用，重新合成要几分钟）。M5 期间
# `/tmp/vinput-bench` 被系统清掉过一次，端到端整片以 loadAudioFailed 失败，
# **看着像代码坏了**——排查它花掉的时间比换个目录贵得多。
#
# 顺带解决另一件事：`decode-sweep.sh` 会把真人录音 `Bench/audio/punct-03.wav`
# 补上静音再写出来，而 `/tmp` 的权限是 `drwxrwxrwt`（全局可读）。
# `~/Library/Caches` 是当前用户私有的。
CACHE_ROOT="$HOME/Library/Caches/vInput"
NOISE="$CACHE_ROOT/prompt-sweep-noise"
mkdir -p "$NOISE"

# 泄漏检测素材，与 scripts/bench.sh 里的做法一致（16k 单声道）。
# 30 秒底噪是最灵敏的一条：长窗口给了模型「必须说点什么」的空间，
# prompt 的原话就在这里漏出来。
noise_gen() {
  local name="$1" seconds="$2" amplitude="$3"
  [[ -s "$NOISE/$name.wav" ]] && return 0
  if [[ "$amplitude" == "0" ]]; then
    ffmpeg -v error -f lavfi -i "anullsrc=r=16000:cl=mono" -t "$seconds" \
      -c:a pcm_s16le "$NOISE/$name.wav"
  else
    ffmpeg -v error -f lavfi -i "anoisesrc=r=16000:c=white:a=$amplitude" -t "$seconds" \
      -ac 1 -c:a pcm_s16le "$NOISE/$name.wav"
  fi
}
noise_gen silence05  1.5 0
noise_gen silence30 30   0
noise_gen noise02    2   0.002
noise_gen noise30   30   0.002

MODEL_NAME=""
if [[ $# -gt 0 && "$1" != -* ]]; then
  MODEL_NAME="$1"
  shift
fi

# 与 bench-run.sh 同一条规则：不带参数时取应用会用的默认模型，而不是写
# null。写 null 会让 `WhisperKitTranscriber(modelFolder: nil)` 落到 `"base"`
# 并联网下载它——扫九个候选就是九遍 base，结论与产品无关（独立验收 F1）。
if [[ -z "$MODEL_NAME" ]]; then
  MODEL_NAME="$("$ROOT/scripts/default-model.sh")"
  print "未指定模型，用应用的默认模型：$MODEL_NAME"
fi
[[ -d "$ROOT/vendor/models/$MODEL_NAME" ]] || {
  print -u2 "模型目录不存在：$ROOT/vendor/models/$MODEL_NAME"; exit 1
}
MODEL_FOLDER="\"$ROOT/vendor/models/$MODEL_NAME\""

python3 - "$MODEL_FOLDER" "$NOISE" <<'PY' > Bench/.prompt-sweep.json
import json, sys
model = json.loads(sys.argv[1])
candidates = json.load(open("Bench/prompt-candidates.json"))
json.dump({
    "modelFolder": model,
    "noiseDir": sys.argv[2],
    "leakRepeats": 4,
    "candidates": candidates,
}, sys.stdout, ensure_ascii=False)
PY

trap 'rm -f "$ROOT/Bench/.prompt-sweep.json"' EXIT

./scripts/test.sh --filter PromptSweepTests "$@"
