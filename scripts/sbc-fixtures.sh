#!/bin/zsh
# 重新生成 SBC 解码器的测试夹具（Tests/vInputTests/Fixtures/SBC/）。
#
#   ./scripts/sbc-fixtures.sh
#
# 夹具是「一段裸 SBC 码流 + ffmpeg 解出的参考 PCM」成对存放：
#   <名字>.sbc   裸 SBC 码流（首尾相接的完整帧）
#   <名字>.pcm   ffmpeg 解出的 s16le 交错 PCM，逐样本参考答案
#
# ── 为什么夹具要进版本库 ──────────────────────────────────────────────
# `SBCDecoderTests` 的判据是「与 ffmpeg 逐样本完全相同」。把 ffmpeg 的输出
# 存成夹具，测试就能在**没装 ffmpeg**的机器上跑，也不必加载任何模型。
# 产品代码不再依赖 homebrew 的 ffmpeg，正是 M7 这一步的目的；测试同理。
#
# ── 为什么不用真实录音当夹具 ──────────────────────────────────────────
# 真机抓到的三段是用户的说话声，MouseDecode/ 整个在 .gitignore 里，不能进
# 版本库。所以这里全部用合成信号。真实录音的逐样本比对走门控的
# `MouseDecodeTests`，见那个文件。
#
# ── 合成的两种手法 ────────────────────────────────────────────────────
# 1. 设备配置那一条用 **ffmpeg 的 SBC 编码器**压一段正弦+噪声。
#    16 kHz 单声道 + `-b:a 32k` 恰好压出帧头 `9C 31 0C`，与鼠标固件逐位相同。
# 2. 其余配置 ffmpeg 编码器压不出来（它固定 8 子带 / Loudness），改为**手工
#    拼帧**：帧头按规范填、CRC-8 照算、scale factor 随机、音频区直接填随机
#    字节。随机码流也是合法的 SBC——解码器只按 scale factor 推位分配，
#    不校验码字内容。这样才能覆盖 4 子带、SNR 分配、4/8/12 blocks 与
#    32/44.1/48 kHz 这些真机流里出现不了、但固件一改就可能出现的分支。
#
# 带 `-clip` 的那条故意把 scale factor 拉满，让输出撞上 16 位饱和——
# `av_clip_int16` 那一步也要被测到。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

if ! command -v ffmpeg >/dev/null 2>&1; then
  print -u2 "生成夹具需要 ffmpeg（只在重新生成时需要，跑测试不需要）：brew install ffmpeg"
  exit 1
fi

OUT="$ROOT/Tests/vInputTests/Fixtures/SBC"
rm -rf "$OUT"
mkdir -p "$OUT"

python3 - "$OUT" <<'PY'
import os
import random
import struct
import subprocess
import sys

out = sys.argv[1]


def crc8(buffer, nbits):
    """SBC 的 CRC-8：多项式 0x1D、初值 0x0F，按位算（长度不是 8 的整数倍）。"""
    crc = 0x0F
    for i in range(nbits):
        bit = (buffer[i >> 3] >> (7 - (i & 7))) & 1
        crc = ((crc << 1) & 0xFF) ^ (0x1D if ((crc >> 7) ^ bit) else 0)
    return crc


