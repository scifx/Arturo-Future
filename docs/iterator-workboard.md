# Iterator / Generator Workboard

## Goal

让 Arturo 的迭代器与生成器具备一流支持：

- 对大文件/大数据流真正节省内存
- 保持原有 eager 语义兼容
- 在适合的地方通过属性切换 lazy / iterator 行为
- 持续做编译验证、回归测试、性能对比

---

## Design rules

- `:iterator` 是运行时可消费值。
- `generator` 是创建 `:iterator` 的优雅工厂。
- `yield` 是生成过程中的逐项产出。
- `to :iterator` 必须走真实逐项产出路径，不能偷存另一份完整列表。
- 对可能改变原有 eager 语义的集合操作，优先用属性开关扩展。
- 对天然就是 consumable-stream 的对象，可允许直接消费式行为。

### Consumer vs non-consumer policy

#### consumer（会推进/耗尽 iterator）
- `next`
- `first` / `first.n`（针对 iterator）
- `take`（当直接返回 block 时）
- `drop`（当直接对 iterator 本体操作时）
- `@iterator`
- `array iterator`
- `to :block iterator`
- `print.lines iterator`

#### non-consumer（不应丢失下一个值）
- `peek`
- `empty?`（通过 peek/cache 语义实现，不应吞掉元素）
- `iterator?`

---

## Done

### Core runtime
- [x] 新增 `:iterator` 原型运行时实现
- [x] `to :iterator`
- [x] `iterator`
- [x] `iterator?`
- [x] `next`
- [x] `peek`
- [x] `rewind`
- [x] `yield`
- [x] `generator`
- [x] `to :block iterator`
- [x] `@iterator`
- [x] `array iterator`

### Streaming IO
- [x] `read.lines.stream`
- [x] `read.csv.stream`
- [x] `read.buffer:<n>`
- [x] `read.binary.buffer:<n>`
- [x] `write.buffer:<n>`
- [x] `write.binary.buffer:<n>`
- [x] `.seek:` for buffered read/write
- [x] `seek iterator position` for seekable iterators
- [x] `read.*.stream` 作为规范命名
- [x] `read.*.iterator` 仅保留为兼容别名（legacy alias），避免 public API 冗余继续扩大

### Iterator-aware collections / iteration
- [x] `loop` 支持 iterator
- [x] `map` 支持 iterator 输入
- [x] `select` 支持 iterator 输入
- [x] `filter` 支持 iterator 输入
- [x] `map.iterator` / `filter.iterator` / `select.iterator`
  - 当前已稳定为“返回 :iterator 的兼容形态”
  - 后续仍可继续优化为真正的逐项流式变换管线
- [x] `collect` 支持 iterator 输入
- [x] `fold` 支持 iterator 输入（left fold）
- [x] `enumerate` 支持 iterator 输入
- [x] `every?` / `some?` 支持 iterator 输入
- [x] `maximum` / `minimum`
- [x] `gather` / `cluster` / `chunk`
- [x] `take iterator`（eager materialize）
- [x] `take.iterator ...`（lazy switch）
- [x] `drop iterator`（consume and return remaining iterator）
- [x] `drop.iterator ...`（lazy switch）
- [x] `first iterator`
- [x] `first.n iterator`
- [x] `empty? iterator`

### Validation
- [x] `nim check`
- [x] Native compile validation
- [x] `tests/unittests/lib.iterators.art`
- [x] `tests/unittests/lib.files.art`
- [x] `tests/unittests/lib.iterator.examples.art`
- [x] `tests/unittests/lib.iterator.reliability.art`
- [x] `tests/unittests/lib.iterator.realworld.art`
- [x] custom sanity checks
- [x] benchmark head-vs-stream for large file reads
- [x] optimize internal iterator channel buffering once and re-benchmark

---

## Current limitations

- [ ] `.parallel` 还未与 iterator 正式打通
- [ ] `fold.right` / `select.last` / `filter.last` 仍不适合单向 iterator
- [ ] `collect.iterator` 这类更复杂的 lazy pipeline 还未做
- [ ] `read.bytes.stream` 还未做
- [ ] `read.chunks.stream` 还未做
- [ ] `read.json.stream` 不成立（JSON 结构通常需整体解析）

---

## Next recommended tasks

### Phase A: lazy transformation pipeline
- [x] `map.iterator`
- [x] `filter.iterator`
- [x] `select.iterator`
- [ ] `collect.iterator`（如有必要）

### Phase B: more IO streaming
- [ ] `read.bytes.stream.size:N`
- [ ] `read.chunks.stream.size:N`
- [ ] larger CSV benchmark suite

### Phase C: throughput optimization
- [ ] 降低 full-stream 场景下每项 channel/fiber 开销
- [ ] 为 hot path 增加专门快速通道
- [ ] 增加更系统的 microbench + macrobench

---

## Latest status

当前这条线已经不再是“伪迭代器”。

它已经具备：
- 真正的 generator / yield
- 真正的 streaming file reads
- 对 iterator 的原生集合操作支持
- 明确的 eager/lazy 分层
- 实测的大文件内存优势
