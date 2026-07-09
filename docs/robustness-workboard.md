# Arturo Robustness Workboard

## Goal

提升 Arturo 在错误输入、缺失参数、无效类型、以及不完整语法下的稳健性：

- 不崩溃
- 不无声退出
- 返回有意义的错误提示
- 通过可重复的压力测试持续验证

---

## Current focus

### Crash / hang regressions
- [x] bare `if`
- [x] bare `unless`
- [x] bare `while`
- [x] bare `switch`
- [x] incomplete `if 1`
- [x] incomplete `while [1]`
- [x] unmatched `[` / `(` / `{`
- [x] unterminated quoted strings
- [x] dangling trailing `:`
- [x] dangling trailing `=>` / `->`

### Buffered IO safety
- [x] invalid `read.buffer:<n>` sizes
- [x] invalid `write.buffer:<n>` sizes
- [x] invalid `seek` types
- [x] negative seek offsets
- [x] seek/tell on wrong input types

### Iterator / stream features
- [x] `read.buffer:<n>`
- [x] `write.buffer:<n>`
- [x] `tell`
- [x] `seek`
- [x] `seek.relative`
- [x] `seek.end`

### Validation assets
- [x] `tests/robustness_malformed.py`
- [x] `tests/robustness_fuzz_prefixes.py`
- [x] `tests/unittests/lib.iterator.seek.art`
- [x] `tests/unittests/lib.iterator.realworld.art`
- [x] `tests/unittests/lib.practical.vector_matrix_ga.art`
- [x] compile + run logs captured during iteration

---

## Remaining ideas

- [ ] expand malformed-input corpus with random truncations of common forms
- [ ] host-level stress loop for hundreds/thousands of malformed invocations
- [ ] test more parser edge cases around arrows, blocks, and attrs
- [ ] test nested exception propagation in iterators/generators