def build_frame(freq, blocks, mode, alloc, subbands, bitpool, rng, sf_max):
    channels = 1 if mode == 0 else 2
    b1 = ((freq << 6) | (((blocks // 4) - 1) << 4)
          | (mode << 2) | (alloc << 1) | (1 if subbands == 8 else 0))
    factors = [[rng.randint(0, sf_max) for _ in range(subbands)] for _ in range(channels)]

    # CRC 覆盖 header[1]、header[2] 与全部 scale factor 位（不含 syncword）。
    crc_buffer = bytearray(16)
    crc_buffer[0] = b1
    crc_buffer[1] = bitpool
    pos = 16
    for ch in range(channels):
        for sb in range(subbands):
            crc_buffer[pos >> 3] |= factors[ch][sb] << (4 - (pos & 7))
            pos += 4

    frame = bytearray([0x9C, b1, bitpool, crc8(crc_buffer, pos)])
    frame += crc_buffer[2:pos // 8]
    frame += bytes(rng.randrange(256) for _ in range((blocks * channels * bitpool + 7) // 8))
    return bytes(frame)


def emit(name, stream):
    sbc_path = os.path.join(out, name + ".sbc")
    pcm_path = os.path.join(out, name + ".pcm")
    with open(sbc_path, "wb") as handle:
        handle.write(stream)
    subprocess.run(
        ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
         "-f", "sbc", "-i", sbc_path, "-f", "s16le", "-c:a", "pcm_s16le", pcm_path],
        check=True,
    )
    with open(pcm_path, "rb") as handle:
        raw = handle.read()
    values = struct.unpack("<%dh" % (len(raw) // 2), raw)
    peak = max(abs(v) for v in values) if values else 0
    saturated = sum(1 for v in values if v >= 32767 or v <= -32768)
    print(f"{name}: 码流={len(stream)}B 样本={len(values)} 峰值={peak} 撞满量程={saturated}")


# 设备配置：ffmpeg 编码器压一段 440 Hz 正弦叠加白噪声。
# 噪声是必要的——纯正弦只激活少数几个子带，proto filter 表里大半系数
# 抄错了也照样对得上。
temporary = os.path.join(out, "_encoder-input.sbc")
subprocess.run(
    ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
     "-f", "lavfi", "-i",
     "sine=frequency=440:sample_rate=16000:duration=0.35,volume=0.4",
     "-af", "aeval=val(0)+0.15*random(0)",
     "-ac", "1", "-c:a", "sbc", "-b:a", "32k", "-f", "sbc", temporary],
    check=True,
)
with open(temporary, "rb") as handle:
    emit("dev-16k-16blk-8sb-loudness-bp12", handle.read())
os.remove(temporary)

# 频率 / blocks / 子带数 / 分配方式的其余组合，全部 MONO——解码器只支持单声道。
# Loudness 的 bitneed 要减去一张按「采样率 × 子带」索引的 offset 表
# （规范 Appendix B）。**这张表的每一行都要被某条夹具走到**——只测 16 kHz
# 那一行时，把 32/44.1/48 kHz 的行改错，测试照样全绿（本轮变异测试实测）。
# 所以下面 Loudness × {4,8} 子带 × 四种采样率一个都不能少。
# SNR 不查这张表，各留一条覆盖 4/8 子带即可。
matrix = [
    # 名字                                     freq blocks mode alloc sb bitpool sf_max
    ("synth-16k-4blk-8sb-loudness-bp20",       0,  4, 0, 0, 8, 20,  9),
    ("synth-32k-16blk-8sb-loudness-bp24",      1, 16, 0, 0, 8, 24,  9),
    ("synth-44k-8blk-8sb-loudness-bp26",       2,  8, 0, 0, 8, 26,  9),
    ("synth-48k-16blk-8sb-loudness-bp28",      3, 16, 0, 0, 8, 28,  9),
    ("synth-16k-16blk-4sb-loudness-bp12",      0, 16, 0, 0, 4, 12,  9),
    ("synth-32k-12blk-4sb-loudness-bp10",      1, 12, 0, 0, 4, 10,  9),
    ("synth-44k-16blk-4sb-loudness-bp14",      2, 16, 0, 0, 4, 14,  9),
    ("synth-48k-16blk-4sb-loudness-bp16",      3, 16, 0, 0, 4, 16,  9),
    ("synth-16k-8blk-8sb-snr-bp16",            0,  8, 0, 1, 8, 16,  9),
    ("synth-44k-16blk-8sb-snr-bp32",           2, 16, 0, 1, 8, 32,  8),
    ("synth-48k-4blk-4sb-snr-bp24",            3,  4, 0, 1, 4, 24,  9),
    ("synth-16k-16blk-8sb-loudness-bp12-clip", 0, 16, 0, 0, 8, 12, 15),
]
for name, freq, blocks, mode, alloc, subbands, bitpool, sf_max in matrix:
    # 固定种子：夹具必须可复现，否则「重新生成一次」就等于换了一套判据。
    rng = random.Random(name)
    emit(name, b"".join(
        build_frame(freq, blocks, mode, alloc, subbands, bitpool, rng, sf_max)
        for _ in range(16)
    ))
PY

print "夹具已写入 $OUT"
