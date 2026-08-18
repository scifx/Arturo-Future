#!/usr/bin/env python3
"""
Cross-validate Arturo's date arithmetic against Python's datetime.

For each case we compute the expected result in Python (which, like Nim,
works on absolute instants and is timezone-aware) and compare it against
what Arturo produces.

Usage:  python3 tools/date_cross_check.py [path-to-arturo-binary]
"""

import subprocess
import sys
import tempfile
import os
from datetime import datetime, timedelta, timezone
from fractions import Fraction

ARTURO = sys.argv[1] if len(sys.argv) > 1 else "bin/arturo"

FAILURES = []
CHECKS = 0


def run_arturo(code):
    """run a snippet of Arturo code and return its stripped stdout"""
    with tempfile.NamedTemporaryFile("w", suffix=".art", delete=False) as f:
        f.write(code)
        path = f.name
    try:
        out = subprocess.run(
            [ARTURO, "--no-color", path],
            capture_output=True, text=True, timeout=60
        )
        if out.returncode != 0 or "Error" in out.stderr:
            return "<ERROR> " + (out.stdout + out.stderr).strip()
        return out.stdout.strip()
    finally:
        os.unlink(path)


def check(label, expected, actual):
    global CHECKS
    CHECKS += 1
    ok = str(expected) == str(actual)
    status = "ok  " if ok else "FAIL"
    print(f"  [{status}] {label}")
    if not ok:
        print(f"         expected: {expected}")
        print(f"         actual  : {actual}")
        FAILURES.append(label)


# ---------------------------------------------------------------------------
# 1. date - date  ->  elapsed seconds
# ---------------------------------------------------------------------------
print("\n=== date - date (elapsed seconds) ===")

PAIRS = [
    ("1995-02-03T12:00:00+08:00", "2025-06-09T12:00:00+08:00"),
    # crossing a UTC offset change: same wall clock, different zones
    ("2021-03-22T11:25:30+01:00", "2021-03-22T11:25:30+00:00"),
    # leap day
    ("2020-02-28T00:00:00+00:00", "2020-03-01T00:00:00+00:00"),
    # leap year boundary
    ("1999-12-31T23:59:59+00:00", "2000-01-01T00:00:00+00:00"),
    # negative result
    ("2025-06-09T12:00:00+08:00", "1995-02-03T12:00:00+08:00"),
    # far apart, mixed offsets
    ("1970-01-01T00:00:00+00:00", "2038-01-19T03:14:07+00:00"),
    ("1900-01-01T00:00:00-05:00", "2100-01-01T00:00:00+09:00"),
]

for a, b in PAIRS:
    pa = datetime.fromisoformat(a)
    pb = datetime.fromisoformat(b)
    expected = int((pb - pa).total_seconds())

    code = f'''
d1: to :date "{a}"
d2: to :date "{b}"
print scalar (d2 - d1) --> `s
'''
    check(f"({b}) - ({a})", expected, run_arturo(code))


# ---------------------------------------------------------------------------
# 2. date - date  ->  converted to other time units
# ---------------------------------------------------------------------------
print("\n=== date - date, converted to other units ===")

a, b = "1995-02-03T12:00:00+08:00", "2025-06-09T12:00:00+08:00"
total = int((datetime.fromisoformat(b) - datetime.fromisoformat(a)).total_seconds())

for unit, per in [("min", 60), ("h", 3600), ("day", 86400), ("wk", 604800)]:
    # Arturo keeps quantities as exact rationals, so a non-integral result
    # comes back as `n/d` rather than as a lossy float. Mirror that with
    # Python's own exact Fraction.
    frac = Fraction(total, per)
    expected = frac.numerator if frac.denominator == 1 else f"{frac.numerator}/{frac.denominator}"
    code = f'''
d1: to :date "{a}"
d2: to :date "{b}"
print scalar (d2 - d1) --> `{unit}
'''
    check(f"elapsed in `{unit}", expected, run_arturo(code))


