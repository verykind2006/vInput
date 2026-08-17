#!/bin/zsh
# 模型对比：用同一组音频跑 vendor/models 下的所有模型。
#
# 测试音频用系统 TTS 生成，覆盖三个目标场景：闲聊短句、技术密集、长文。
# 已存在则跳过生成。
set -euo pipefail

ROOT="${0:A:h:h}"
AUDIO="/tmp/vinput-bench"
mkdir -p "$AUDIO"

gen() {
  local name="$1" text="$2"
  [[ -s "$AUDIO/$name.wav" ]] && return 0
  print "生成 $name.wav"
  say -v Tingting -o "$AUDIO/$name.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$AUDIO/$name.aiff" "$AUDIO/$name.wav"
  rm -f "$AUDIO/$name.aiff"
}

gen chat "行那我明天上午再看看这个事儿吧你先忙"
gen short "帮我把这个函数里的依赖数组改一下，然后跑一遍测试"
gen tech "把 useEffect 里的依赖数组补上 loading 状态，然后把这个组件的 props 类型定义抽到单独的文件里，顺便修一下快捷键之外的那个报错"
# 标点回归用：真机上「长句零标点」的两句原话，文本刻意不带标点，
# 让 TTS 一口气读完，复现连读长句的场景。
gen nopunct1 "最后再来看一下长句子的输出如果有一段长达二十秒到三十秒的句子识别的能力会是怎样的我们来测试一下现在已经十五秒还需要五秒钟的长度一起来看看结果"
gen nopunct2 "好的我又跑了一遍你检查一下日志看看具体是什么情况同时还有另外一件事我不知道大模型有没有起作用但是目前的结果来看标点符号的处理是比较糟糕的这个有办法解决吗"

gen long "今天下午三点我们讨论一下发版计划，看看相关的计划是否可行，以及在可行范围内我们要付出怎样的代价，怎么用最小的代价实现我们的发版目标。另外还需要确认一下测试环境的准备情况，以及灰度发布的具体时间窗口，如果有风险要提前上报。"

# 英文技术专名回归用：真机上把 Claude Code 听成 collodecode 的那句原话。
# 注意 say -v Tingting 读英文词的发音与真人差别很大，这段只能用来看
# 「有没有变坏」，不能拿来证明真机上会变好。
gen techen "我们用 Claude Code 写代码，然后用 GitHub Actions 做持续集成，最后部署到 AWS 上面。"

# 不到 1 秒的高频短句。
#
# WhisperKit 的主解码循环是 `while seek < seekClipEnd - windowPadding`，
# windowPadding 默认 1.0 秒，因此不长于 1 秒的音频循环体一次都不执行、
# 返回空文本。这几段实测全部落在悬崖下方（0.41–0.79 秒），
# 而 short_ok 是 1.04 秒、刚好在上方，用来标定悬崖位置。
gen short_hao "好的"
gen short_shou "收到"
gen short_xie "谢谢"
gen short_zhidao "知道了"
gen short_bukeqi "不客气"
gen short_mingtian "明天见"
gen short_ok "好的就这样"

# 单音节词：0.26–0.41 秒，比旧的 minimumDuration=0.3 还短。
# 「对」0.260s 补白后能解出「对。」，证明那个门槛在往外挡真话。
gen syl_dui "对"
gen syl_hao "好"
gen syl_xing "行"

# 无语音素材：检测 initial prompt 的词汇泄漏与套话幻觉。
# 数字静音、白噪声（不同响度与时长），全部 16k 单声道，与 TTS 素材同规格。
noise_gen() {
  local name="$1" seconds="$2" amplitude="$3"
  [[ -s "$AUDIO/$name.wav" ]] && return 0
  print "生成 $name.wav"
  if [[ "$amplitude" == "0" ]]; then
    ffmpeg -v error -f lavfi -i "anullsrc=r=16000:cl=mono" -t "$seconds" \
      -c:a pcm_s16le "$AUDIO/$name.wav"
  else
    ffmpeg -v error -f lavfi -i "anoisesrc=r=16000:c=white:a=$amplitude" -t "$seconds" \
      -ac 1 -c:a pcm_s16le "$AUDIO/$name.wav"
  fi
}

noise_gen silence   1.5 0
# 0.5 秒静音：与 short_* 同一量级。补白修复会把它撑到 1.1 秒送进解码器，
# 这一段守着「补白不会凭空补出一句套话」。
noise_gen silence05 0.5 0
noise_gen silence5  5   0
noise_gen silence15 15  0
noise_gen silence30 30  0
noise_gen noise     2   0.002
noise_gen noise10  10   0.002
# 30 秒底噪是泄漏检测里最灵敏的一条：短片段模型多半直接吐空，
# 而长窗口给了它「必须说点什么」的空间，prompt 的原话就在这里漏出来。
noise_gen noise30  30   0.002
noise_gen noise_quiet 4 0.0007

# 嘈杂环境下的真实语音：把 TTS 压到很轻再混白噪，模拟远场/嘈杂。
#
# 这一段是「温度大于 0 就判幻觉」那条判据会误伤的证据：4 次转写里有 1 次
# 解出 temperature=0.4、noSpeechProb=0.0000、avgLogprob=-0.4625 的
# 「谢谢大家。」——文字完全正确，却满足判据被整段删掉。
# 详见 WhisperKitTranscriber.isFallbackFiller 的注释。
#
# **它是不确定性的**（退火采样带随机数），不能拿来写断言，只能跑多次观察。
# normalize=0 必须写：amix 默认按输入数归一，会把设好的信噪比改掉。
mix_gen() {
  local name="$1" text="$2" volume="$3" amplitude="$4"
  [[ -s "$AUDIO/$name.wav" ]] && return 0
  print "生成 $name.wav"
  say -v Tingting -o "$AUDIO/$name.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$AUDIO/$name.aiff" "$AUDIO/$name.src.wav"
  ffmpeg -v error -y -i "$AUDIO/$name.src.wav" \
    -f lavfi -i "anoisesrc=r=16000:c=white:a=$amplitude" \
    -filter_complex "[0:a]volume=$volume,aformat=sample_fmts=fltp:channel_layouts=mono[a];[1:a]aformat=sample_fmts=fltp:channel_layouts=mono[n];[a][n]amix=inputs=2:duration=first:normalize=0[out]" \
    -map "[out]" -ar 16000 -ac 1 -c:a pcm_s16le "$AUDIO/$name.wav"
  rm -f "$AUDIO/$name.aiff" "$AUDIO/$name.src.wav"
}

mix_gen noisy_thanks "谢谢大家" 0.06 0.05

cd "$ROOT"
# --audio-only：只生成音频就退出。
#
# /tmp 会被系统定期清空，而转写端到端（PipelineE2ETests）依赖这批音频。
# 清空之后测试会以 loadAudioFailed 整片失败，看着像代码坏了。
# 没有这个入口的话，重新生成音频得连带跑一遍完整的模型对比（好几分钟）。
if [[ "${1:-}" == "--audio-only" ]]; then
  print "音频已生成于 $AUDIO"
  exit 0
fi

# 参数透传。`Bench.main` 读 `CommandLine.arguments` 判断是不是 `switch`，
# 而此处此前没有 "$@"——`./scripts/bench.sh switch` 一直进不到切换诊断，
# 跑的还是默认的模型对比（2026-08-17 独立验收顺带查出）。
exec swift run -c release vInputBench "$@"
