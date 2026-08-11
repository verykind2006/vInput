#!/bin/zsh
# 在不稳定网络下拉取 WhisperKit 的 CoreML 模型。
# curl 的 --retry + 断点续传比 WhisperKit 内部的 URLSession 健壮得多。
set -uo pipefail

MODEL="${1:-openai_whisper-base}"
DEST="${0:A:h:h}/vendor/models/$MODEL"
BASE="https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/main/$MODEL"
TREE="https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/main/$MODEL?recursive=true"

mkdir -p "$DEST"

print "获取文件清单…"
curl -sSL --retry 10 --retry-all-errors --retry-delay 3 --max-time 60 "$TREE" -o /tmp/vinput-tree.json || {
  print -u2 "清单获取失败"; exit 1
}

FILES=($(python3 -c "
import json
d = json.load(open('/tmp/vinput-tree.json'))
prefix = '$MODEL/'
for f in d:
    if f['type'] == 'file':
        p = f['path']
        print(p[len(prefix):] if p.startswith(prefix) else p)
"))

print "共 ${#FILES[@]} 个文件"

FAILED=0
for rel in $FILES; do
  out="$DEST/$rel"
  mkdir -p "$(dirname "$out")"
  if [[ -s "$out" ]]; then
    remote_size=$(curl -sSLI --max-time 30 "$BASE/$rel" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{n=$2} END{print n}')
    local_size=$(stat -f%z "$out")
    if [[ -n "$remote_size" && "$remote_size" == "$local_size" ]]; then
      print "  ✓ 已完整: $rel"
      continue
    fi
  fi
  print "  ↓ $rel"
  if ! curl -sSL --retry 20 --retry-all-errors --retry-delay 3 \
       --continue-at - --speed-limit 1024 --speed-time 60 \
       "$BASE/$rel" -o "$out"; then
    print -u2 "  ✗ 失败: $rel"
    FAILED=1
  fi
done

if [[ $FAILED -eq 1 ]]; then
  print -u2 "有文件未拉全，重跑本脚本会断点续传"
  exit 1
fi

print "完成。总大小: $(du -sh "$DEST" | cut -f1)"
print "路径: $DEST"