# ---------------------------------------------------------------------------
# 3. date + quantity  ->  date   (exact durations)
# ---------------------------------------------------------------------------
print("\n=== date + quantity (exact durations) ===")

BASE = "2021-03-22T11:25:30+00:00"
base_dt = datetime.fromisoformat(BASE)

SHIFTS = [
    ("3`days", timedelta(days=3)),
    ("2`wk", timedelta(weeks=2)),
    ("48`h", timedelta(hours=48)),
    ("90`min", timedelta(minutes=90)),
    ("3600`s", timedelta(seconds=3600)),
    ("1`day", timedelta(days=1)),
    ("100`days", timedelta(days=100)),
]

for q, delta in SHIFTS:
    expected = (base_dt + delta).strftime("%Y-%m-%dT%H:%M:%S+00:00")
    code = f'print (to :date "{BASE}") + {q}'
    check(f"date + {q}", expected, run_arturo(code))

    expected_sub = (base_dt - delta).strftime("%Y-%m-%dT%H:%M:%S+00:00")
    code_sub = f'print (to :date "{BASE}") - {q}'
    check(f"date - {q}", expected_sub, run_arturo(code_sub))


# ---------------------------------------------------------------------------
# 4. quantity + date  (commutative)
# ---------------------------------------------------------------------------
print("\n=== quantity + date (commutativity) ===")

for q, delta in SHIFTS[:3]:
    expected = (base_dt + delta).strftime("%Y-%m-%dT%H:%M:%S+00:00")
    code = f'print {q} + (to :date "{BASE}")'
    check(f"{q} + date", expected, run_arturo(code))


# ---------------------------------------------------------------------------
# 5. calendar-aware months / years
# ---------------------------------------------------------------------------
print("\n=== calendar-aware months / years ===")


def add_months(dt, n):
    """Calendar month shift, matching Nim's `TimeInterval` semantics.

    Note: Nim (and therefore Arturo's existing `after.months:` /
    `after.years:`) *overflows* an out-of-range day into the next month
    rather than clamping it: Jan 31 + 1 month = Mar 2, not Feb 29.
    We reproduce that here deliberately, so the cross-check validates the
    behaviour Arturo actually promises - and stays consistent with the
    builtins that already shipped.
    """
    import calendar
    y = dt.year + (dt.month - 1 + n) // 12
    m = (dt.month - 1 + n) % 12 + 1
    last = calendar.monthrange(y, m)[1]
    if dt.day <= last:
        return dt.replace(year=y, month=m, day=dt.day)
    # overflow the surplus days into the following month
    overflow = dt.day - last
    base = dt.replace(year=y, month=m, day=last)
    return base + timedelta(days=overflow)


CAL = [
    ("2021-03-22T11:25:30+00:00", "1`mo", 1),
    ("2021-03-22T11:25:30+00:00", "6`mo", 6),
    ("2021-03-22T11:25:30+00:00", "12`mo", 12),
    ("2020-01-31T00:00:00+00:00", "1`mo", 1),   # Jan 31 -> Feb 29 (leap)
    ("2021-01-31T00:00:00+00:00", "1`mo", 1),   # Jan 31 -> Feb 28
]

for base, q, n in CAL:
    dt = datetime.fromisoformat(base)
    expected = add_months(dt, n).strftime("%Y-%m-%dT%H:%M:%S+00:00")
    code = f'print (to :date "{base}") + {q}'
    check(f"{base} + {q}", expected, run_arturo(code))

YEARS = [
    ("2021-03-22T11:25:30+00:00", "1`yr", 1),
    ("2021-03-22T11:25:30+00:00", "10`yr", 10),
    ("2020-02-29T00:00:00+00:00", "1`yr", 1),   # leap day -> Feb 28
]

for base, q, n in YEARS:
    dt = datetime.fromisoformat(base)
    expected = add_months(dt, n * 12).strftime("%Y-%m-%dT%H:%M:%S+00:00")
    code = f'print (to :date "{base}") + {q}'
    check(f"{base} + {q}", expected, run_arturo(code))


