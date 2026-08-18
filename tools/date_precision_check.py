#!/usr/bin/env python3
"""
Precision-focused cross-check for Arturo's date arithmetic.

Where `date_cross_check.py` validates *correctness* against Python's
datetime, this one specifically hunts for **precision loss**:

  - nanosecond-level exactness, including values that a float64 cannot
    represent (>2^53 nanoseconds, i.e. beyond ~104 days)
  - `\\timestamp` agreeing exactly with Unix epoch, including negative
    (pre-1970) and 2038-boundary values
  - accumulated drift over many successive shifts (the "task scheduler"
    scenario)

Usage:  python3 tools/date_precision_check.py [path-to-arturo-binary]
"""

import subprocess
import sys
import tempfile
import os
from datetime import datetime, timedelta, timezone

ARTURO = sys.argv[1] if len(sys.argv) > 1 else "bin/arturo"

FAILURES = []
CHECKS = 0


def run_arturo(code):
    with tempfile.NamedTemporaryFile("w", suffix=".art", delete=False) as f:
        f.write(code)
        path = f.name
    try:
        out = subprocess.run([ARTURO, "--no-color", path],
                             capture_output=True, text=True, timeout=300)
        if out.returncode != 0 or "Error" in out.stderr:
            return "<ERROR> " + (out.stdout + out.stderr).strip()[:300]
        return out.stdout.strip()
    finally:
        os.unlink(path)


def check(label, expected, actual):
    global CHECKS
    CHECKS += 1
    ok = str(expected) == str(actual)
    print(f"  [{'ok  ' if ok else 'FAIL'}] {label}")
    if not ok:
        print(f"         expected: {expected}")
        print(f"         actual  : {actual}")
        FAILURES.append(label)


# ---------------------------------------------------------------------------
# 1. \timestamp vs Unix epoch
# ---------------------------------------------------------------------------
print("\n=== \\timestamp == Unix epoch ===")

STAMPS = [
    "1970-01-01T00:00:00+00:00",     # epoch itself
    "1969-12-31T23:59:59+00:00",     # negative epoch
    "1900-01-01T00:00:00+00:00",     # far negative
    "2038-01-19T03:14:07+00:00",     # 32-bit signed boundary
    "2038-01-19T03:14:08+00:00",     # just past it
    "2106-02-07T06:28:15+00:00",     # 32-bit unsigned boundary
    "1995-02-03T12:00:00+08:00",     # the issue's own date
    "2025-06-09T12:00:00+08:00",
    "2025-06-09T06:00:00+02:00",     # same instant, other offset
    "2025-06-09T04:00:00+00:00",     # same instant, UTC
]

lines = []
expected = []
for s in STAMPS:
    expected.append(int(datetime.fromisoformat(s).timestamp()))
    lines.append(f'x: to :date "{s}"\nprint x\\timestamp')

actual = run_arturo("\n".join(lines)).splitlines()
for s, e, a in zip(STAMPS, expected, actual):
    check(f"{s}", e, a.strip())


# ---------------------------------------------------------------------------
# 2. beyond float64: nanosecond counts > 2^53
# ---------------------------------------------------------------------------
print("\n=== beyond float64 (>2^53 ns) ===")

# 2^53 ns is about 9.007e6 seconds (~104 days). A float64-based
# implementation starts silently rounding past this point.
BIG_SECONDS = [
    9_007_200,          # ~104 days, right at the boundary
    31_556_952,         # 1 year
    315_569_520,        # 10 years
    3_155_695_200,      # 100 years
    999_999_999_999,    # absurdly large, still exact in int64 ns? no - but seconds are
]

lines = []
for n in BIG_SECONDS:
    lines.append(f'd: to :date "2021-03-22T11:25:30+00:00"\n'
                 f'q: to :quantity @[{n} `s]\n'
                 f'print scalar ((d + q) - d) --> `s')
actual = run_arturo("\n".join(lines)).splitlines()
for n, a in zip(BIG_SECONDS, actual):
    check(f"+{n} s round-trip", n, a.strip())

