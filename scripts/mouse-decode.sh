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

# **快照由下面的 Python 写，不在这里 cp。**
#
# 原来这一行是无条件的 `cp "$LOG" "$OUT/capture.log"`，排在时长上限判断
# **之前**。于是 2026-08-18 那 11 分钟环境音「被跳过」之后，它的原始十六
# 进制仍然完整躺在 capture.log 里，只是没解成 WAV——而脚本打的那行
# 「不解码不落盘」是假的。独立验收 2026-08-18 指出（P2）。
#
# 现在快照是**剔除过的**：超长会话的音频行不进 capture.log，位置上留一行
# 标记说明剔掉了什么。快照仍然完整覆盖被解码的那些会话，「任何人拿这份
# 快照都能复现同一批 WAV」这条不变。
#
# 为什么仍然要快照：抓包工具还在跑时源文件是活的，本轮调查期间它从 1562
# 行长到 12734 行，同一条命令跑两次会得到不同的会话列表。

python3 - "$OUT" "$MODEL_FOLDER" "$LOG" <<'PY'
import json
import os
import re
import sys

out, model, source = sys.argv[1], sys.argv[2], sys.argv[3]
# 快照的路径。报告里写的是它——拿这份快照能复现同一批 WAV。
log = os.path.join(out, "capture.log")

# 音频特征（服务 FFF1）。同一特征上既有 128 字节的音频包，也有 17 字节的
# 控制帧，靠长度区分。
AUDIO_UUID = "0783B03E-8535-B5A0-7140-A304D2495CB8"
LINE = re.compile(r"^(\d\d-\d\d \d\d:\d\d:\d\d\.\d\d\d)\s+RAW uuid=(\S+) len=(\d+) hex=(.*)$")

# 读源日志而不是快照：快照要等到知道哪些行该剔除之后才写得出来。
source_lines = open(source, encoding="utf-8", errors="replace").readlines()

rows = []
for number, line in enumerate(source_lines):
    m = LINE.match(line.strip())
    if m and m.group(2) == AUDIO_UUID:
        payload = bytes(int(x, 16) for x in m.group(4).split())
        # len= 与 hex= 对不上说明这一行被截断了（日志是边跑边写的，最后一行
        # 可能只写了一半）。直接丢掉，混进码流会让后面所有帧错位。
        if len(payload) == int(m.group(3)):
            rows.append((m.group(1), payload, number))

def seconds(stamp):
    hh, mm, ss = stamp.split(" ")[1].split(":")
    return int(hh) * 3600 + int(mm) * 60 + float(ss)

# 会话协议（控制帧第 6 字节）：奇数码开始、下一个偶数码结束。
#   0x51 → 0x21 → [音频] → 0x22    语音键
#   0x23 → [音频] → 0x24           另一个键
#   0x27 → [音频] → 0x28           第三个键
# 0x31 也出现过（长按开麦），同样是奇数开始码。
STARTS = {0x21, 0x23, 0x27, 0x31}

# **超过这个时长的会话一律跳过，不写码流也不写 WAV。**
#
# 2026-08-18 真机上出过一次：0x31（长按开麦）没有配对的结束码，鼠标持续
# 送流 11 分钟，把用户不知情的房间环境音录进了抓包日志，随后被这个脚本
# 解成 15 MB 的 WAV 还转写了一遍。用户是靠菜单栏的麦克风图标才发现的。
#
# 有意按键说话不会超过一分钟——遥控器那边固件 60 秒就切断（见
# Testing/M3-Acceptance.md）。所以「很长」等价于「不是有意录的」，
# 默认跳过比默认解码安全得多：漏解一段有意的录音只是重跑一次，
# 而误解一段环境音是把它落盘、转写、可能还进了版本库。
#
# 真要处理长会话，显式设 MOUSE_DECODE_MAX_SECONDS 覆盖它。
MAX_SESSION_SECONDS = float(os.environ.get("MOUSE_DECODE_MAX_SECONDS", "90"))

control = [i for i, (_, p, _) in enumerate(rows) if len(p) == 17]

spans = []
for index, position in enumerate(control):
    code = rows[position][1][5]
    if code not in STARTS:
        continue
    # 结束位置：下一个控制帧；没有下一个说明这段还没结束（抓包时用户
    # 还按着，或者工具是在录制中途被停掉的），用最后一个包兜底。
    end = control[index + 1] if index + 1 < len(control) else len(rows)
    audio = [(p, number) for _, p, number in rows[position + 1:end] if len(p) == 128]
    if not audio:
        continue
    end_stamp = rows[end][0] if end < len(rows) else rows[-1][0]
    spans.append((
        code,
        seconds(end_stamp) - seconds(rows[position][0]),
        [p for p, _ in audio],
        [number for _, number in audio],
    ))

candidates = []
skipped = []
# 超长会话的音频行号。**这些行不进快照**——否则「不落盘」是假话。
redacted_lines = set()
for number, (code, duration, packets, line_numbers) in enumerate(spans, start=1):
    name = f"s{number:02d}-code{code:02x}"
    if duration > MAX_SESSION_SECONDS:
        # 只报时长，不报内容——这段大概率是没人想录的东西。
        skipped.append(f"{name} 时长={duration:.1f}s 音频行数={len(line_numbers)}")
        redacted_lines.update(line_numbers)
        continue
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

# 写快照：超长会话的音频行剔掉，原地留一行标记。
#
# **标记不能省。** 一份少了几千行而不说明的快照，比不做剔除更糟——
# 下一个人拿它对不上会话列表，会去怀疑解析器。
with open(log, "w", encoding="utf-8") as handle:
    marked = False
    for number, line in enumerate(source_lines):
        if number in redacted_lines:
            if not marked:
                handle.write(
                    f"# 【已剔除】{len(redacted_lines)} 行超长会话的音频十六进制"
                    f"（超过 {MAX_SESSION_SECONDS:.0f} 秒的会话，多半是误触长按录到的"
                    f"环境音）。剔除的是这份快照，源日志 {source} 未被改动。\n"
                )
                marked = True
            continue
        handle.write(line)

if skipped:
    print(f"\n已跳过 {len(skipped)} 段超长会话（超过 {MAX_SESSION_SECONDS:.0f} 秒，"
          f"多半是误触长按录到的环境音）：")
    for item in skipped:
        print(f"  {item}")
    print(f"  不解码、不出 WAV，原始十六进制也没有进 {log}（共剔除 "
          f"{len(redacted_lines)} 行）。")
    print(f"  **源日志 {source} 未被改动**——那几行仍在里面，要清干净得自己删。")
    print("  确需处理请显式设 MOUSE_DECODE_MAX_SECONDS\n")

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
