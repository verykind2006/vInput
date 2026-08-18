#!/bin/zsh
# 把蓝牙鼠标抓包里的音频流离线解成 PCM，再喂给**生产的** Whisper 转写器。
#
# 用法：
#   ./scripts/mouse-decode.sh                                  # 用最新一份抓包 + 应用的默认模型
#   ./scripts/mouse-decode.sh ~/Library/Logs/vInput/ble-scan-20260818-140612.log
#   ./scripts/mouse-decode.sh <日志> openai_whisper-large-v3    # 指定模型
#
# 产物全部落在 MouseDecode/（已在 .gitignore 里）：
#   capture.log          抓包快照
#   sbc/<会话>.sbc       该会话的裸 SBC 码流（可直接拖进任何 SBC 解码器）
#   wav/<会话>.wav       解出的 16 kHz 单声道 PCM，能直接试听
#   report.txt           逐会话的样本数、反算采样率、转写结果
#
# ── 这条流到底是什么 ────────────────────────────────────────────────
# **标准 SBC，不是 ADPCM。** 每个 128 字节 BLE 包 = 4 个 32 字节 SBC 帧，
# 帧头 `9C 31 0C xx` 逐位对得上 A2DP 规范的 SBC frame_header：
#
#   9C  syncword（SBC 固定 0x9C；mSBC 才是 0xAD）
#   31  0b00 110 0 0 1 → sampling_frequency=16 kHz，blocks=16，
#       channel_mode=MONO，allocation_method=Loudness，subbands=8
#   0C  bitpool = 12
#   xx  CRC-8（多项式 0x1D、初值 0x0F，覆盖 header[1]、header[2] 与全部
#       scale factor 位）——**抓包里 7872/7872 帧逐帧命中**，这是判定依据，
#       不是猜测。那个「变化的第 4 字节」就是它。
#
# 帧长按规范算 4 + 4*8*1/8 + ceil(16*1*12/8) = 32 字节，与实测一致；
# 每帧 16 blocks × 8 subbands = 128 个样本 = 16 kHz 下的 8 ms，
# 每包 4 帧 = 32 ms，与实测的 31.25 包/秒（包间隔中位数 30 ms、均值 32 ms）
# 对得上。用控制帧时间戳反算出的采样率是 15986/15939/15942 Hz，
# 与帧头写的 16 kHz 一致——**头和时长两条独立证据互相印证**。
#
# 走过的弯路记在这里，省得再试一遍：静音段那些重复的 `55 55 75` 半字节
# 看着很像 IMA ADPCM 的中间码字，但按 IMA 解（帧头 3 或 4 字节 × 高/低
# 半字节在前，四种组合全试过）得到的样本 55–62% 撞满量程、直流偏置
# +13000，反算采样率 6974–7243 Hz，全是噪音。
#
# ── 为什么这里还留着 ffmpeg ─────────────────────────────────────────
# 产品已经不需要它了：`Sources/vInput/Audio/Vendored/SBCDecoder.swift`
# 是 Swift 实现的 SBC 解码器，应用不再依赖 homebrew 的 ffmpeg。
#
# 这里保留 ffmpeg 是**当标尺**：`MouseDecodeTests` 用 SBCDecoder 解同一份
# 裸码流，再与 ffmpeg 解出的 WAV 逐样本比对，要求完全相同。合成滤波器带的
# proto filter 系数表写错了不会崩、不会报错，只会解出「能听但发闷」的音频，
# 正是本项目最怕的那种静默失败——只有逐样本判据抓得住它。
# 不装 ffmpeg 也能跑的那一份判据在 `SBCDecoderTests` 里（夹具已进版本库）。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

if ! command -v ffmpeg >/dev/null 2>&1; then
  print -u2 "需要 ffmpeg 来解 SBC：brew install ffmpeg"
  exit 1
fi

LOG="${1:-}"
if [[ -z "$LOG" ]]; then
  # 取最新一份抓包。ble-scan-*.log 的文件名带时间戳，字典序即时间序。
  LOG="$(ls -1 "$HOME/Library/Logs/vInput/"ble-scan-*.log 2>/dev/null | tail -1)"
fi
if [[ -z "$LOG" || ! -f "$LOG" ]]; then
  print -u2 "找不到抓包日志。用法：./scripts/mouse-decode.sh <ble-scan-*.log>"
  exit 1
fi

MODEL_NAME="${2:-}"
if [[ -z "$MODEL_NAME" ]]; then
  # 与 bench-run.sh 同一条理由：不带参数时也要解析出**应用会用的**模型，
  # 而不是让 WhisperKitTranscriber 落到 modelName 的默认值 "base"
  # 联网下载一个产品从不使用的模型（2026-08-17 独立验收 F1）。
  MODEL_NAME="$("$ROOT/scripts/default-model.sh")"
  print "未指定模型，用应用的默认模型：$MODEL_NAME"
fi
MODEL_FOLDER="$ROOT/vendor/models/$MODEL_NAME"
if [[ ! -d "$MODEL_FOLDER" ]]; then
  print -u2 "模型目录不存在：$MODEL_FOLDER"
  exit 1
fi

