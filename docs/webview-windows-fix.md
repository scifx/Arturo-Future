# Windows `webview` 修复说明

对应上游 [arturo-lang/arturo#2209](https://github.com/arturo-lang/arturo/issues/2209)，
示例来自讨论 [arturo-lang/arturo#2208](https://github.com/arturo-lang/arturo/discussions/2208)。

## 1. 出发点

`webview` 的对外形状已经很好，不该动：

```red
webview.debug {!html
    <a href="#" onclick="printHello()">Click me</a>
    <script>
        function printHello() {
            arturo.exec('print "Hello from the webview!"');
            arturo.call("odd?", 123).then(function (result) {
                console.log(result);
            });
        }
    </script>
}
```

Linux 上这段能跑。Windows 上同一份脚本会撞三面墙：

1. 第一次打开 `arturo` 还没挂上，要手动刷新才行
2. 窗口多出 File / Share 菜单，点谁都打印 `Shared to Instagram`
3. `arturo.call` 对简单值（`odd? 123`）还能回来；稍微复杂的用户函数，shell 里打印正常，页面拿不到返回值

这不是新功能，是把 Windows 拉回和 Linux 一样的「打开就能用」。

原则和这个仓库其它改动一样：

> **不发明新概念。** 不新增 `arturo.ready`、不新增 `:bridge`、不加 `.menu`。
> 页面上还是 `arturo.call` / `arturo.exec`，窗口还是一个干净的 webview。

## 2. 三面墙，三处根因

### 2.1 第一次加载看不到 `arturo`

`newWebView` 以前的顺序是：

```
set_html / navigate     ← WebView2 立刻开始导航
webview_init(arturo.js) ← AddScriptToExecuteOnDocumentCreated 只对「之后」的文档生效
webview_bind(callback)
```

WebKitGTK 上 `load_html` 够慢，用户脚本赶得上 document-start。WebView2 的
`NavigateToString` 会抢跑：第一份文档带着页面脚本出生，桥还没注册。
刷新之后脚本已经挂上，于是「只有刷新才能跑」。

讨论区 Win 11 上的 `Uncaught SyntaxError: Invalid or unexpected token` 是同一条路上的另一个坑：
Windows 下 `{!html ...}` 会把换行写成 CR LF，再原样塞进 `<script>`。

### 2.2 菜单是误留的演示代码

`show*` 里整段 File / New / Share / Instagram 是有人在试 `newMenu` 时留下的。
Linux 上 `gtk_container_add` 把菜单条塞进已经有 webview 的 GtkWindow，看起来像「没有菜单栏」；
Windows 上 `SetMenu` 会真的画出来。

更糟的是回调表用 `userData` 当键，而 `addItem` 默认 `userData = nil`。
Facebook / Twitter / Instagram 三个闭包全写进 `menuCallbacks[nil]`，
最后一个（Instagram）赢。所以「点谁都是 Shared to Instagram」。

### 2.3 复杂返回值到不了页面

两件事叠在一起：

- `returned = jsonFromValue(...).cstring` 立刻丢掉了拥有那段内存的 Nim `string`。
  短 JSON（`true` / `123`）偶尔还能活过 `webview_return`；字典、长字符串、带中文的结构更容易被 GC 收走，JS 侧 `JSON.parse` 失败或拿到垃圾。
- `generateJsonNode` 对 Function / Binary / Complex 等是 `discard`，`result` 是 nil。
  用户函数只要返回一个**里面含有函数**的字典，序列化就会炸或吐出非法 JSON。
- `FunctionCall` 没有 `try/except`（`ExecuteCode` 有）。复杂函数一抛错，Promise 永远不 settle，页面元素也就不会被赋值。

「shell 里输出正常、webview 拿不到」对得上这三条。

## 3. 改了什么（表层不变）

页面 API 一字不改：`arturo.call`、`arturo.exec`、`window\title` 还是原来的词。

| 位置 | 改动 |
|---|---|
| `helpers/webviews.nim` | **先** `init` + `bind`，**再** `set_html` / `navigate`；HTML 统一成 LF，片段包一层带 `charset=utf-8` 的文档；回包用局部 `payload: string` 活过 `webview_return`；拆掉演示菜单 |
| `helpers/webviews.js` | 挂到 `window.arturo`；`callback` 还没到就排队等几秒，而不是立刻 `ReferenceError`；不用模板字符串 / 箭头函数 |
| `helpers/windows.nim` | 每个菜单项用自己的 `MenuItem` 指针当身份，写进 C 层 `userData` |
| `helpers/jsonobject.nim` | `generateJsonNode` 永远返回节点；不可序列化的句柄是 `null`；`jsonFromValue` 再挡一层 nil |
| `library/Ui.nim` | `FunctionCall` 和 `ExecuteCode` 一样包 `try/except`；缺 `args` 当空块；删掉 `eval` 里的调试 `echo` |

完整文档页如果用户自己写了 `<!DOCTYPE>` / `<html>`，不会被再包一层。

## 4. 明确不做的事

- 不改 `webview` 的属性表，不加 `.menu`。菜单 API 修好了，但默认窗口仍然是裸的，和 Linux 一致。
- 不把 `{!html}` 的 CR LF 行为改成全局——那会动到所有 Windows 多行字符串。只在送进 webview 之前折成 LF。
- 不把 Windows 从预编译 `webview.dll` 改成静态编 `webview-windows.h`。这次的根因都在 Nim / JS 这一侧，DLL 不用动。
- 不新增 JS 辅助对象。`arturo` 还是那一个。

## 5. 怎么验证

本环境没有 WebView2，也没有现成的 `arturo` 二进制。可重复跑的是桥和算法：

```bash
node tests/webview/test_bridge.js
python3 tests/webview/test_webview.py
```

它们覆盖：

- 第一次加载就有 `window.arturo`，`callback` 晚到也能把 `call` / `exec` 发出去
- 复杂字典 / 长字符串 / 中文往返
- 菜单项身份不再撞在 `nil` 上
- `init`/`bind` 源码顺序在 `set_html` 之前，演示菜单已经不在

手测（有 Windows 构建时）直接跑讨论区那份脚本：

```bash
arturo examples/simplewebview.art
```

第一次打开点 Click me，不用刷新，控制台应看到 `odd?` / `greet` / `stats` 的返回值；窗口标题栏没有 File/Share。
