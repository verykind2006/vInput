#!/bin/zsh
# 解码参数变体的三维对照：长语音丢字 × 静音幻觉 × 正常语料 CER。
#
#   ./scripts/decode-sweep.sh                                     # 用应用的默认模型
#   ./scripts/decode-sweep.sh openai_whisper-large-v3-v20240930_turbo
#   ./scripts/decode-sweep.sh --quick                             # 砍掉基准集那一维，只看前两维
#   ./scripts/decode-sweep.sh --only 1,7                          # 只跑编号 1 与 7 两个变体
#   ./scripts/decode-sweep.sh -- -v                               # 余下参数透传给 test.sh
#
# 存在的理由（M6 ⓪ 选型）：那个「超过 30 秒的语音被静默截断」的 bug，成因
# 已经定位（VAD 把切点落在句中 → 那一块首 token logProb −1.86 低于
# −1.5 阈值 → 六档退火全不达标 → decodeWithFallback 返回最后一次而非最好的
# 一次 → 整块 15.6 秒变空）。**最对症的修法在 vendor/WhisperKit 里，不能动**
# （vendor 在 .gitignore 里，改了不进版本库）。剩下能从我们自己代码设的只有
# DecodingOptions 上那几个旋钮，而它们**动的全是防幻觉机制**。
#
# 所以这个脚本的重点不是「哪个变体能治丢字」——那一列很容易好看——
# 而是**同一轮里把代价也量出来**：静音会不会开始冒话、日常那 90% 的录音
# 会不会退化。只报一个维度的结论是不可接受的。
#
# 语料：长音频复用 Bench/long-audio-corpus.json（与 long-audio.sh 同一份，
# 同一批 wav 缓存），静音素材见下面 noise_gen 那一段，基准集是 Bench/manifest.json。
# 报告出到 Bench/decode-sweep.txt，并留一份带时间戳的到 Bench/reports/。
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
AUDIO="$CACHE_ROOT/long-audio"          # 与 long-audio.sh 共用，避免重复合成
NOISE="$CACHE_ROOT/decode-sweep-noise"
mkdir -p "$AUDIO" "$NOISE"

RUN_BENCH=1
MODEL_NAME=""
export DECODE_SWEEP_ONLY=""
if [[ $# -gt 0 && "$1" != -* ]]; then
  MODEL_NAME="$1"
  shift
fi
SCALING=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)   RUN_BENCH=0; shift ;;
    --only)    DECODE_SWEEP_ONLY="$2"; shift 2 ;;
    --scaling) SCALING=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
export DECODE_SWEEP_SCALING="$SCALING"

# 与 bench-run.sh / long-audio.sh 同一条规则：不带参数时取应用会用的默认
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

# 静音与底噪素材。前四段与 prompt-sweep.sh 完全一致（16k 单声道），
# 好让本轮的「非空次数」能直接对上 M5 那轮的「16 次静音零非空」。
#
# **另外三段是本轮新造的，理由是前四段量不出这次的差别**：VAD 分块只在
# 音频超过 30 秒时才启用（WhisperKit.swift:1021），而 silence30 恰好是
# 30.0 秒、不触发分块——拿它去比「开/关 VAD 分块」，两边跑的是同一条代码路径。
#
#   silence45 / noise45  45 秒，越过分块边界，这才真正量到 vad 开关的差别。
#   tail-silence         真人基准集里 12.9 秒的一条真实录音 + 20 秒尾部静音。
#                        这是**生产上最常见的幻觉形态**：用户说完了、手还
#                        按在键上，尾巴上挂着一段静音。纯静音是理想化的
#                        极端，说完再静音才是每天都在发生的事，而且它同时
#                        越过了 30 秒的分块边界。
noise_gen() {
  local name="$1" seconds="$2" amplitude="$3"
  [[ -s "$NOISE/$name.wav" ]] && return 0
  print "生成 $name.wav"
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
noise_gen silence45 45   0
noise_gen noise45   45   0.002

# 说完再静音：基准集里最长的那条真人录音（punct-03，14.7 秒）尾部补 20 秒静音。
#
# **它不进静音那一维的计数**——它本来就该出字，「非空」不是它的失败判据。
# 它走长语料那一维：覆盖率盯「真话有没有被吃掉」，CER 与结尾那行盯
# 「尾巴上有没有多出模型自己编的话」。总长 34.7 秒，越过 30 秒的分块边界。
TAIL_SRC="$ROOT/Bench/audio/punct-03.wav"
if [[ -s "$TAIL_SRC" && ! -s "$NOISE/tail-silence.wav" ]]; then
  print "生成 tail-silence.wav（punct-03 + 20 秒尾部静音）"
  ffmpeg -v error -i "$TAIL_SRC" -af "apad=pad_dur=20" -ar 16000 -ac 1 \
    -c:a pcm_s16le "$NOISE/tail-silence.wav"
fi

python3 - "$AUDIO" "$MODEL_FOLDER" "$NOISE" "$RUN_BENCH" <<'PY' > Bench/.decode-sweep.json
import json
import os
import subprocess
import sys
import wave

audio_dir, model_folder, noise_dir, run_bench = sys.argv[1:5]

# ---- 长语料：与 long-audio.sh 同一份 corpus、同一套合成逻辑 ----
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
                "repeats": case.get("repeats", group.get("repeats", 1)),
            }
        )