OUT="$ROOT/MouseDecode"
rm -rf "$OUT/sbc" "$OUT/wav"
mkdir -p "$OUT/sbc" "$OUT/wav"

# **先把日志快照下来再解析。** 抓包工具还在跑时这个文件是活的：本轮调查
# 期间它从 1562 行长到 12734 行，同一条命令跑两次会得到不同的会话列表。
# 报告里写的是快照的路径，任何人拿这份快照都能复现同一批 WAV。
cp "$LOG" "$OUT/capture.log"

python3 - "$OUT" "$MODEL_FOLDER" <<'PY'
import json
import os
import re
import sys

out, model = sys.argv[1], sys.argv[2]
log = os.path.join(out, "capture.log")

# 音频特征（服务 FFF1）。同一特征上既有 128 字节的音频包，也有 17 字节的
# 控制帧，靠长度区分。
AUDIO_UUID = "0783B03E-8535-B5A0-7140-A304D2495CB8"
LINE = re.compile(r"^(\d\d-\d\d \d\d:\d\d:\d\d\.\d\d\d)\s+RAW uuid=(\S+) len=(\d+) hex=(.*)$")

rows = []
for line in open(log, encoding="utf-8", errors="replace"):
    m = LINE.match(line.strip())
    if m and m.group(2) == AUDIO_UUID:
        payload = bytes(int(x, 16) for x in m.group(4).split())
        # len= 与 hex= 对不上说明这一行被截断了（日志是边跑边写的，最后一行
        # 可能只写了一半）。直接丢掉，混进码流会让后面所有帧错位。
        if len(payload) == int(m.group(3)):
            rows.append((m.group(1), payload))

def seconds(stamp):
    hh, mm, ss = stamp.split(" ")[1].split(":")
    return int(hh) * 3600 + int(mm) * 60 + float(ss)

# 会话协议（控制帧第 6 字节）：奇数码开始、下一个偶数码结束。
#   0x51 → 0x21 → [音频] → 0x22    语音键
#   0x23 → [音频] → 0x24           另一个键
#   0x27 → [音频] → 0x28           第三个键
# 0x31 也出现过（长按开麦），同样是奇数开始码。
STARTS = {0x21, 0x23, 0x27, 0x31}
control = [i for i, (_, p) in enumerate(rows) if len(p) == 17]

spans = []
for index, position in enumerate(control):
    code = rows[position][1][5]
    if code not in STARTS:
        continue
    # 结束位置：下一个控制帧；没有下一个说明这段还没结束（抓包时用户
    # 还按着，或者工具是在录制中途被停掉的），用最后一个包兜底。
    end = control[index + 1] if index + 1 < len(control) else len(rows)
    packets = [p for _, p in rows[position + 1:end] if len(p) == 128]
    if not packets:
        continue
    end_stamp = rows[end][0] if end < len(rows) else rows[-1][0]
    spans.append((code, seconds(end_stamp) - seconds(rows[position][0]), packets))

candidates = []
for number, (code, duration, packets) in enumerate(spans, start=1):
    name = f"s{number:02d}-code{code:02x}"
    stream = b"".join(packets)
    # 每包 4 个 32 字节 SBC 帧，直接首尾相接就是合法的裸 SBC 码流。
    with open(os.path.join(out, "sbc", name + ".sbc"), "wb") as handle:
        handle.write(stream)
    frames = len(stream) // 32
    candidates.append({
        "label": f"{name}  包={len(packets)} 帧={frames}",
        # 裸码流的路径：MouseDecodeTests 用生产的 SBCDecoder 解它，
        # 再与下面这个 ffmpeg 解出的 WAV 逐样本比对。
        "sbcPath": os.path.join(out, "sbc", name + ".sbc"),
        "wavPath": os.path.join(out, "wav", name + ".wav"),
        "durationSeconds": round(duration, 3),
    })
    print(f"会话 {name}: 包={len(packets)} 帧={frames} 时长={duration:.3f}s")

if not candidates:
    sys.exit("抓包里没有任何完整会话——确认这份日志录到了按键说话的那一段")

config = {
    "modelFolder": model,
    "logPath": log,
    "reportPath": os.path.join(out, "report.txt"),
    "candidates": candidates,
}
with open(os.path.join(out, ".run-config.json"), "w", encoding="utf-8") as handle:
    json.dump(config, handle, ensure_ascii=False, indent=2)
PY

# -f sbc 让 ffmpeg 按裸 SBC 码流读；帧头自带采样率与声道数，无需再指定。
for stream in "$OUT"/sbc/*.sbc; do
  name="${stream:t:r}"
  ffmpeg -y -hide_banner -loglevel error \
    -f sbc -i "$stream" -c:a pcm_s16le "$OUT/wav/$name.wav"
done
print "解出的 WAV 在 $OUT/wav/（16 kHz 单声道，可直接试听）"

# 标记文件即门控，跑完必须删掉——留着会让下一次普通 ./scripts/test.sh
# 顺带加载一次 Whisper 模型跑这轮实验。
trap 'rm -f "$OUT/.run-config.json"' EXIT

./scripts/test.sh --filter MouseDecodeTests
