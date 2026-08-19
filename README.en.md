<div align="right">

[简体中文](./README.md) | **English**

</div>

<div align="center">

<img align="center" width="150" src="docs/images/logo.png#gh-light-mode-only"/>
<img align="center" width="150" src="docs/images/logo-lightgray.png#gh-dark-mode-only"/>

# Arturo-Future

### Radical experiments on the [Arturo](https://github.com/arturo-lang/arturo) language

[![License](https://img.shields.io/github/license/arturo-lang/arturo?style=for-the-badge)](LICENSE)
![Language](https://img.shields.io/badge/language-Nim-6A7FC8.svg?style=for-the-badge)
![Status](https://img.shields.io/badge/status-experimental-orange.svg?style=for-the-badge)
[![Upstream](https://img.shields.io/badge/upstream-arturo--lang%2Farturo-blue.svg?style=for-the-badge)](https://github.com/arturo-lang/arturo)

[What this is](#what-this-is) · [Added features](#added-features) · [Upcoming](#upcoming-features) · [Thanks & donations](#thanks--donations)

</div>

---

> **This is not official Arturo.**
>
> This repository is an experimental fork of [arturo-lang/arturo](https://github.com/arturo-lang/arturo) by [scifx](https://github.com/scifx). It does not aim to replace upstream. It exists to knock down walls hit in daily use — especially [issues I filed upstream](https://github.com/arturo-lang/arturo/issues?q=is%3Aissue%20author%3Ascifx) that were not going to land soon — by implementing them here first, with AI assistance.
>
> For a stable, official, predictable Arturo, go upstream:
>
> **[arturo-lang/arturo](https://github.com/arturo-lang/arturo)** · **[arturo-lang.io](https://arturo-lang.io/)**

---

## What this is

[Arturo](https://arturo-lang.io/) is an independently developed modern scripting language, vaguely related to Logo, Rebol, Forth, Ruby, Haskell, Smalltalk, Tcl and Lisp. It is written in Nim, and the rules are simple:

- Code is just a list of words, symbols and literal values
- Words and symbols are interpreted according to context
- **There are no reserved words**

```red
factorial: function [n][
    switch n > 0 -> n * factorial n-1
                 -> 1
]

loop 1..19 [x]->
    print ["Factorial of" x "=" factorial x]
```

I like writing Arturo the way I use a calculator: few keystrokes, little to remember, problems get solved. Using it for real work also hits walls — Chinese identifiers silently dropped by the parser, CJK input corrupted in the REPL, large files that must be loaded whole, `execute` / `request` that only return after everything is finished, loops that blow memory on big data.

**Arturo-Future** is a radical attempt at those walls. It is currently based on upstream `0.10.x` (this repo reports `0.10.1-dev`). Default behaviour stays as byte-compatible with upstream as possible; new capabilities are opt-in attributes such as `.stream` and `.iterator`.

---

## How it differs from upstream

| | Upstream Arturo | This fork |
|---|---|---|
| Role | Official language implementation | Radical sandbox |
| Identifiers | ASCII only; Chinese is silently skipped | UTF-8 / Chinese identifiers are real words |
| REPL | linenoise treats input as bytes; multi-byte edits corrupt text | REPL handles UTF-8 by code point |
| Collections | Most paths materialize a full block first | Real lazy `:iterator`s that yield item by item |
| Large files | `read.lines` loads the whole file | `read.lines.stream` / `read.csv.stream` / `read.buffer:N` |
| Subprocesses | `execute` captures all stdout | `execute.stream` consumes live output; early-stop kills the process |
| HTTP | `request` reads the whole body | `request.stream` returns when headers arrive; SSE / LLM token streams |
| Bad input | Bare `if` / unmatched brackets can hang | Parser precheck + evaluator guards; fail fast with “not enough parameters” |
| Builds | Official multi-platform releases | Build from source; experimental Termux / Android path |

**Compatibility rule:** without the new attributes, `execute`, `request`, `read`, `map` and friends keep their eager semantics. Existing scripts should keep working.

---

## What is distinctive

### 1. Chinese is a first-class identifier

Upstream only accepts ASCII letters as a word start, so `你好` is skipped byte by byte. Here identifiers are recognized by rune, so Chinese can be a function name, a parameter, or a variable:

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

Editing multi-byte characters in the REPL no longer tears `你` into garbage bytes. These are upstream [#2170](https://github.com/arturo-lang/arturo/issues/2170) and [#2211](https://github.com/arturo-lang/arturo/issues/2211), landed here first.

### 2. An `:iterator` is not “another array box”

No new `:stream` type. An iterator is a **consumable runtime value**: the producer runs on a fiber, yields through a bounded channel (capacity 256), and blocks when the consumer is not taking — back-pressure comes for free.

```red
; 54 MB / 1 million lines, only the first 10: do not load the file
head: take read.lines.stream "huge.log" 10

; lazy transform pipeline: only the consumed prefix is computed
1..1000000
    | map.iterator 'x -> x * 2
    | filter.iterator => odd?
    | take 10
```

The same consumers work on every source: `loop` / `map` / `select` / `filter` / `take` / `fold` / `first` / `empty?` / `enumerate` / `gather` / `chunk` / `cluster` …

### 3. One streaming convention: files, processes, HTTP, LLMs

`.stream` means exactly one thing: **give me an iterator, not a value.**

```red
; subprocess: handle ping as it arrives; take 10 lines kills `yes`
loop execute.stream "ping -c 5 example.com" 'line [
    print ["<<" line]
]
head: take execute.stream "yes hello" 10

; HTTP: response shape is unchanged; only body becomes :iterator
r: request.stream "https://example.com/big.txt" ø
print r\status
loop r\body 'line -> print line

; SSE / LLM token stream
r: request.stream.events.post.json
     "https://api.openai.com/v1/chat/completions"
     #[model: "gpt-4o" stream: true messages: @[...]]

loop r\body 'ev [
    if ev\data <> "[DONE]" ->
        prints (read.json ev\data)\choices\0\delta\content
]
```

`unplug` closes a stream early (terminate the child process / close the HTTP client).

### 4. Measured memory wins

~54 MB / 1,000,000-line text, plus lazy transforms over `1..1000000` (sandbox numbers):

| Workload | eager | stream / iterator |
|---|---|---|
| First 10 lines of a file | ~0.175 s · ~290 MB | **~0.006 s · ~10 MB** |
| `map` then take 10 | ~0.138 s · ~100 MB | **~0.006 s · ~18 MB** |
| `filter` then take 10 | ~0.136 s · ~57 MB | **~0.006 s · ~16 MB** |
| Full scan of every line | ~0.19 s · ~300 MB | ~0.44 s · **~16 MB** |

Early-stop work is an order-of-magnitude win. A full scan still uses far less memory, but is currently slower than eager — per-item fiber / channel cost is the next cut.

### 5. Incomplete input no longer hangs the process

A bare `if`, an unfinished `while [1]`, a dangling `[` / `=>` / `:` used to stall in the parser or the evaluator optimizer. They now fail fast with a real error. This is not new syntax; it is the language no longer locking up when you mistype.

---

## Added features

Relative to upstream, already merged here and backed by tests or design notes:

### Language / REPL

- [x] UTF-8 identifiers: non-ASCII letters such as Chinese are words (upstream [#2170](https://github.com/arturo-lang/arturo/issues/2170))
- [x] UTF-8 REPL input and editing: multi-byte characters are no longer torn apart (upstream [#2211](https://github.com/arturo-lang/arturo/issues/2211))
- [x] Parser structural precheck: unmatched brackets, unterminated strings, dangling `:` / `=>` / `->` fail fast
- [x] Evaluator guards: incomplete `if` / `unless` / `while` / `switch` report “not enough parameters” instead of hanging or crashing

### Iterators and generators

- [x] Language-level `:iterator` prototype (`to :iterator` / `iterator` / `iterator?`)
- [x] `generator` + `yield`: real item-by-item production, not a second materialized list
- [x] `next` / `peek` / `rewind` / `drain`
- [x] `@iterator` / `array iterator` / `to :block` materialize
- [x] `loop` / `map` / `select` / `filter` / `collect` / `fold` (left fold) accept iterators
- [x] `enumerate` / `every?` / `some?` / `maximum` / `minimum`
- [x] `gather` / `cluster` / `chunk`
- [x] `map.iterator` / `filter.iterator` / `select.iterator`: lazy transforms that return `:iterator`
- [x] `take` / `take.iterator` / `drop` / `drop.iterator` / `first` / `first.n` / `empty?`

### Streaming I/O

- [x] `read.lines.stream`: lazy line reader for local files
- [x] `read.csv.stream`: lazy CSV reader
- [x] `read.buffer:N` / `read.binary.buffer:N`
- [x] `write.buffer:N` / `write.binary.buffer:N`
- [x] `.seek:`, `seek` / `seek.relative` / `seek.end`, `tell`
- [x] `print.lines` can consume an iterator directly
- [x] `read.*.iterator` is a compatibility alias only; the canonical name is `read.*.stream`

### Process and network streams

- [x] `execute.stream` / `execute.stream.buffer:N`: child stdout as an `:iterator`
- [x] After the stream is exhausted, `exit` is readable on the iterator; `unplug` kills the process
- [x] `request.stream` / `request.stream.buffer:N`: returns when headers arrive; `body` is an iterator
- [x] `request.stream.events`: SSE framing; each event is `#[event: data: id: retry:]`
- [x] POSIX: async incremental pipe reads; Windows: avoid the sync-pipe + IOCP trap, poll with `PeekNamedPipe`

### Platform and engineering

- [x] Termux / Android build experiments (`build.sh`, `termux` branch; upstream [#1971](https://github.com/arturo-lang/arturo/issues/1971))
- [x] Malformed-input stress tests: `tests/robustness_malformed.py`, `tests/robustness_fuzz_prefixes.py`
- [x] Iterator / file / real-world unit tests and benchmark scripts
- [x] Windows `webview`: `arturo.call` / `arturo.exec` work on the first load, leftover File/Share menu removed, complex return values reach the page (upstream [#2209](https://github.com/arturo-lang/arturo/issues/2209))

Design and validation notes:

- [docs/iterator-optimization-plan.md](docs/iterator-optimization-plan.md)
- [docs/iterator-workboard.md](docs/iterator-workboard.md)
- [docs/iterator-validation-report.md](docs/iterator-validation-report.md)
- [docs/streaming-design.md](docs/streaming-design.md)
- [docs/robustness-workboard.md](docs/robustness-workboard.md)
- [docs/robustness-validation-report.md](docs/robustness-validation-report.md)
- [docs/webview-windows-fix.md](docs/webview-windows-fix.md)

---

## Upcoming features

Left blank on purpose. I fill this in as I go. Done items move up to “Added features”.

- [ ]
- [ ]
- [ ]
- [ ]
- [ ]

---

## Upstream issues, implemented here first

These are issues I opened on [arturo-lang/arturo](https://github.com/arturo-lang/arturo). The upstream authors are kind, and several items are moving there too. This fork means: **what I cannot wait for, I implement here with AI.**

Already mapped onto this branch:

| Upstream issue | What landed here |
|---|---|
| [#2170](https://github.com/arturo-lang/arturo/issues/2170) parser drops UTF-8 / Chinese identifiers | Identifiers recognized by rune |
| [#2211](https://github.com/arturo-lang/arturo/issues/2211) REPL corrupts multi-byte input | UTF-8 editing path fixed |
| [#1971](https://github.com/arturo-lang/arturo/issues/1971) Termux build failure | `build.sh` + experimental `termux` branch |
| [#1972](https://github.com/arturo-lang/arturo/issues/1972) loop performance / large data | Lazy iterators; early-stop memory and latency drop |

The rest that are still open (closures, glob, writable `env`, stdin/stdout/stderr, date intervals, `serve` POST crash, Windows webview, `read.json` safety, …) are my own backlog. Progress goes into “Added features”; the next concrete items live only in the empty list above.

Full list: <https://github.com/arturo-lang/arturo/issues?q=is%3Aissue%20author%3Ascifx>

---

## Limits, said up front

These are design boundaries, not hidden bugs:

- `:iterator` is still an object prototype, not a native VM `ValueKind`
- `.parallel` is not wired to iterators yet
- `fold.right` / `select.last` / `filter.last` / `reverse` need random access and are explicitly disabled on one-way streams
- A full scan is still slower than eager materialization; per-item channel/fiber cost still needs cutting
- `execute.stream` cannot yet write to the child stdin
- Windows process streams have a worst-case ~15 ms poll delay (correctness first)
- No official prebuilt binaries; if you want this fork’s features, build from source

---

## Build

You need **Nim** and a C/C++ toolchain. Some features also need system libraries (SSL, etc.).

```bash
git clone https://github.com/scifx/Arturo-Future.git
cd Arturo-Future

./build.nims                  # default full build → bin/arturo
./build.nims --mode:mini      # smaller mini build
./build.nims --install        # install to ~/.arturo/bin
./build.nims test             # test suite

# thin wrapper (full + release + log, no UI)
./build.sh
```

For the official stable release, prebuilt binaries, Docker or Homebrew, use upstream. Do not treat this experimental branch as a release channel:

- Download: <https://arturo-lang.io/#download>
- One-liner: `curl -sSL https://get.arturo-lang.io | sh`
- Nightly: <https://github.com/arturo-lang/nightly/releases>
- Build docs: <https://github.com/arturo-lang/arturo/wiki/Building-Arturo>

Language documentation is official as well: <https://arturo-lang.io/documentation/>

---

## Thanks & donations

Arturo exists because [Yanis Zafirópulos](https://github.com/drkameleon) (Dr.Kameleon) has been writing it in his free time since 2019. Without him there is no language, and no fork. Maintainer [RickBarretto](https://github.com/RickBarretto) and every upstream contributor deserve the same thanks.

**Please support the original author, not this experimental branch.**

This repository does not accept donations. If Arturo made you happy, made a job easier, or you just want it to go further, send that support upstream:

### How to donate (same channels as upstream)

The main channel is **[GitHub Sponsors](https://github.com/sponsors/drkameleon)**.

Crypto works too:

- **BTC**: `bc1qpjlmktrz79muz4yksm8aadz3d3srh0rmnn3hhd`
- **ETH**: `0x8552a389ea3d77e0e13573a642cff5ef745447b9`
- **SOL**: `FS47tEruHesSbWFPdhqbJpixtwHVgU38DvJYYYLRk2MS`

You can also sponsor the maintainer: [GitHub Sponsors @RickBarretto](https://github.com/sponsors/RickBarretto)

### Sponsors already listed upstream

Every little bit counts and the least we could do is to thank you all for your help and making us stick to the project:

<a href="https://github.com/BNAndras"><img align="center" width="50" src="https://avatars.githubusercontent.com/u/20251272?v=4"/></a>

---

## Community

- Official repo and issues: <https://github.com/arturo-lang/arturo>
- Discussion and experiments for this fork: <https://github.com/scifx/Arturo-Future/issues>
- Discord: <https://discord.gg/YdVK2CB>
- Website: <https://arturo-lang.io/>

Curious people are welcome to play, break things, and propose even more radical ideas. Fixes that can go back upstream will be shaped into standalone patches when possible.

---

## License

MIT License

Copyright (c) 2019-2026 Yanis Zafirópulos (aka Dr.Kameleon)

Experimental changes added by scifx in this fork are also MIT, and the upstream copyright notice is kept. Full text: [LICENSE](LICENSE).
