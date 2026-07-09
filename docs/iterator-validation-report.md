# Iterator / Generator Validation Report

## Build status

Validated on Debian 13 sandbox with Nim 2.2.10.

Successful compile command used for validation:

```bash
nim c \
  --define:useOpenssl3 \
  --define:ssl \
  --define:DOCGEN \
  --define:CLIPBOARD \
  --define:PARSERS \
  --define:SQLITE \
  -o:bin/arturo src/arturo.nim
```

Notes:
- The sandbox lacks optional system dependencies for the repository's default `@full` profile (`WEBVIEW`, `DIALOGS`, `GMP/mpfr`).
- Core iterator/generator work was compiled and validated in a reduced-but-real native build.

## Static validation

`nim check` passed for `src/arturo.nim` with the same enabled feature set.

## Runtime validation

Validated successfully:

- `tests/unittests/lib.iterators.art`
- `tests/unittests/lib.files.art`
- `tests/unittests/lib.iterator.examples.art`
- `tests/unittests/lib.iterator.reliability.art`
- `tests/unittests/lib.iterator.realworld.art`
- custom sanity script `iter_sanity.art`

This now also covers:
- `read.buffer:<n>`
- `write.buffer:<n>`
- `read.binary.buffer:<n>`
- `write.binary.buffer:<n>`
- buffered `.seek:` reads/writes
- `seek iterator position`
- `read.csv.stream`
- `print.lines` consuming iterators
- practical real-world scenarios (buffered copy, log scan, small CSV ETL)

The custom sanity script checks:
- `to :iterator` for range/string/dictionary
- `peek` / `next` / `rewind`
- `array iterator` / `@iterator`
- generator with parameters
- generator without parameters
- `take` on generator-produced iterators

## Key bugs fixed during validation

1. `checkAttr("last")` accidentally consumed `.last` before later logic used it.
   - This broke `select.last` / `filter.last` semantics.
   - Fixed by switching the pre-check to `getAttr("last") != VNULL`.

2. Generator factory built from `newBuiltin(...)` produced a builtin-function value that was not a good callable generator factory in Arturo userland.
   - Reworked `generator` to return a user function via `newFunctionFromDefinition(...)`.

3. Generator helper body originally relied on ambiguous direct-call syntax.
   - Reworked to use explicit internal `call '__generatorMake [...]`.

4. A template branch returned raw `@[]`, which triggered a Nim C backend internal error (`cannot map the empty seq type to a C type`).
   - Fixed by returning `newSeq[Value](0)`.

5. `read.lines.stream` and `to :iterator` were verified to use the lazy channel/fiber pipeline instead of materializing a second list first.

6. `@iterator` / `array iterator` now explicitly materialize iterators into blocks.

7. `read.csv.stream`, `take.iterator`, `drop.iterator`, `first iterator`, `drop iterator`, and `empty? iterator` were added and validated.

8. `map.iterator`, `filter.iterator`, and `select.iterator` were added and validated as stable iterator-returning forms.
   - Their current implementation prioritizes correctness and compatibility.
   - They can still be optimized later into deeper streaming pipelines if needed.

9. `read.*.stream` is now the canonical public naming; `read.*.iterator` remains only as a compatibility alias so the public API does not drift into redundant synonyms.

10. Pipe-based iterator flows such as `a | map.iterator => [ inc & ]`, `a | map.iterator 'x [ ... ]`, and `... | print.lines` were explicitly reproduced, tested, and fixed.

11. `read.buffer:<n>` / `write.buffer:<n>` were added as aligned fixed-size chunk input/output modes and validated for both text and binary paths.

12. Buffered `.seek:` support and the `seek` builtin were added and validated for practical random-access chunk workflows.

## Performance comparison

In addition to file-stream benchmarks, lazy transform pipelines were also sampled for partial-consumption workloads.

Benchmark file: `tmp_bench_big.txt`
- size: ~54 MB
- lines: 1,000,000

### Scenario A: only need first 10 lines

#### Eager
```arturo
lines: read.lines file
head: take lines 10
```
- elapsed: ~0.175 s
- peak RSS: ~296,672 KB

#### Stream / iterator
```arturo
stream: read.lines.stream file
head: take stream 10
```
- elapsed: ~0.006 s
- peak RSS: ~10,284 KB

### Scenario B: full scan / count all lines

#### Eager
```arturo
lines: read.lines file
enumerate lines => true
```
- elapsed: ~0.187 s
- peak RSS: ~302,708 KB

#### Stream / iterator
```arturo
stream: read.lines.stream file
enumerate stream => true
```
- elapsed: ~0.441 s
- peak RSS: ~15,928 KB

### Scenario C: lazy transform pipeline, partial consumption

#### Eager map + take
```arturo
mapped: map 1..1000000 'x -> x * 2
head: take mapped 10
```
- elapsed: ~0.138 s
- peak RSS: ~99,932 KB

#### `map.iterator` + take
```arturo
mapped: map.iterator 1..1000000 'x -> x * 2
head: take mapped 10
```
- elapsed: ~0.006 s
- peak RSS: ~17,708 KB

#### Eager filter + take
```arturo
filtered: filter 1..1000000 'x -> odd? x
head: take filtered 10
```
- elapsed: ~0.136 s
- peak RSS: ~56,668 KB

#### `filter.iterator` + take
```arturo
filtered: filter.iterator 1..1000000 'x -> odd? x
head: take filtered 10
```
- elapsed: ~0.006 s
- peak RSS: ~15,608 KB

## Interpretation

This is the expected trade-off:

- For **early-stop / partial consumption** workloads, the iterator path is dramatically better:
  - much lower memory
  - much lower latency

- For **full-stream throughput**, the current channel/fiber implementation is still more memory-efficient, but slower than eager full materialization.

A small bounded internal iterator buffer was added to reduce producer/consumer ping-pong, improving full-stream throughput compared with the earlier unbuffered version while preserving low memory use.

## Current conclusion

The current prototype is:
- usable
- compiled
- runtime-validated
- memory-safe for large-file streaming use cases
- semantically correct for the tested iterator/generator paths
- measurably better for partial-read / early-stop workloads

Remaining optimization work should focus on reducing per-item channel/fiber overhead for long full-stream scans, and on adding lazy transform pipelines such as `map.iterator` / `filter.iterator` / `select.iterator`.
