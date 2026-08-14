#!/bin/zsh
# 从日常使用产生的日志里，被动核对那些需要真实硬件、无法单元测试的验收项。
#
# 为什么存在：这些项（断连、重连、录音中途掉线）都需要有人去拔电池、
# 走出蓝牙范围。与其安排一场专门的测试，不如让日常使用自己留下证据——
# 遥控器早晚会没电、会走出范围，届时日志里就有了。
#
# 用法：./scripts/acceptance-scan.sh [日志路径]

set -euo pipefail
LOG="${1:-$HOME/Library/Logs/vInput/vInput.log}"

if [[ ! -f "$LOG" ]]; then
  print -u2 "找不到日志: $LOG"
  exit 1
fi

print "日志: $LOG"
print "范围: $(head -1 "$LOG" | cut -c1-14) → $(tail -1 "$LOG" | cut -c1-14)"
print ""

# 各项打印「✅ 已被动验证」或「⬜ 尚无证据」，后者不是失败，
# 只是说明这个场景在日常使用中还没自然发生过。
check() {
  local label="$1" count="$2" detail="${3:-}"
  if (( count > 0 )); then
    print "✅ $label（$count 次）"
    [[ -n "$detail" ]] && print "   $detail"
  else
    print "⬜ $label —— 尚无证据"
  fi
}

disconnects=$(grep -c "BLE DISCONNECTED" "$LOG" || true)
check "遥控器断连被记录" "$disconnects"

# 断连后又出现 READY，即自动重连成功。用行号比较，避免跨会话误判。
reconnects=$(awk '
  /BLE DISCONNECTED/ { pending = 1 }
  /BLE READY/        { if (pending) { n++; pending = 0 } }
  END                { print n + 0 }
' "$LOG")
check "断连后自动重连成功" "$reconnects"

# 最关键的一项：录音中途断连，已说的内容是否仍被转写注入。
# 规则二「永不丢字」在蓝牙路径上的体现。
midrecord=$(grep -c "BLE DISCONNECTED.*streaming=true" "$LOG" || true)
if (( midrecord > 0 )); then
  saved=$(awk '
    /BLE DISCONNECTED.*streaming=true/ { pending = 1; next }
    pending && /注入成功/              { n++; pending = 0 }
    pending && /遥控器语音键按下/       { pending = 0 }   # 新会话开始，上一次没救回来
    END { print n + 0 }
  ' "$LOG")
  if (( saved == midrecord )); then
    check "录音中途断连不丢字" "$saved" "$midrecord 次中途断连，全部完成注入"
  else
    print "❌ 录音中途断连丢字：$midrecord 次中断，仅 $saved 次完成注入"
    print "   这违反规则二，请查日志中 streaming=true 的断连点"
    exit 1
  fi
else
  check "录音中途断连不丢字" 0
fi

print ""
print "说明：⬜ 表示该场景在日常使用中尚未自然发生，不是失败。"
print "「蓝牙关闭文案」已由 RemoteConnectionI18nCoverageTests 覆盖，不在此列。"
