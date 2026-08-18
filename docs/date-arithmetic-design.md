# Date arithmetic (issue #1983)

Arithmetic operators now work with `:date` values:

```arturo
d1: now
d2: now                     ; a couple of seconds later
timePassed: d2 - d1         ; the interval, as a time :quantity
print timePassed --> `s     ; ...in whichever unit we please

c: now
c + 3`days                  ; => a new :date
```

This is exactly the design [@drkameleon sketched in the issue][1] — no new
`deltaTime` builtin, just the operators Arturo users already reach for,
reusing the Quantities/Units machinery that was already there.

[1]: https://github.com/arturo-lang/arturo/issues/1983

---

## What was actually wrong

The premise in the issue report — "Arturo's date has no timestamp, so the
difference isn't a real-world interval" — turned out to be **half right**.

A `:date` already carries a complete Nim `DateTime` in its `eobj` field,
UTC offset included. The precision was never lost; it simply wasn't reachable,
because `src/vm/values/operators.nim` had **no `Date` cases at all**. Both
`d2 - d1` and `c + 3`days` failed with a plain type error.

The operators now go through `eobj` and Nim's own `times` module — which is
precisely the "original Nim precision" that was asked for.

### `\timestamp`

A `timestamp` field was **also** added to every `:date`, exposing the Unix
epoch directly:

```arturo
d: to :date "1995-02-03T12:00:00+08:00"
d\timestamp        ; => 791784000
```

This is derived on the spot from `eobj` (`dt.toTime().toUnix()`), so it cannot
drift out of sync with the date it belongs to. It matters because `to :date`
normalises everything to UTC — `hour` reads `4`, not `12`, and `utc` is always
`0` — which makes the human-readable fields a poor basis for reasoning about
instants. `\timestamp` gives you the unambiguous one, and it agrees exactly
with the subtraction operator:

```arturo
(d2\timestamp - d1\timestamp) = scalar (d2 - d1) --> `s   ; => true
```

Verified against Python for the epoch itself, negative (pre-1970) values,
and both the 2038 signed and 2106 unsigned 32-bit boundaries.

## The operations

| Expression | Result |
|---|---|
| `date - date` | `:quantity` — the elapsed time, in seconds |
| `date + quantity` | `:date` — shifted forwards |
| `quantity + date` | `:date` — same, commutative |
| `date - quantity` | `:date` — shifted backwards |

