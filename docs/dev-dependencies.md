# 依赖获取：本机网络的应对

本仓库的两个大依赖都无法在本机网络下直接由 SwiftPM 拉取。这份文档记录
症状、成因与重建方法。

## 症状

`swift package resolve` 克隆 `mlx-swift` 时必断：

```
Receiving objects:  52% (13965/26709), 9.93 MiB | 20.00 KiB/s
error: RPC failed; curl 92 HTTP/2 stream 5 was not closed cleanly: CANCEL (err 8)
fatal: early EOF
fatal: fetch-pack: invalid index-pack output
```

`mlx-swift` 有两万多个对象，在 20 KB/s 的速率下必然触发 HTTP/2 的流超时。
仓库越大越必然——小仓库（`swift-collections`、`swift-argument-parser`）
反而能直接拉成功。

## 成因与解法

**改用 HTTP/1.1 即可。** 这是 HTTP/2 多路复用在长时间、低速率连接下的
已知问题，与代理或防火墙无关。

不改全局 git 配置（那会影响用户的其他项目），而是在克隆时用 `-c` 临时指定，
把仓库预先克隆到本机，再经 SwiftPM 的**本地镜像**机制接上。这样
`Package.swift` 里仍写着正式的 GitHub URL，换机器或网络恢复后删掉镜像即可。

## 重建方法

镜像仓库放在 `~/Library/Application Support/vInput/spm-mirrors/`
（**刻意不放 `vendor/`**：本仓库位于 OneDrive 同步目录下，几十 MB 的
git 对象没有必要占用云端配额，模型权重同理）。

```bash
M=~/Library/Application\ Support/vInput/spm-mirrors
mkdir -p "$M" && cd "$M"

clone() {
  local url=$1 dir=$2
  [ -d "$dir/.git" ] && return 0
  for i in $(seq 1 15); do
    git -c http.version=HTTP/1.1 -c http.postBuffer=524288000 \
        -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=120 \
        clone --no-checkout "$url" "$dir" && return 0
    rm -rf "$dir"; sleep 10
  done
  return 1
}

clone https://github.com/ml-explore/mlx-swift-examples mlx-swift-examples
clone https://github.com/ml-explore/mlx-swift              mlx-swift
clone https://github.com/huggingface/swift-transformers    swift-transformers
clone https://github.com/1024jp/GzipSwift                  GzipSwift
clone https://github.com/huggingface/swift-jinja.git       swift-jinja
clone https://github.com/apple/swift-numerics              swift-numerics
clone https://github.com/apple/swift-docc-plugin           swift-docc-plugin
```

`--no-checkout` 只取 git 对象、不展开工作区，省一半磁盘。**不要用
`--depth 1`**：SwiftPM 需要完整标签历史来解析版本约束。

然后在仓库根目录注册镜像：

```bash
cd /path/to/vInput
M="$HOME/Library/Application Support/vInput/spm-mirrors"
for pair in \
  "https://github.com/ml-explore/mlx-swift-examples:mlx-swift-examples" \
  "https://github.com/ml-explore/mlx-swift:mlx-swift" \
  "https://github.com/huggingface/swift-transformers:swift-transformers" \
  "https://github.com/1024jp/GzipSwift:GzipSwift" \
  "https://github.com/huggingface/swift-jinja.git:swift-jinja" \
  "https://github.com/apple/swift-numerics:swift-numerics" \
  "https://github.com/apple/swift-docc-plugin:swift-docc-plugin" ; do
  swift package config set-mirror --original "${pair%:*}" --mirror "$M/${pair##*:}"
done

swift package resolve
```

**`--original` 必须与被依赖方声明的 URL 逐字一致**，包括 `.git` 后缀——
`swift-transformers` 声明的是 `https://github.com/huggingface/swift-jinja.git`，
少了 `.git` 镜像就不生效，表现为 resolve 又开始走网络、长时间无输出。

## 传递依赖是怎么找出来的

一层层查出来的，没有捷径：先镜像直接依赖，`resolve` 卡住时再看是谁没被
镜像。查某个版本声明了什么依赖：

```bash
git -C "$M/swift-transformers" show 1.0.0:Package.swift | grep '\.package(url'
```

最终 8 个依赖里有 2 个（`swift-collections`、`swift-argument-parser`）
没做镜像也能直接拉成功，因此不在上面的名单里。若它们某天也开始失败，
按同样方法补上即可。

## 镜像配置为何不进版本库

`.swiftpm/configuration/mirrors.json` 里是本机绝对路径，提交它对别的机器
毫无意义，还会把用户名带进仓库。已在 `.gitignore` 中排除，重建方法即本文档。

## WhisperKit

M1 时因同样的网络问题改成了 `vendor/WhisperKit` 本地路径依赖（v1.1.0 的
浅克隆），至今未改回。它比镜像方案更早、也更粗糙——`Package.swift` 里写
的是本地路径而非正式 URL。网络条件改善后，两者都应回归远程依赖。
