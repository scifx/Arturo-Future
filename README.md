<div align="right">

**简体中文** | [English](./README.en.md)

</div>

<div align="center">

<img align="center" width="150" src="docs/images/logo.png#gh-light-mode-only"/>
<img align="center" width="150" src="docs/images/logo-lightgray.png#gh-dark-mode-only"/>

# Arturo-Future

### 对 [Arturo](https://github.com/arturo-lang/arturo) 语言的激进实验分支

[![License](https://img.shields.io/github/license/arturo-lang/arturo?style=for-the-badge)](LICENSE)
![Language](https://img.shields.io/badge/language-Nim-6A7FC8.svg?style=for-the-badge)
![Status](https://img.shields.io/badge/status-experimental-orange.svg?style=for-the-badge)
[![Upstream](https://img.shields.io/badge/upstream-arturo--lang%2Farturo-blue.svg?style=for-the-badge)](https://github.com/arturo-lang/arturo)

[这是什么](#这是什么) · [已添加特性](#已添加的特性) · [待添加](#待添加的特性) · [致谢与捐赠](#致谢与捐赠)

</div>

---

> **这不是官方 Arturo。**
>
> 本仓库是 [scifx](https://github.com/scifx) 从 [arturo-lang/arturo](https://github.com/arturo-lang/arturo) 分出的实验分支。目标不是替代上游，而是把日常使用中撞到的墙——尤其是我在上游提过、一时还排不上的那些 [issue](https://github.com/arturo-lang/arturo/issues?q=is%3Aissue%20author%3Ascifx)——自己动手、借助 AI 先做出来。
>
> 需要稳定、官方、可预期的 Arturo，请直接去上游：
>
> **[arturo-lang/arturo](https://github.com/arturo-lang/arturo)** · **[arturo-lang.io](https://arturo-lang.io/)**

---

## 这是什么

[Arturo](https://arturo-lang.io/) 是一门独立发展的现代脚本语言，血统上能看到 Logo、Rebol、Forth、Ruby、Haskell、Smalltalk、Tcl、Lisp 的影子。它用 Nim 写成，原则很干净：

- 代码只是词、符号和字面量的列表
- 词和符号按上下文解释
- **没有任何保留字**

```red
factorial: function [n][
    switch n > 0 -> n * factorial n-1
                 -> 1
]

loop 1..19 [x]->
    print ["Factorial of" x "=" factorial x]
```

我喜欢它写起来像按计算器：字少、负担小、解决问题快。用久了也会撞墙——中文标识符被解析器悄悄丢掉、REPL 里一输入汉字就烂、大文件必须整份读进内存、`execute` / `request` 必须等全部结束才给你数据、循环在大数据上吃内存。

**Arturo-Future** 就是针对这些墙的激进尝试。当前基于上游 `0.10.x`（本仓库版本号 `0.10.1-dev`）。默认行为尽量与上游字节级兼容；新能力用属性开关打开，例如 `.stream`、`.iterator`。

---

## 和上游差在哪

| | 上游 Arturo | 这个分支 |
|---|---|---|
| 定位 | 官方语言实现 | 激进实验场 |
| 标识符 | ASCII only，中文会被解析器默默丢掉 | UTF-8 / 中文标识符可作为 word |
| REPL | linenoise 按字节处理，多字节字符编辑会损坏 | REPL 按码点处理 UTF-8 输入 |
| 集合消费 | 多数路径先物化成 block | 真正的惰性 `:iterator`，按项 yield |
| 大文件 | `read.lines` 整文件进内存 | `read.lines.stream` / `read.csv.stream` / `read.buffer:N` |
| 子进程 | `execute` 全量捕获 stdout | `execute.stream` 边跑边消费，可早停并杀掉进程 |
| HTTP | `request` 全量读 body | `request.stream` 头到即返回；支持 SSE / LLM token 流 |
| 错误输入 | 残缺 `if` / 未闭合括号可能挂死 | 解析器预检 + 求值守卫，快速报「参数不足」 |
| 构建 | 官方多平台发行 | 源码构建；另有 Termux / Android 实验路径 |

**兼容原则：** 不加新属性时，`execute`、`request`、`read`、`map` 等默认语义保持 eager，尽量不破坏现有脚本。

---

## 特色

### 1. 中文就是一等标识符

上游解析器只认 ASCII 字母作 word 起点，`你好` 会被按字节跳过。这里按 rune 识别字母，中文可以直接当函数名、参数名、变量名：

```red
阶乘: function [n][
    switch n > 0 -> n * 阶乘 n-1
                 -> 1
]

问好: function [名字][
    print ["你好," 名字]
]

问好 "世界"
loop 1..10 'x -> print ["阶乘" x "=" 阶乘 x]
```

REPL 里编辑多字节字符也不再把 `你` 拆成烂字节。这是我在上游提的 [#2170](https://github.com/arturo-lang/arturo/issues/2170)、[#2211](https://github.com/arturo-lang/arturo/issues/2211)，现在先在这个分支落地。

### 2. `:iterator` 不是「另一个数组盒子」

不发明新的 `:stream` 类型。迭代器是**被消费的运行时值**：生产者跑在 fiber 里，经容量 256 的有界 channel 逐项 yield，消费者不取，生产者就停——背压是白送的。

```red
; 54MB / 100 万行的日志，只要前 10 行：不必整文件进内存
head: take read.lines.stream "huge.log" 10

; 惰性变换管线，只算用到的部分
1..1000000
    | map.iterator 'x -> x * 2
    | filter.iterator => odd?
    | take 10
```

同一套消费者吃所有源：`loop` / `map` / `select` / `filter` / `take` / `fold` / `first` / `empty?` / `enumerate` / `gather` / `chunk` / `cluster`……

### 3. 流是统一的：文件、进程、HTTP、LLM

`.stream` 的约定只有一句：**给我迭代器，不要给我值。**

```red
; 子进程：边 ping 边处理；take 10 行就会杀掉 yes
loop execute.stream "ping -c 5 example.com" 'line [
    print ["<<" line]
]
head: take execute.stream "yes hello" 10

; HTTP：响应形状不变，只有 body 从 :string 变成 :iterator
r: request.stream "https://example.com/big.txt" ø
print r\status
loop r\body 'line -> print line

; SSE / LLM token 流
r: request.stream.events.post.json
     "https://api.openai.com/v1/chat/completions"
     #[model: "gpt-4o" stream: true messages: @[...]]

loop r\body 'ev [
    if ev\data <> "[DONE]" ->
        prints (read.json ev\data)\choices\0\delta\content
]
```

`unplug` 可以提前关掉流（终止子进程 / 关闭 HTTP 客户端）。

### 4. 实测过的内存优势

约 54MB / 1,000,000 行文本，以及 `1..1000000` 的惰性变换（沙箱实测）：

| 场景 | eager | stream / iterator |
|---|---|---|
| 读文件只取前 10 行 | ~0.175 s · ~290 MB | **~0.006 s · ~10 MB** |
| `map` 后取前 10 项 | ~0.138 s · ~100 MB | **~0.006 s · ~18 MB** |
| `filter` 后取前 10 项 | ~0.136 s · ~57 MB | **~0.006 s · ~16 MB** |
| 全量扫完所有行 | ~0.19 s · ~300 MB | ~0.44 s · **~16 MB** |

早停场景是数量级的胜利。全量扫描仍然更省内存，但目前比 eager 慢——fiber / channel 的逐项开销还是下一刀优化点。

### 5. 残缺输入不再把进程卡死

光秃秃的 `if`、没写完的 `while [1]`、悬空的 `[` / `=>` / `:`，以前可能挂在解析器或求值优化里。现在会快速失败，并给出像样的错误。这不是新语法，是把语言从「一写错就卡死」拉回来。

---

## 已添加的特性

相对上游，这个分支已经合入、并且有测试或设计文档托底的部分：

### 语言 / REPL

- [x] UTF-8 标识符：中文等非 ASCII 字符可作为 word（对应上游 [#2170](https://github.com/arturo-lang/arturo/issues/2170)）
- [x] REPL UTF-8 输入与编辑：多字节字符不再被按字节撕碎（对应上游 [#2211](https://github.com/arturo-lang/arturo/issues/2211)）
- [x] 解析器结构预检：未闭合括号、未结束字符串、悬空 `:` / `=>` / `->` 快速报错
- [x] 求值器守卫：残缺的 `if` / `unless` / `while` / `switch` 报「参数不足」，不再挂死或崩

### 迭代器与生成器

- [x] 语言级 `:iterator` 原型（`to :iterator` / `iterator` / `iterator?`）
- [x] `generator` + `yield`：真正的逐项产出，不是先落成另一份列表
- [x] `next` / `peek` / `rewind` / `drain`
- [x] `@iterator` / `array iterator` / `to :block` 物化
- [x] `loop` / `map` / `select` / `filter` / `collect` / `fold`（左折）吃 iterator
- [x] `enumerate` / `every?` / `some?` / `maximum` / `minimum`
- [x] `gather` / `cluster` / `chunk`
- [x] `map.iterator` / `filter.iterator` / `select.iterator`：返回 `:iterator` 的惰性变换
- [x] `take` / `take.iterator` / `drop` / `drop.iterator` / `first` / `first.n` / `empty?`

### 流式 IO

- [x] `read.lines.stream`：按行惰性读本地文件
- [x] `read.csv.stream`：按行惰性读 CSV
- [x] `read.buffer:N` / `read.binary.buffer:N`
- [x] `write.buffer:N` / `write.binary.buffer:N`
- [x] `.seek:`、`seek` / `seek.relative` / `seek.end`、`tell`
- [x] `print.lines` 可直接消费 iterator
- [x] `read.*.iterator` 仅作兼容别名，规范名是 `read.*.stream`

### 进程与网络流

- [x] `execute.stream` / `execute.stream.buffer:N`：子进程 stdout 接到 `:iterator`
- [x] 流耗尽后可从迭代器读 `exit`；`unplug` 终止子进程
- [x] `request.stream` / `request.stream.buffer:N`：HTTP 头到即返回，`body` 为 iterator
- [x] `request.stream.events`：按 SSE 分帧，事件形如 `#[event: data: id: retry:]`
- [x] POSIX 上异步增量读管道；Windows 上避开同步 pipe + IOCP 的坑，用 `PeekNamedPipe` 协作读取

### 平台与工程

- [x] Termux / Android 构建实验（`build.sh`、`termux` 分支；对应上游 [#1971](https://github.com/arturo-lang/arturo/issues/1971)）
- [x] 畸形输入压力测试：`tests/robustness_malformed.py`、`tests/robustness_fuzz_prefixes.py`
- [x] 迭代器 / 文件 / 现实场景单测与基准脚本
- [x] Windows `webview`：第一次打开就能调 `arturo.call` / `arturo.exec`，去掉误留的 File/Share 菜单，复杂返回值能回到页面（对应上游 [#2209](https://github.com/arturo-lang/arturo/issues/2209)）

设计与验证笔记：

- [docs/iterator-optimization-plan.md](docs/iterator-optimization-plan.md)
- [docs/iterator-workboard.md](docs/iterator-workboard.md)
- [docs/iterator-validation-report.md](docs/iterator-validation-report.md)
- [docs/streaming-design.md](docs/streaming-design.md)
- [docs/robustness-workboard.md](docs/robustness-workboard.md)
- [docs/robustness-validation-report.md](docs/robustness-validation-report.md)
- [docs/webview-windows-fix.md](docs/webview-windows-fix.md)

---

## 待添加的特性

下面留给后续自己填。做完一项，就挪到上面的「已添加」。

- [ ]
- [ ]
- [ ]
- [ ]
- [ ]

---

## 上游 Issue，这边先做

这些是我在 [arturo-lang/arturo](https://github.com/arturo-lang/arturo) 提过的问题。上游作者很友好，其中不少也在推进；这个 fork 的意思是：**等不及的，自己借助 AI 先实现。**

已经在本分支对上的：

| 上游 issue | 这边的落地 |
|---|---|
| [#2170](https://github.com/arturo-lang/arturo/issues/2170) 解析器丢掉 UTF-8 / 中文标识符 | 按 rune 识别 identifier |
| [#2211](https://github.com/arturo-lang/arturo/issues/2211) REPL 多字节输入损坏 | 修复 UTF-8 编辑路径 |
| [#1971](https://github.com/arturo-lang/arturo/issues/1971) Termux 编译失败 | `build.sh` + `termux` 实验分支 |
| [#1972](https://github.com/arturo-lang/arturo/issues/1972) 循环性能 / 大数据 | 惰性 iterator，早停场景内存和延迟都下来了 |
| [#2209](https://github.com/arturo-lang/arturo/issues/2209) Windows webview 首次加载 / 菜单 / 复杂返回值 | 先 bind 再导航；拆掉演示菜单；JSON 回包保活 |

其余仍开放的（闭包、glob、`env` 可写、stdin/stdout/stderr、日期差值、`serve` POST 崩溃、`read.json` 安全等）是我自己的问题清单。有进展会写进「已添加」；具体下一步只记在上面的空列表里。

完整列表：<https://github.com/arturo-lang/arturo/issues?q=is%3Aissue%20author%3Ascifx>

---

## 还没做、也先说清楚的限制

不是隐藏缺点，是设计边界：

- `:iterator` 目前是对象原型，还不是 VM 原生 `ValueKind`
- `.parallel` 尚未与 iterator 打通
- `fold.right` / `select.last` / `filter.last` / `reverse` 依赖随机访问，单向流上明确禁用
- 全量扫描仍比 eager 物化慢，逐项 channel/fiber 开销还要削
- `execute.stream` 暂不支持往子进程 stdin 里写
- Windows 子进程流最坏约 15ms 轮询延迟（正确性优先）
- 没有官方预编译包；要这个分支的特性，请从源码构建

---

## 构建

需要 **Nim** 和一套 C/C++ 编译器。部分功能还依赖系统库（SSL 等）。

```bash
git clone https://github.com/scifx/Arturo-Future.git
cd Arturo-Future

./build.nims                  # 默认完整构建 → bin/arturo
./build.nims --mode:mini      # 更小的 mini 构建
./build.nims --install        # 装到 ~/.arturo/bin
./build.nims test             # 测试套件

# 简便包装（full + release + log，无 UI）
./build.sh
```

想要官方稳定版、现成二进制、Docker 或 Homebrew，请走上游，不要用这个实验分支冒充发行版：

- 下载：<https://arturo-lang.io/#download>
- 一键安装：`curl -sSL https://get.arturo-lang.io | sh`
- Nightly：<https://github.com/arturo-lang/nightly/releases>
- 构建说明：<https://github.com/arturo-lang/arturo/wiki/Building-Arturo>

语言文档同样以官方为准：<https://arturo-lang.io/documentation/>

---

## 致谢与捐赠

Arturo 是 [Yanis Zafirópulos](https://github.com/drkameleon)（Dr.Kameleon）从 2019 年起，用自己的业余时间做出来的。没有他，没有这门语言，也就没有这个 fork。维护者 [RickBarretto](https://github.com/RickBarretto) 以及所有上游贡献者，同样值得感谢。

**请支持原作者，而不是这个实验分支。**

这个仓库不接受捐赠。如果你因为 Arturo 觉得开心、好用、或者只是想让它走得更远，请把支持送给上游：

### 如何捐赠（渠道与上游完全相同）

主渠道是 **[GitHub Sponsors](https://github.com/sponsors/drkameleon)**。

也可以加密货币：

- **BTC**: `bc1qpjlmktrz79muz4yksm8aadz3d3srh0rmnn3hhd`
- **ETH**: `0x8552a389ea3d77e0e13573a642cff5ef745447b9`
- **SOL**: `FS47tEruHesSbWFPdhqbJpixtwHVgU38DvJYYYLRk2MS`

也可以同时支持维护者：[GitHub Sponsors @RickBarretto](https://github.com/sponsors/RickBarretto)

### 上游已公开的 Sponsors

Every little bit counts and the least we could do is to thank you all for your help and making us stick to the project:

<a href="https://github.com/BNAndras"><img align="center" width="50" src="https://avatars.githubusercontent.com/u/20251272?v=4"/></a>

---

## 社区

- 官方仓库与 issue：<https://github.com/arturo-lang/arturo>
- 本 fork 的讨论与实验：<https://github.com/scifx/Arturo-Future/issues>
- Discord：<https://discord.gg/YdVK2CB>
- 官网：<https://arturo-lang.io/>

这个分支欢迎好奇的人来玩、来挑错、来提更狂一点的想法。能回馈上游的修复，会尽量整理成可独立提交的补丁。

---

## 许可证

MIT License

Copyright (c) 2019-2026 Yanis Zafirópulos (aka Dr.Kameleon)

本 fork 中由 scifx 新增的实验性改动同样以 MIT 授权，并保留上游版权声明。完整文本见 [LICENSE](LICENSE)。
