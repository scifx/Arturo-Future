# 流式 `execute` 与 `request` 设计说明

## 1. 出发点

本仓库已经有一套成熟的惰性 `:iterator` 体系（`helpers/iteratorstate.nim`）：

- `:iterator` 是**被消费的运行时值**，不是"另一个数组盒子"
- 生产者跑在 fiber 里，通过**有界 channel**（容量 256）逐项 yield，天然带背压
- `loop / map / select / filter / take / fold / first / empty?` 等消费者已经全部接入
- `read.lines.stream`、`read.buffer:N` 已经证明了"文件 → 惰性流"的路子

`execute` 和 `request` 是仅剩的两个"必须等到全部结束才给你数据"的大洞：

| 内置函数 | 当前行为 | 问题 |
|---|---|---|
| `execute` | `execCmdEx` 全量捕获 | 长任务/无限输出直接卡死；无法边跑边处理 |
| `request` | `client.request` 全量读 body | SSE / AI token 流完全没法用 |

所以本次改动的原则很清楚：

> **不发明新概念。** 把 `execute` 和 `request` 接到**已有的** `:iterator` 管道上去，
> 复用同一个 channel、同一批消费者、同一套 `next / peek / take / loop / empty?`。

## 2. 表层语法

### 2.1 统一的修饰语义

沿用 `read` 已经确立的约定：

- `.stream` = **"给我迭代器，不要给我值"**（惰性开关）
- 其余属性决定**单位**

于是两个内置函数得到完全一致的形状：

```red
; 单位 = 行（文本流的通用单位，也是管道想要的）
execute.stream "cmd"
request.stream  url data

; 单位 = 定长原始块
execute.stream.buffer:4096 "cmd"
request.stream.buffer:4096 url data

; 单位 = SSE 事件（仅 request）
request.stream.events url data
```

`.buffer:` 的命名直接取自 `read.buffer:N`，不再另造 `.chunk` / `.chunks`。

### 2.2 `execute.stream`

```red
; 边跑边处理，不等命令结束
loop execute.stream "ping -c 5 example.com" 'line [
    print ["<<" line]
]

; 早停：只要前 10 行，进程会被立刻终止
head: take execute.stream "yes hello" 10

; 管道流程
execute.stream "cat huge.log"
    | select.iterator 'l -> contains? l "ERROR"
    | take 20
    | loop => print
```

返回 `:iterator`。退出码在流耗尽之后出现在迭代器对象上：

```red
s: execute.stream "ls /nonexistent"
drain s
print s\exit        ; => 2
```

### 2.3 `request.stream`

**响应的形状不变**——依然是 `#[version: body: headers: status:]`，
只有 `body` 从 `:string` 变成 `:iterator`。这样 `r\status` / `r\headers`
的用法完全不用改，学习成本为零。

```red
r: request.stream "https://example.com/big.txt" ø
print r\status                     ; 头一到就返回，body 还在路上
loop r\body 'line -> print line    ; 边收边处理
```

AI 流式（SSE）—— **不需要写 `.events`**：

```red
r: request.stream.post.json
     "https://api.openai.com/v1/chat/completions"
     #[model: "gpt-4o" stream: true messages: @[...]]

loop r\body 'ev [
    if ev\data <> "[DONE]" ->
        prints ev\json\choices\0\delta\content
]
```

#### SSE 自动识别

服务器用 `Content-Type: text/event-stream` 已经明确声明了"我发的是 SSE"。
既然如此，还要求用户手写 `.events` 就是多余的——而且**忘写不会报错**，
只会静默退回行模式，把一帧拆成 `event: xxx` / `data: {...}` / `""` 三个字符串，
`split.lines` 和 `read.json` 都无从下手。这正是实际使用中踩到的坑。

所以现在：**响应头是 `text/event-stream` 就自动按事件解码**。
`.events` 保留为强制开关（服务器 Content-Type 不规范时用），
`.lines` 是显式的退出通道。

#### 事件形状

每个事件是 `#[event: data: id: retry: json:]`：

| 字段 | 说明 |
|---|---|
| `event` / `id` / `retry` | SSE 规范字段 |
| `data` | **始终**是原始字符串，不做任何加工 |
| `json` | `data` 是 JSON 时自动解析好的值；否则 `:null` |

加 `json` 是因为几乎所有值得流式消费的 SSE（OpenAI 及兼容实现）
`data:` 里装的都是 JSON，让用户对**每一帧**手写 `read.json ev\data` 是纯粹的噪音。
`[DONE]`、心跳、纯文本这些非 JSON 载荷不会报错，`json` 留 `:null`，
而 `data` 永远保底可用。

