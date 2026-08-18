#!/bin/zsh
# 长音频截断对照：同一段话越录越长，看转写从多长开始丢字、丢多少。
#
#   ./scripts/long-audio.sh                                     # 用应用的默认模型
#   ./scripts/long-audio.sh openai_whisper-large-v3-v20240930_turbo
#   ./scripts/long-audio.sh -- -v                               # 余下参数透传给 test.sh
#
# 存在的理由（M6 ⓪）：2026-08-17 真机上 31.4 秒的录音只出 81 字、断在半句上，
# 而同一批 8–19 秒的录音全部完整。基准集 23 条里最长的只有 15–30 秒，
# **30 秒以上零覆盖**，查不出这个问题。这里用 TTS 补上那段盲区——文本已知，
# 所以丢了多少能精确算出来，不必等用户再录一次。
#
# **用字数比而不是绝对秒数判断**：say -v Tingting 的语速约 4.0 字/秒，
# 与用户实测的 3.1–4.6 字/秒同一量级，但停顿分布与真人不同，VAD 分块的
# 位置不会一样。能比的是「参考多少字、实际出多少字」。
#
# 语料在 Bench/long-audio-corpus.json，报告出到 Bench/long-audio.txt。
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
AUDIO="$CACHE_ROOT/long-audio"
mkdir -p "$AUDIO"

MODEL_NAME=""
if [[ $# -gt 0 && "$1" != -* ]]; then
  MODEL_NAME="$1"
  shift
fi
[[ "${1:-}" == "--" ]] && shift

# 与 bench-run.sh / prompt-sweep.sh 同一条规则：不带参数时取应用会用的默认
# 模型，而不是写 null。写 null 会让 `WhisperKitTranscriber(modelFolder: nil)`
# 落到 `"base"` 并联网下载它，跑出来的结论与产品无关（独立验收 F1）。
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

# 合成音频 + 写门控标记文件。两件事放在一起，是因为标记文件里要写每段的
# 实际时长与参考文本——分开写就会有一份手抄的时长表，迟早与音频对不上。
python3 - "$AUDIO" "$MODEL_FOLDER" <<'PY' > Bench/.long-audio.json
import json
import os
import subprocess
import sys
import wave

audio_dir, model_folder = sys.argv[1], sys.argv[2]
corpus = json.load(open("Bench/long-audio-corpus.json", encoding="utf-8"))
voice = corpus["voice"]

cases = []
for group in corpus["groups"]:
    for case in group["cases"]:
        text = "".join(group["segments"][: case["segments"]])
        wav = os.path.join(audio_dir, f"{case['id']}.wav")
        if not os.path.exists(wav) or os.path.getsize(wav) == 0:
            print(f"生成 {case['id']}.wav", file=sys.stderr)
            aiff = wav.replace(".wav", ".aiff")
            # rate 为 null 时不传 -r，用 say 的默认语速（中文约 4 字/秒）。
            rate = ["-r", str(group["rate"])] if group.get("rate") else []
            subprocess.run(["say", "-v", voice] + rate + ["-o", aiff, text], check=True)
            subprocess.run(
                ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav],
                check=True,
            )
            os.remove(aiff)
        with wave.open(wav) as handle:
            seconds = handle.getnframes() / handle.getframerate()
        cases.append(
            {
                "id": case["id"],
                "group": group["id"],
                "wav": wav,
                "text": text,
                "seconds": seconds,
                # 间歇性失败的组要重复采样，见 LongAudioTests 的类型注释。
                # 用例可以覆盖组的次数——真正会翻车的只有一条，全组一起
                # 拉高次数就是拿十几分钟去换一个已知不变的绿灯。
                "repeats": case.get("repeats", group.get("repeats", 1)),
            }
        )

# prompt 变体。**这一组直接检验「224 token 预算被 prompt 吃掉」的假设**：
# 三个变体只差 prompt 长度，音频完全相同。prompt 为 null 表示用生产默认
# （WhisperKitTranscriber.punctuationPrompt），空串表示完全不挂 prompt。
p0 = next(
    c["prompt"]
    for c in json.load(open("Bench/prompt-candidates.json", encoding="utf-8"))
    if c["name"].startswith("P0")
)
variants = [
    {"name": "P6 生产默认（124 字）", "prompt": None},
    {"name": "P0 旧版（63 字）", "prompt": p0},
    {"name": "不挂 prompt", "prompt": ""},
]

json.dump(
    {"modelFolder": model_folder, "cases": cases, "variants": variants},
    sys.stdout,
    ensure_ascii=False,
)
PY

# 标记文件即门控，跑完必须删掉——留着会让下一次普通 ./scripts/test.sh
# 顺带跑一遍全部变体（好几分钟），而且是在人没预期的时候。
trap 'rm -f "$ROOT/Bench/.long-audio.json"' EXIT

./scripts/test.sh --filter LongAudioTests "$@"
