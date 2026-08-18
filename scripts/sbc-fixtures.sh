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
#
# ── 矩阵覆盖到哪、覆盖不到哪 ─────────────────────────────────────────
# 独立验收 2026-08-18 对解码器跑了 417 个变异，404 个被抓。存活的 13 个
# 分成两类，结论完全不同：
#
# **6 个是真盲区，已补**（见矩阵末尾那三条的注释）：bits[sb] 的 `16` 上限
# 一族 5 个、帧长公式的 `+7` 向上取整 1 个。当前固件（16 blocks /
# bitpool 12）碰不到它们，但**固件一改就是未测代码**。
#
# 补完之后逐个复验过（把上界上下各改一格、把 `+7` 去掉，共 7 处变异）：
# 7/7 全被抓到，但**抓到的形态有三种**，看结果时要认得出来——
# 5 处是逐样本断言失败；`min(…, 16)` 改成 `17` 是 `Index out of range`
# **崩溃**（bits 超过 16 就会读到帧外，真实码流里不会发生，因为
# calculateBits 保证 sum(bits) ≤ bitpool）；slicecount 那处的上界改小则让
# `repeat…while` **不收敛**，测试挂死到超时。只 grep「断言失败」会把后两种
# 误报成「变异存活」——本轮就先这么误判过一次。
#
# **另外 10 个是结构性死代码，不要试图去覆盖**：`synmatrix4[2]` 与
# `synmatrix8[4]` 是全零行（合成滤波器的对称性决定的），那些系数无论改成
# 什么都要乘 0，ffmpeg 里也一样。改它们不可能产生任何输出差异，
# 「没被抓到」是正确的结果而不是缺口。记在这里免得下一轮又有人去追。
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
    # ── 下面三条补的是变异测试查出来的两个盲区（独立验收 2026-08-18）──
    #
    # ① bits[sb] 的 `16` 上限一族（5 个存活变异）。上面那些夹具的 bits[sb]
    #    最高只到 11，而规范可到 16——于是位分配里那四处 `16`
    #    （`bitneed < bitslice + 16`、`min(…, 16)`、两处 `bits[sb] < 16`）
    #    改成别的数也照样全绿。
    #
    #    **这一条要 256 帧，不是 16 帧。** 逐个变异量过命中率之后才定的数：
    #    前三处随便一帧接近上限就能打到，而**第二个填充环那处
    #    （`bits[sb] < 16` → `bits[sb] += 1`）在整个合法参数空间里的命中率
    #    都只有约 0.5%**（扫了 4/8 子带 × 两种分配 × 全部合法 bitpool ×
    #    五档 sf_max，最高就是 0.005）。16 帧撞上它的概率不到 8%。
    #    这个配置下四处的首次命中分别在第 17 / 135 / 135 / 221 帧，
    #    取 256 帧留出余量。帧只有 20 字节，整条夹具连参考 PCM 一共 13 KB。
    #
    #    顺带：4 blocks × bitpool 27 = 108，108 % 8 = 4，所以它同时也是
    #    一条 `+7` 向上取整的用例。
    ("synth-16k-4blk-4sb-snr-bp27",            0,  4, 0, 1, 4, 27, 14, 256),
    #
    #    上面那条把「上界被下调」的方向堵住了，**「上界被上调」是另一个方向**：
    #    把 `min(…, 16)` 写成 `min(…, 17)` 它照样抓不到，因为 bp27 下
    #    `bitneed - bitslice` 到不了 17。这一条补那个方向——bitpool 取到
    #    4 子带的规范上限 64 附近，第 0 帧就能把差值顶过 16。
    #    4 × 63 = 252，252 % 8 = 4，它也是一条 `+7` 用例。
    ("synth-16k-4blk-4sb-snr-bp63",            0,  4, 0, 1, 4, 63, 15),
    #
    # ② 帧长公式的 `+7` 向上取整（1 个存活变异）。上面那些**全部满足
    #    blocks × bitpool % 8 == 0**，于是 `(x + 7) // 8` 写成 `x // 8`
    #    结果一样。4 blocks × bitpool 21 = 84，84 % 8 = 4，帧长必须是 19
    #    字节而不是 18。留成独立一条是因为它一眼就能看懂，
    #    而上面那条 256 帧的是为别的目的攒的。
    ("synth-16k-4blk-8sb-loudness-bp21",       0,  4, 0, 0, 8, 21,  9),
]
for row in matrix:
    name, freq, blocks, mode, alloc, subbands, bitpool, sf_max = row[:8]
    # 帧数。默认 16 够用；个别配置要多得多，理由写在那一行旁边。
    frames = row[8] if len(row) > 8 else 16
    # 固定种子：夹具必须可复现，否则「重新生成一次」就等于换了一套判据。
    # **种子是名字**，所以改名字等于换一套码流——上面那条 256 帧的夹具
    # 是按名字实测过命中帧号的，改名要重新量。
    rng = random.Random(name)
    emit(name, b"".join(
        build_frame(freq, blocks, mode, alloc, subbands, bitpool, rng, sf_max)
        for _ in range(frames)
    ))
PY

print "夹具已写入 $OUT"
