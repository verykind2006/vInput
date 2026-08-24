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

## `.build` 被 OneDrive 打上 quarantine，测试加载不了（2026-08-21 遇到）

症状：`swift test` 编译通过，跑起来却报

```
library load disallowed by system policy
```

`dlopen` 加载 `vInputPackageTests.xctest` 失败。成因是仓库在 OneDrive 同步
目录里，同步回来的构建产物被打上 `com.apple.quarantine` 与
`com.apple.FinderInfo` 扩展属性，Gatekeeper 因此拒绝加载。

解法（只碰构建产物，仓库内容一个字节不动）：

```bash
xattr -cr .build
codesign --force --sign - .build/*/debug/vInputPackageTests.xctest
```

排查时注意别误判成代码问题——它和「测试挂了」长得不一样，报错在加载阶段，
一条测试都还没跑。实在反复出现就把 `DERIVED_DATA` / `.build` 挪到同步
目录之外（与 `scripts/decode-sweep.sh` 把缓存挪出 `/tmp` 是同一类卫生问题）。

## OneDrive 会把早就删掉的旧文件整批恢复回仓库（2026-08-24 踩了一天）

**一次同步，四种完全不同的症状**，没有一种指向真正的原因。全部来自同一批
被 OneDrive 恢复的旧文件——**共同特征：权限 `-rwx------`、带 `@` 扩展属性、
未跟踪、时间戳是几天前**。

| 被恢复的 | 症状 |
|---|---|
| `Sources/vInput/RemoteKeySuppressor.swift`（0 字节，08-21） | `error: … multiple producers: Compiling Swift Module 'vInput' (110 sources), Compiling Swift Module 'vInput' (110 sources)`。真正的实现在 `Sources/vInput/Remote/` 下，**SwiftPM 按 basename 生成 `.o`，撞名就报这个** |
| `Tests/vInputTests/ZZTempRatioAnalysis{,2}.swift`（08-18 的临时探针） | 链接失败 `ld: symbol(s) not found`（引用了另一个已经删掉的探针文件） |
| **六个门控标记**：`Bench/.run-config.json`、`.long-audio.json`、`.decode-sweep.json`、`.prompt-sweep.json`、`.translate-sweep.json`、`MouseDecode/.run-config.json` | **所有重型基准套件被打开**：加载真模型、拉起 ANE 与 MLX，单条 544 秒。表现是「测试卡住不动」和 `MLX error: Failed to load the default metallib` |
| `OnboardingWindow.swift.bak`、`default.profraw`、两个 SBC 夹具 | 暂时无害 |

**为什么「今早还好好的」不能作为排除依据**：增量构建复用旧的构建计划时看不见
新出现的文件，**一次完整 re-plan 才会**；门控标记则是同步回来那一刻就生效。

**判定（两条都要跑）**：

```bash
# 一、未跟踪且权限是 700 的文件
git status --porcelain -uall | awk '$1=="??"{print $2}' | \
  while read f; do stat -f "%Sp %N" "$f"; done | grep '^-rwx------'

# 二、门控标记。**`git status` 看不见它们**——全在 .gitignore 里，
#     而它们本该由各个 sweep 脚本的 trap 跑完就删。
ls -la Bench/.*.json MouseDecode/.run-config.json Testing/.*-enabled 2>/dev/null

# 三、同名源文件（上面第一条已经删掉的话这条会是空的）
find Sources Tests -name "*.swift" -exec basename {} \; | sort | uniq -d
```

删之前先确认哪一份是真的（比大小、看 `git status` 里哪份未跟踪）。

## 完整重建会把 `.build` 里的 `mlx-swift_Cmlx.bundle` 冲掉（2026-08-24 遇到）

症状：`Failed to load the default metallib`（配合上一节的门控标记一起出现——
门控关着时根本不会有测试去碰 MLX，所以这条只在两件事叠加时才暴露）。

成因：**SwiftPM 命令行编不了 Metal 着色器**（mlx-swift README 写明的限制，
`scripts/build-app.sh` 开头那段注释讲的就是它），所以 `.build` 里那份
`default.metallib` 不是 SwiftPM 产的。一次完整 re-plan 会把它清掉。

解法（`.xcbuild` 是 `build-app.sh` 的 DerivedData，跑过一次就有）：

```bash
cp .xcbuild/Build/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib \
   .build/arm64-apple-macosx/debug/vInputPackageTests.xctest/Contents/MacOS/mlx.metallib
```

放这个位置是因为它是 mlx 查找顺序的**第一条**（与二进制同目录的
`mlx.metallib`，见 `Source/Cmlx/mlx/mlx/backend/metal/device.cpp` 的
`load_default_library`）。放进 `Contents/Resources/` 里的 SwiftPM bundle 形状
实测**不生效**，而放进 `Contents/MacOS/` 之后 `codesign` 会拒签
（「code object is not signed at all」）——不重签也能跑，别去重签。

## 菜单栏图标「不见了」，先量位置再怀疑代码（2026-08-21 踩过）

作者的机器是 14 寸 MacBook，逻辑分辨率 1470×956，**有刘海**，刘海大致占
x≈645–825。菜单栏右侧排满时（日期、控制中心、搜索、Wi-Fi、电量、输入法、
iCloud、微信、剪映、截图、ChatGPT…从约 880 一路排到最右），**新注册的状态项
只能往左落，第一个空位恰好在刘海底下——既看不见也点不到**。

重启 app 会重新抢位置，所以「昨天还在、今天没了」完全正常，与代码无关。

**判定方法（30 秒，不要靠猜）**：

```bash
osascript -e 'tell application "System Events" to tell process "vInput" \
  to return position of menu bar item 1 of menu bar 2'
```

`menu bar 2` 才是状态栏（`menu bar 1` 是 LSUIElement 应用那个空的主菜单）。
拿到的 x 若落在 645–825，就是被刘海吃了。想看图标长什么样：

```bash
screencapture -x -R$((X-4)),0,44,26 /tmp/i.png && sips -Z 400 /tmp/i.png --out /tmp/i-big.png
```

**解法**：退掉一两个菜单栏常驻应用后重启 vInput（它会拿到刘海右边的位置），
或按住 ⌘ 拖动图标重排。

**这一轮我犯的两个错，一并记下**：

1. **先入为主地怪到刚提交的代码上**。当时刚落地两个 UI 修复，看到图标没了
   就去 bisect 提交，其实两个提交都没碰过图标那条路径。**辅助功能接口早就
   能给出答案**（它报告状态项存在、有尺寸、有坐标），只是我一开始没去问。
2. **切了系统外观做诊断，却没先记原值就「还原」**——用户原本是浅色，我按
   深色还回去了。要改用户机器上的全局设置时：先读、后改、按读到的值还原。
