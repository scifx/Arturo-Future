# Arturo 迭代器化与性能优化计划

## 当前原型状态

当前原型不直接新增底层 `ValueKind.Iterator`，而是先基于现有 `Object + Prototype` 体系提供语言级 `:iterator` 类型原型。

但这次设计有一个明确原则：

> `:iterator` 不是“另一个数组盒子”。
> `to :iterator` / `generator` 都必须走真正的逐项产出（yield）路径，避免把完整输入先落成列表。

### 当前表层 API

- `to :iterator <value>`
- `iterator <value>`（友好别名）
- `generator [args][body]`
- `yield <value>`
- `iterator?`
- `next`
- `peek`
- `rewind`
- `to :block <iterator>`
- `drain <iterator>`（兼容别名，后续应弱化）
- `read.lines.stream <file>`：按行惰性读取本地文件

### 当前内部实现原则

1. **`to :iterator` 不复制整个输入集合**
   - `block`：顺序遍历原 block
   - `range`：按步进动态生成
   - `string`：按 rune 惰性产出
   - `dictionary/object`：顺序产出键值对
   - `integer`：动态生成 `1..N`

2. **`generator` 返回的是“生成迭代器的工厂”**
   - 表层上它像 `function`
   - 真正调用时返回 `:iterator`
   - `yield` 在内部通过 channel / fiber 协作逐项送值

3. **文件流必须是真流式**
   - `read.lines.stream` 不应把 10GB 文本整个读进内存
   - 必须逐行读取、逐行产出

这样做的优点：

1. 改动面小，先打通语言层能力。
2. 可以尽快验证语义、命名与语言美感是否成立。
3. 后续若要升级为真正的 VM 原生类型，可以复用这套接口。

## 已接入的迭代器消费路径

同步迭代型 API 已开始支持 `:iterator` 作为输入：

- `loop`
- `map`
- `select`
- `filter`
- `collect`
- `fold`（仅 left fold）
- `enumerate`
- `gather`
- `chunk`
- `cluster`
- `maximum`
- `minimum`
- `every?`
- `some?`
- `take`
- `empty?`
- `arrange`（语义可用，但排序天然要落地）

## 明确区分：哪些必须迭代器化，哪些不需要

### 一、强烈建议迭代器化/流式化

这些操作的共同特点是：**数据量可能非常大，且业务通常只需要顺序扫描**。

#### 1. 文件读取

- `read.lines.stream`
- 后续可扩展：`read.csv.stream`
- 后续可扩展：大文本 `read.chunks.stream`

原因：
- 当前全量读入会直接放大峰值内存。
- 大文件、日志、ETL、grep 类任务天然适合单遍消费。

#### 2. 顺序扫描类迭代

- `loop`
- `enumerate`
- `every?`
- `some?`
- `maximum`
- `minimum`
- `gather`
- `cluster`
- `chunk`

原因：
- 它们天然是单遍扫描。
- 不需要完整保留源集合。
- 很适合直接消费 iterator。

#### 3. 具备短路能力的操作

- `select.first`
- `filter.first`
- `collect`
- `collect.after`
- `some?`
- `every?`
- `take`

原因：
- 很多场景只需要前几个结果，或在满足条件后立即停止。
- 迭代器可以把“早停”价值最大化。

### 二、可以接收迭代器，但结果仍然要落地

#### 1. `map`

原因：
- 源集合可以流式消费。
- 但结果仍然要形成新 block。
- 所以只能减少**输入侧**峰值内存，无法消除**输出侧**内存。

#### 2. `select`

原因：
- 输入可流式。
- 输出结果仍然要收集。

#### 3. `arrange` / `sort`

原因：
- 排序本质上需要全量数据。
- 允许 iterator 输入没问题，但内部仍必须 materialize。
- 它是“兼容迭代器”，不是“真正流式”。

### 三、不适合直接迭代器化，或必须先落地

这些操作依赖随机访问、反向遍历、切片、重复遍历。

- `fold.right`
- `select.last`
- `filter.last`
- 所有依赖 `reverse`
- 所有依赖尾部切片 / 回看历史 / 多次扫描 的实现
- 并行 `.parallel` 分支（当前原型暂时禁用 iterator 输入）

原因：
- 迭代器天生偏单向、单遍。
- 这些语义需要 random access / replay / reverse。
- 若强行支持，最终还是要把数据落成 block，失去节省内存的意义。

## 循环效率优化建议

### 已有问题

语言中仍有一些路径倾向于先把输入物化：

- `String -> seq[Value]`
- `Integer -> [1..N]`
- `Dictionary/Object -> flattened key/value block`
- 并行分支 `fetchIterableItemsForParallel`

这会带来：

- 额外分配
- GC 压力
- 大输入下内存峰值上涨

### 下一步建议

#### 第一阶段：把“同步单遍扫描”优先改成直接消费 iterator/state

优先级最高：

1. `loop`
2. `enumerate`
3. `every?` / `some?`
4. `maximum` / `minimum`
5. `collect` / `filter.first` / `select.first`
6. `chunk` / `cluster` / `gather`
7. `take` / `drop` / `first`

#### 第二阶段：给更多数据源补“懒源”

建议新增内部 source adapter：

- file lines stream
- csv row stream
- string rune iterator
- dictionary pair iterator
- object pair iterator
- integer generator iterator
- range iterator

#### 第三阶段：把高层 API 的输入层统一抽象

当前 `doIterate` 仍同时维护：

- range fast-path
- block/materialized path
- iterator path

后续可以逐渐统一为：

- `IterationSource`
  - `next()`
  - `peek()`
  - `rewind?()`
  - `remainingHint()`
  - `supportsReverse`
  - `supportsParallelMaterialize`

这样能把很多 template 分支收敛掉。

## 是否要上升为 VM 原生类型？

建议：**先用原型验证，再决定是否下沉到 VM 原生类型。**

### 先不下沉的理由

- Arturo 已经有对象原型系统，可以先快速验证 API 设计。
- 原生类型会牵涉：
  - `ValueKind`
  - `copyValue`
  - `hash`
  - `consideredEqual`
  - `printable/codify`
  - `type predicates`
  - VM/stdlib 各类 case 分支
- 改动面会明显变大。

### 什么时候值得下沉

当下面几点都成立时：

1. 语言层 API 已稳定。
2. 大文件/大数据流场景已验证收益明显。
3. 需要进一步减少对象包装开销。
4. 需要在更多底层指令或集合操作中直接识别 iterator。

## 当前原型限制

- `.parallel` 目前对 iterator 输入显式禁用。
- `fold.right` / `select.last` / `filter.last` 对 iterator 显式禁用。
- `read.lines.stream` 目前仅支持本地文件。
- `generator` 当前先聚焦“优雅地返回 :iterator”，尚未扩展到更重的调度控制接口。
- 目前 `:iterator` 是语言级原型类型，不是底层 `ValueKind`。