多行 `data:` 仍按规范用 `\n` 拼接后再尝试解析。

### 2.4 `unplug` —— 提前关闭

`unplug` 当前的语义是"关闭给定的 socket 或 channel"。流是同一类东西，
所以直接扩展它，而不是新造一个 `close-stream`：

```red
s: execute.stream "yes"
print take s 3
unplug s          ; 终止子进程，释放管道
```

## 3. 内部实现

### 3.1 复用 `newProducedIterator`

`iteratorstate.nim` 已经提供了

```nim
newProducedIterator(sourceName, rebuild, producer)
```

它把 `producer` 丢进 fiber，异常自动转成 failure packet，结束自动 `chanClose`。
两个新流都直接建在它上面，**没有新增第二套流机制**。

### 3.2 新增到 `IteratorState` 的两个字段

```nim
meta*      : ValueDict                  ## 额外同步到迭代器对象上的字段（如 exit / pid）
closeHook* : proc() {.closure.}         ## unplug / 耗尽时调用
```

`syncMeta` 顺带把 `meta` 铺到对象上，所以 `s\exit` 天然可读。

### 3.3 子进程流（`helpers/streaming.nim`）

- `startProcess(..., poStdErrToStdOut)`，stderr 并入 stdout（与现有 `execute` 一致）

读管道的方式**必须分平台**，这是踩过的坑：

**POSIX**：`dup()` 出 `outputHandle`，设 `O_NONBLOCK`，包成 `AsyncFile`，
循环 `coopWait af.read(bufSize)`——**真正的增量读取**（已验证 3 行分别在
+0.00 / +0.30 / +0.61s 到达）。

**Windows**：**不能用 `AsyncFile`。** `osproc` 在 Windows 上用 `CreatePipe()`
建管道，产出的是**同步（非 overlapped）句柄**；而 `newAsyncFile()` 会把句柄
塞进 IOCP（`createIoCompletionPort`）并用 `OVERLAPPED` 发 `ReadFile`。
把同步句柄交给 IOCP 会直接失败：

```
Exception message: Invalid parameter.        ; ERROR_INVALID_PARAMETER (87)
  asyncfile.nim(96) newAsyncFile             ; 中文系统显示为「参数错误」
```

而且这个错误在 `newAsyncFile` 就抛了，**跟具体命令无关**——`ls` 和 `ping`
一样炸。所以 Windows 走 `winPipeRead`：

1. `PeekNamedPipe` 探测可读字节数（不阻塞）
2. 有数据 → 同步 `ReadFile` 读出来
3. 没数据 → `coopWait sleepAsync(15ms)` 让出，**不能**直接阻塞 `ReadFile`
   （那会卡死整个调度器，连带所有其它 fiber）
4. 管道断开 / 子进程退出且缓冲已空 → EOF
5. 每轮开头检查 `closed`，避免 `unplug` 关掉句柄后仍在轮询

代价是 Windows 上最坏有 15ms 延迟（POSIX 是事件驱动、零延迟），
但换来的是正确性，且对人眼和管道场景完全够用。

> `request.stream` **没有**这个问题：`AsyncHttpClient` 走的是 async
> **socket**，在 Windows 上本来就是 IOCP 原生支持的，不碰 `asyncfile`。
- 行模式下用一个残留缓冲切行，最后一段不带换行也会吐出
- 结束时 `waitForExit`，把 `exit` 写进 `meta`
- `closeHook` = 关闭 AsyncFile + `p.terminate()`（已验证可以干净地掐掉 `yes`）

### 3.4 HTTP 流（`helpers/streaming.nim`）

- 用 `AsyncHttpClient`，`coopWait client.request(...)` —— **头到即返回**
- body 用 `resp.bodyStream.read()` 逐块拉（`FutureStream[string]`，已验证 3 个 chunk 分别在 +0.20 / +0.50 / +0.80s 到达）
- 行模式 / SSE 模式在同一个残留缓冲上做切分
- `closeHook` = `client.close()`

### 3.5 背压

生产者 fiber 走的是 `emitIteratorValue → chanSend`，容量 256 的有界 channel。
消费者不取，生产者就在 `chanSend` 上挂起，不再从 socket / 管道读，
TCP 窗口和管道缓冲自然把压力传回上游。**背压是免费拿到的**，因为复用了既有 channel。

## 4. 明确不做的事

- 不新增 `:stream` 类型。流就是 `:iterator`，消费者一个都不用改。
- 不改 `execute` / `request` 的默认行为。不加 `.stream` 时字节级兼容。
- 不做 stdin 写入（`execute` 交互式喂数据）——那是另一个正交特性。
- 不动 `read.lines.stream` 的既有形状。