# 「说完再静音」那条挂在长语料这一维的尾巴上，参考文本取 manifest 里
# punct-03 的原文——它就是这段音频的前 14.7 秒。
tail_wav = os.path.join(noise_dir, "tail-silence.wav")
if os.path.exists(tail_wav):
    manifest = json.load(open("Bench/manifest.json", encoding="utf-8"))
    entries = manifest["entries"] if isinstance(manifest, dict) else manifest
    text = next(e["text"] for e in entries if e["id"] == "punct-03")
    with wave.open(tail_wav) as handle:
        seconds = handle.getnframes() / handle.getframerate()
    cases.append(
        {
            "id": "tail-silence",
            "group": "hallucination",
            "wav": tail_wav,
            "text": text,
            "seconds": seconds,
            "repeats": 4,
        }
    )

# ---- 静音那一维 ----
silence = [
    os.path.join(noise_dir, name)
    for name in (
        "silence05.wav", "noise02.wav",
        "silence30.wav", "noise30.wav",
        "silence45.wav", "noise45.wav",
    )
]

# ---- 变体 ----
#
# 每个变体只动一处（4 是 3 的宽松版），这样某一列变差时能对上是哪个旋钮。
# 组合变体放在最后：它们只有在单项都不够时才值得看，而且代价会叠加。
#
# 数值取法：
#   threshold-loose 取 −3.0，因为实测被切中那块的首 token logProb 在
#     −1.86…−3.05 之间跳（六档退火全过程见 docs/Roadmap.md），−3.0 挡得住
#     −3.05 那种、放得过 −1.86 那种，是「只放宽一点」与「完全关掉」之间的中间档。
#   no-fallback 取 0 档，即只跑温度 0 那一次。它治的是「返回最后一次」这个
#     根因的**另一半**：既然拿不到最好的一次，那就别让最后一次有机会覆盖
#     第一次。但温度 0 那次若正好撞上首 token 阈值就是零 token，所以它
#     必须与 threshold-off 一起用才讲得通——单独列一档是为了看清这一点。
#   rescue 是**唯一不在 DecodingOptions 上的变体**：它自己用 WhisperKit 那个
#     公开的 VADAudioChunker 切一遍、逐块解码，只对「有人声却解出空」的那块
#     放宽阈值重来。见 DecodeTuning.rescueEmptyChunks——它是「在
#     decodeWithFallback 里保留最好的一次」的不碰 vendor 等效做法。
variants = [
    {
        "name": "1 baseline 现状",
        "vadChunking": True,
        "firstTokenLogProbThreshold": -1.5,
        "logProbThreshold": -1.0,
        "temperatureFallbackCount": 5,
        "rescueEmptyChunks": False,
    },
    {
        "name": "2 no-vad 关分块",
        "vadChunking": False,
        "firstTokenLogProbThreshold": -1.5,
        "logProbThreshold": -1.0,
        "temperatureFallbackCount": 5,
        "rescueEmptyChunks": False,
    },
    {
        "name": "3 threshold-off",
        "vadChunking": True,
        "firstTokenLogProbThreshold": None,
        "logProbThreshold": -1.0,
        "temperatureFallbackCount": 5,
        "rescueEmptyChunks": False,
    },
    {
        "name": "4 threshold-loose -3.0",
        "vadChunking": True,
        "firstTokenLogProbThreshold": -3.0,
        "logProbThreshold": -1.0,
        "temperatureFallbackCount": 5,
        "rescueEmptyChunks": False,
    },
    {
        "name": "5 no-vad + threshold-off",
        "vadChunking": False,
        "firstTokenLogProbThreshold": None,
        "logProbThreshold": -1.0,
        "temperatureFallbackCount": 5,
        "rescueEmptyChunks": False,
    },
    {
        "name": "6 threshold-off + 不退火",
        "vadChunking": True,
        "firstTokenLogProbThreshold": None,
        "logProbThreshold": -1.0,
        "temperatureFallbackCount": 0,
        "rescueEmptyChunks": False,
    },
    {
        "name": "7 rescue 空块救援",
        "vadChunking": True,
        "firstTokenLogProbThreshold": -1.5,
        "logProbThreshold": -1.0,
        "temperatureFallbackCount": 5,
        "rescueEmptyChunks": True,
    },
]