# ---------------------------------------------------------------------------
# 6. round-trip: the issue's own use case
# ---------------------------------------------------------------------------
print("\n=== round-trip (the issue's use case) ===")

start, end = "1995-02-03T12:00:00+08:00", "2025-06-09T12:00:00+08:00"
days = int((datetime.fromisoformat(end) - datetime.fromisoformat(start)).days)

code = f'''
startDate: to :date "{start}"
endDate:   to :date "{end}"
delta: endDate - startDate
print scalar delta --> `day
'''
check("elapsed days", days, run_arturo(code))

code = f'''
startDate: to :date "{start}"
endDate:   to :date "{end}"
delta: endDate - startDate
print (startDate + delta) = endDate
'''
check("start + (end - start) = end", "true", run_arturo(code))


# ---------------------------------------------------------------------------
# 7. sub-second precision (the whole point of the issue)
# ---------------------------------------------------------------------------
print("\n=== sub-second precision ===")

code = '''
d1: to :date "2021-03-22T11:25:30+00:00"
d2: d1 + 1500`ms
print scalar (d2 - d1) --> `ms
'''
check("1500 ms round-trip", 1500, run_arturo(code))

code = '''
d1: to :date "2021-03-22T11:25:30+00:00"
d2: d1 + 250`us
print scalar (d2 - d1) --> `us
'''
check("250 us round-trip", 250, run_arturo(code))

code = '''
d1: to :date "2021-03-22T11:25:30+00:00"
d2: d1 + 1`ns
print scalar (d2 - d1) --> `ns
'''
check("1 ns round-trip", 1, run_arturo(code))


# ---------------------------------------------------------------------------
# 8. randomized fuzzing against Python
# ---------------------------------------------------------------------------
print("\n=== randomized fuzz (vs Python) ===")

import random
random.seed(1983)   # the issue number - deterministic runs

fuzz_fail = 0
FUZZ_N = 40

# build one Arturo script for all fuzz cases, to keep this fast
lines = []
expectations = []

for _ in range(FUZZ_N):
    y1 = random.randint(1900, 2100)
    y2 = random.randint(1900, 2100)
    d1 = datetime(y1, random.randint(1, 12), random.randint(1, 28),
                  random.randint(0, 23), random.randint(0, 59), random.randint(0, 59),
                  tzinfo=timezone(timedelta(hours=random.randint(-11, 12))))
    d2 = datetime(y2, random.randint(1, 12), random.randint(1, 28),
                  random.randint(0, 23), random.randint(0, 59), random.randint(0, 59),
                  tzinfo=timezone(timedelta(hours=random.randint(-11, 12))))

    a_s = d1.isoformat()
    b_s = d2.isoformat()
    expectations.append(int((d2 - d1).total_seconds()))
    lines.append(f'print scalar ((to :date "{b_s}") - (to :date "{a_s}")) --> `s')

out = run_arturo("\n".join(lines))
actual = out.splitlines()

CHECKS += 1
if len(actual) != FUZZ_N:
    print(f"  [FAIL] fuzz: expected {FUZZ_N} lines, got {len(actual)}")
    FAILURES.append("fuzz (line count)")
else:
    for i, (exp, act) in enumerate(zip(expectations, actual)):
        if str(exp) != act.strip():
            fuzz_fail += 1
            if fuzz_fail <= 3:
                print(f"  [FAIL] fuzz #{i}: expected {exp}, got {act.strip()}")
    if fuzz_fail:
        print(f"  [FAIL] {fuzz_fail}/{FUZZ_N} random date differences mismatched")
        FAILURES.append("fuzz")
    else:
        print(f"  [ok  ] {FUZZ_N}/{FUZZ_N} random date differences match Python exactly")


# ---------------------------------------------------------------------------
print("\n" + "=" * 60)
if FAILURES:
    print(f"{len(FAILURES)} of {CHECKS} CHECKS FAILED:")
    for f in FAILURES:
        print(f"  - {f}")
    sys.exit(1)
else:
    print(f"ALL {CHECKS} DATE CHECKS PASSED")