`date + date` is deliberately **not** defined: adding two points in time is
meaningless. Shifting a date by a non-duration (`date + 3`m`) raises an
incompatible-quantity error rather than silently doing something arbitrary.

## Real elapsed time, not "ideal" time

Differences are computed from **absolute instants** (`toTime()`), so UTC
offsets are honoured:

```arturo
; same wall clock, different zones -> one hour apart
(to :date "2021-03-22T11:25:30+00:00") - (to :date "2021-03-22T11:25:30+01:00")
; => 3600 s

; different wall clocks, same instant -> zero
(to :date "2021-03-22T12:25:30+01:00") - (to :date "2021-03-22T11:25:30+00:00")
; => 0 s
```

## Exactness — no float round-trip

Arturo's quantities are backed by `VRational`, so the result is kept **exact**
rather than being pushed through a float.

This matters most when *shifting* a date. An earlier draft of `shiftDate`
split the duration into seconds + nanoseconds via `toFloat`. That is subtly
wrong: a float64 has a 53-bit mantissa, so it cannot hold a nanosecond count
beyond about 104 days without rounding. Shifting by `9007200 s + 1 ns` would
silently drop the `1 ns`:

```
float path -> secs 9007200  ns 0     (!!)
exact path -> secs 9007200  ns 1
```

The shipped implementation (`splitSecondsExactly`) therefore uses **integer
division only** — `n div d` for the whole seconds, then the exact remainder
scaled to nanoseconds — with a big-integer branch for rationals that overflow
`int`. No float is involved anywhere on the path.

Nanoseconds survive intact:

```arturo
d: now
(d + 1`ns) - d          ; => exactly 1 ns
```

and non-integral conversions stay exact rather than rounding:

```arturo
delta --> `wk           ; => 11084/7 wk, not 1583.4285714285713
```

## Calendar-aware months and years

`mo` and `yr` are defined in Arturo as *average* durations (1 mo = 2629746 s
≈ 30.44 days). Adding those as fixed durations would leave `date + 1`yr` at a
strange time of day.

So when a quantity is a whole number of months or years, the shift is applied
as a **calendar** step via Nim's `TimeInterval` — same as the existing
`after.months:` / `after.years:` builtins. Everything else is an exact
duration.

```arturo
base: to :date "2021-03-22T11:25:30+00:00"
base + 1`yr                  ; => 2022-03-22T11:25:30+00:00  (time preserved)
(after.years:1 base) = base + 1`yr   ; => true
```

Note that Nim *overflows* out-of-range days rather than clamping them
(Jan 31 + 1 month = Mar 2, not Feb 28). That is pre-existing Arturo behaviour,
inherited from `after.months:`; the new operators match it deliberately, and
the cross-check validates that convention rather than Python's.

---

## Bug found along the way: `x + 1<unit>` silently lost the unit

While testing `date + 1`ns` I hit an unrelated, pre-existing miscompilation.

The AST optimizer folds `x + 1` into `inc x`. Its guard was `value == I1` —
but Arturo's semantic `==` compares numeric kinds across the board, so
**`1`km == 1` is true**. Any `x + 1<unit>` was therefore folded into a bare
increment, throwing the unit away:

```arturo
q: 5`m
q + 1`km        ; was: 6 m        (!!)  now: 1005 m
q + 1`s         ; was: 6 m        (!!)  now: a proper conversion error
```

Fixed by testing for a *literal* integer 1 (`isPlainOne`) in the three
inc/dec folds in `vm/ast.nim`, instead of the semantic `==`. The plain-integer
hot path is unaffected (2M-iteration `t: t + 1` loop still runs in ~0.18s).

---

## Verification

**`tools/date_cross_check.py`** — cross-validates against Python's
`datetime`, which like Nim is timezone-aware and instant-based. 42 checks:

- `date - date` across UTC offsets, leap days, leap years, negative results,
  and 1900↔2100 spans
- unit conversions (`s`/`min`/`h`/`day`/`wk`), including exact rationals
- `date ± quantity` for 7 units, both directions, plus commutativity
- calendar month/year shifts, including month-end overflow
- sub-second round-trips (ms, µs, ns)
- the issue's own use case, round-tripped
- **40 randomized date pairs** (seeded, 1900–2100, random UTC offsets)

```
$ python3 tools/date_cross_check.py bin/arturo
ALL 42 DATE CHECKS PASSED
```

**`tools/date_precision_check.py`** — a second, precision-focused harness
(30 checks) that specifically hunts for loss: `\timestamp` against Unix epoch
including negative and 2038/2106 boundaries; nanosecond tails on durations
beyond 2^53 ns; exact rational fractions of a second; and accumulated drift
over up to 100,000 successive shifts (the task-scheduler scenario), which
comes out at **exactly zero**.

```
$ python3 tools/date_precision_check.py bin/arturo
ALL 30 PRECISION CHECKS PASSED
```

**`tests/unittests/lib.dates.art`** — 18 new assertion groups covering the
same ground natively.

## Two pre-existing bugs found while testing (not fixed here)

Both reproduce on an untouched baseline build, with no date code involved:

1. **Converting a >2^53 nanosecond quantity fails.** `9007200000000001`ns
   `--> `s` raises "Cannot create Rational value / Denominator is zero",
   because `toRational(float)` in `vm/values/custom/vrational.nim` uses a
   continued-fraction approximation that degenerates for large floats. The
   date *shift* is unaffected (it never goes through a float); only reading
   the difference back in `ns` at that magnitude trips it.

2. **Large negative integer literals hang, then OOM.** `print -2208988800`
   consumes ~50s of mostly system time and is killed; the positive literal
   prints in 14ms. Anything past the 32-bit negative range is affected. The
   date tests work around this by writing `(0 - 2208988800)`.

Both are worth separate issues upstream.

Full suite: **36/38**, unchanged from baseline (the 2 failures are
pre-existing: a currency test needing network access, and a missing
examples directory).