# 只跑其中几个：./scripts/decode-sweep.sh --only 1,7
# 丢字是间歇性的，选型到后期要拿同一个变体连跑几轮，全跑一遍太贵。
only = os.environ.get("DECODE_SWEEP_ONLY", "").strip()
if only:
    wanted = {token.strip() for token in only.split(",") if token.strip()}
    variants = [v for v in variants if v["name"].split()[0] in wanted]
    if not variants:
        raise SystemExit(f"--only {only} 一个变体都没匹配上")

# ---- --scaling：只量「关掉分块之后长录音会不会变慢」 ----
#
# 把 dense-91（88.4 秒，一口气说完的形态）首尾相接复制若干遍，得到 3/6/10
# 分钟的连续语音。用复制而不是重新合成，是因为要的是**时长**，不是新内容；
# 复制还顺带保证了参考字数是精确已知的（原文 ×N）。
scaling_cases = []
if os.environ.get("DECODE_SWEEP_SCALING") == "1":
    variants = []  # 这一模式下不跑三维对照，省半小时
    dense = next(g for g in corpus["groups"] if g["id"] == "dense")
    base_wav = os.path.join(audio_dir, "dense-91.wav")
    base_text = "".join(dense["segments"])
    for repeats_count, label in ((2, "3min"), (4, "6min"), (7, "10min")):
        wav = os.path.join(audio_dir, f"scaling-{label}.wav")
        if not os.path.exists(wav) or os.path.getsize(wav) == 0:
            print(f"生成 scaling-{label}.wav（dense-91 ×{repeats_count}）", file=sys.stderr)
            listing = os.path.join(audio_dir, f"scaling-{label}.txt")
            with open(listing, "w") as handle:
                for _ in range(repeats_count):
                    handle.write(f"file '{base_wav}'\n")
            subprocess.run(
                ["ffmpeg", "-v", "error", "-f", "concat", "-safe", "0",
                 "-i", listing, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav],
                check=True,
            )
            os.remove(listing)
        with wave.open(wav) as handle:
            seconds = handle.getnframes() / handle.getframerate()
        scaling_cases.append(
            {
                "id": f"scaling-{label}",
                "group": "scaling",
                "wav": wav,
                "text": base_text * repeats_count,
                "seconds": seconds,
                "repeats": 1,
            }
        )

json.dump(
    {
        "modelFolder": model_folder,
        "variants": variants,
        "longCases": cases,
        "silenceFiles": silence,
        "silenceRepeats": 4,
        "runBench": run_bench == "1",
        "scalingCases": scaling_cases,
    },
    sys.stdout,
    ensure_ascii=False,
)
PY

# 标记文件即门控，跑完必须删掉——留着会让下一次普通 ./scripts/test.sh
# 顺带跑一遍全部变体（几十分钟），而且是在人没预期的时候。
trap 'rm -f "$ROOT/Bench/.decode-sweep.json"' EXIT

# --scaling 模式下用 /usr/bin/time -l 包一层，拿峰值内存（maximum resident
# set size）。测进程里只跑这一个测试，所以整个进程的峰值就是它的峰值。
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p Bench/reports
if [[ "$SCALING" == "1" ]]; then
  /usr/bin/time -l ./scripts/test.sh --filter DecodeSweepTests "$@" 2>&1 \
    | tee "Bench/reports/$STAMP-decode-scaling-$MODEL_NAME.txt"
  print "归档：Bench/reports/$STAMP-decode-scaling-$MODEL_NAME.txt"
  exit 0
fi

./scripts/test.sh --filter DecodeSweepTests "$@"

# 归档：Bench/decode-sweep.txt 每轮被覆盖，而选型要拿几轮的数放在一起看
# （丢字是间歇性的，单轮 12 次采样的置信区间不窄）。
cp Bench/decode-sweep.txt "Bench/reports/$STAMP-decode-sweep-$MODEL_NAME.txt"
print "归档：Bench/reports/$STAMP-decode-sweep-$MODEL_NAME.txt"
