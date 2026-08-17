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

NOISE="/tmp/vinput-prompt-sweep-noise"
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

MODEL_FOLDER="null"
if [[ $# -gt 0 && "$1" != -* ]]; then
  MODEL_FOLDER="\"$ROOT/vendor/models/$1\""
  [[ -d "$ROOT/vendor/models/$1" ]] || { print -u2 "模型目录不存在：$1"; exit 1; }
  shift
fi

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
