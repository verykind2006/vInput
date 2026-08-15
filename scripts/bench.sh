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
noise_gen silence5  5   0
noise_gen silence15 15  0
noise_gen silence30 30  0
noise_gen noise     2   0.002
noise_gen noise10  10   0.002
# 30 秒底噪是泄漏检测里最灵敏的一条：短片段模型多半直接吐空，
# 而长窗口给了它「必须说点什么」的空间，prompt 的原话就在这里漏出来。
noise_gen noise30  30   0.002
noise_gen noise_quiet 4 0.0007

cd "$ROOT"
exec swift run -c release vInputBench