# The real float64 killer: a large second count PLUS a nanosecond tail.
# 104 days in ns already exceeds 2^53, so a float-based shift drops the tail.
#
# Note: we verify via `\timestamp` + `\nanosecond` rather than by converting
# the difference back to `ns`. Converting a >2^53 nanosecond quantity is
# broken *upstream* in the Quantities code (`toRational(float)` produces a
# zero denominator) - a pre-existing bug, reproducible with no dates
# involved, and out of scope here. What we're testing is that the *shift
# itself* stays exact.
print("\n=== large duration + nanosecond tail (via timestamp/nanosecond) ===")
TAILS = [
    (9_007_200, 1),
    (9_007_200, 999_999_999),
    (31_556_952, 123_456_789),
    (315_569_520, 1),
]
lines = []
for secs, ns in TAILS:
    total_ns = secs * 1_000_000_000 + ns
    lines.append(f'd: to :date "2021-03-22T11:25:30+00:00"\n'
                 f'q: to :quantity @[{total_ns} `ns]\n'
                 f'e: d + q\n'
                 f'print ~"|e\\timestamp - d\\timestamp|,|e\\nanosecond|"')
actual = run_arturo("\n".join(lines)).splitlines()
for (secs, ns), a in zip(TAILS, actual):
    check(f"+{secs}s{ns}ns exact (secs,ns)", f"{secs},{ns}", a.strip())


# ---------------------------------------------------------------------------
# 3. fractional seconds expressed as exact rationals
# ---------------------------------------------------------------------------
print("\n=== exact rational fractions of a second ===")

FRACTIONS = [
    ("1:2", 500_000_000),
    ("1:3", 333_333_333),      # truncates toward zero
    ("1:7", 142_857_142),
    ("2:3", 666_666_666),
    ("1:1000000000", 1),       # exactly one nanosecond
]
lines = []
for frac, _ in FRACTIONS:
    lines.append(f'd: to :date "2021-03-22T11:25:30+00:00"\n'
                 f'print scalar ((d + {frac}`s) - d) --> `ns')
actual = run_arturo("\n".join(lines)).splitlines()
for (frac, exp), a in zip(FRACTIONS, actual):
    check(f"+{frac} s = {exp} ns", exp, a.strip())


# ---------------------------------------------------------------------------
# 4. accumulated drift (the scheduler scenario)
# ---------------------------------------------------------------------------
print("\n=== accumulated drift over many steps ===")

DRIFTS = [
    ("1`h", 10000, 10000 * 3600, "s"),
    ("1`min", 50000, 50000 * 60, "s"),
    ("1`s", 100000, 100000, "s"),
    ("1`ns", 100000, 100000, "ns"),
    ("1:3`s", 30000, 30000 * 333_333_333, "ns"),
]
for q, n, total, unit in DRIFTS:
    code = f'''
t: to :date "2025-01-01T00:00:00+00:00"
s: t
loop 1..{n} 'i [ t: t + {q} ]
print scalar (t - s) --> `{unit}
'''
    check(f"{n} x {q} accumulates exactly", total, run_arturo(code).strip())


# ---------------------------------------------------------------------------
# 5. timestamp agrees with operator-based difference
# ---------------------------------------------------------------------------
print("\n=== \\timestamp and `-` agree ===")

import random
random.seed(1983)
lines = []
expected = []
for _ in range(25):
    d1 = datetime(random.randint(1900, 2100), random.randint(1, 12), random.randint(1, 28),
                  random.randint(0, 23), random.randint(0, 59), random.randint(0, 59),
                  tzinfo=timezone(timedelta(hours=random.randint(-11, 12))))
    d2 = datetime(random.randint(1900, 2100), random.randint(1, 12), random.randint(1, 28),
                  random.randint(0, 23), random.randint(0, 59), random.randint(0, 59),
                  tzinfo=timezone(timedelta(hours=random.randint(-11, 12))))
    expected.append(int((d2 - d1).total_seconds()))
    lines.append(f'a: to :date "{d1.isoformat()}"\n'
                 f'b: to :date "{d2.isoformat()}"\n'
                 f'print (b\\timestamp - a\\timestamp) = scalar (b - a) --> `s')

actual = run_arturo("\n".join(lines)).splitlines()
bad = [i for i, a in enumerate(actual) if a.strip() != "true"]
CHECKS += 1
if len(actual) != 25:
    print(f"  [FAIL] expected 25 lines, got {len(actual)}")
    FAILURES.append("timestamp/operator agreement")
elif bad:
    print(f"  [FAIL] {len(bad)}/25 disagreed")
    FAILURES.append("timestamp/operator agreement")
else:
    print("  [ok  ] 25/25 random pairs: timestamp diff == operator diff")


# ---------------------------------------------------------------------------
print("\n" + "=" * 60)
if FAILURES:
    print(f"{len(FAILURES)} of {CHECKS} CHECKS FAILED:")
    for f in FAILURES:
        print(f"  - {f}")
    sys.exit(1)
else:
    print(f"ALL {CHECKS} PRECISION CHECKS PASSED")
