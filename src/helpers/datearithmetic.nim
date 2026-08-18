#=======================================================
# Arturo
# Programming Language + Bytecode VM compiler
# (c) 2019-2026 Yanis Zafirópulos
#
# @file: helpers/datearithmetic.nim
#=======================================================

## Arithmetic between `:date` values and time `:quantity` values.
##
## Design note:
## - A `:date` already wraps a full Nim `DateTime` (`eobj`), including its
##   UTC offset, so the underlying precision has always been there - it just
##   wasn't reachable from Arturo's operators.
## - `date - date` yields the *real* elapsed time as a `:quantity` in seconds,
##   computed from the absolute instants (`toTime`), so UTC offsets and DST
##   are accounted for. Nanosecond resolution is preserved exactly by keeping
##   the result rational (`n/1000000000`) rather than going through floats.
## - `date + quantity` / `date - quantity` shift a date by a duration and
##   return a new `:date`.
##
## Calendar-aware vs. absolute units:
##   `mo` and `yr` are defined in Arturo as *average* durations
##   (1 mo = 2629746 s, 1 yr = 31556952 s). Adding them as fixed durations
##   would make `date + 1`yr` land at an odd time-of-day. So whenever a
##   quantity is expressed purely in months or years, we shift the calendar
##   using Nim's `TimeInterval` (which is calendar-aware), matching what
##   `after.months:`/`after.years:` already do. Everything else is treated as
##   an exact duration.

#=======================================
# Libraries
#=======================================

import std/times

when defined(GMP):
    import helpers/bignums

import vm/values/custom/[vquantity, vrational]
import vm/values/value
import vm/values/types

#=======================================
# Constants
#=======================================

const
    NanosecondsPerSecond* = 1_000_000_000

#=======================================
# Helpers
#=======================================

proc isTimeQuantity*(q: VQuantity): bool =
    ## is this quantity a duration, i.e. of the `Time` dimension?
    getProperty(q) == "time"

proc secondsAtoms(): VUnit =
    ## the `s` (seconds) unit, parsed once
    parseAtoms("s")

proc asSeconds(q: VQuantity): VRational =
    ## exact value of given time quantity, expressed in seconds
    convertQuantity(q, secondsAtoms()).original

proc isWholeCalendarUnit(q: VQuantity, unitAtoms: VUnit): (bool, int) =
    ## if `q` is expressed purely in the given unit (e.g. `mo`) *and* amounts
    ## to a whole number of them, return that number - so that we can shift
    ## the calendar instead of adding an average-length duration
    if q.atoms != unitAtoms:
        return (false, 0)

    let orig = q.original
    if orig.rKind != NormalRational:
        return (false, 0)
    if orig.den != 1:
        return (false, 0)

    result = (true, orig.num)

#=======================================
# Methods
#=======================================

proc splitSecondsExactly*(secs: VRational): (int64, int64) =
    ## split an exact number of seconds into (whole seconds, nanoseconds),
    ## using integer arithmetic only - no float round-trip, so this stays
    ## exact across the whole range a Nim `Duration` can hold.
    ##
    ## Rounds the sub-nanosecond remainder toward zero, and keeps the sign of
    ## both components consistent (as `initDuration` expects).
    if secs.rKind == NormalRational:
        let n = int64(secs.num)
        let d = int64(secs.den)

        # truncating division, then the exact remainder as nanoseconds
        let whole = n div d
        let rem = n - whole * d
        let nanos = (rem * int64(NanosecondsPerSecond)) div d

        result = (whole, nanos)
    else:
        when defined(GMP):
            # big rationals: do the same, but with big-integer arithmetic
            let n = getNumerator(secs, big=true)
            let d = getDenominator(secs, big=true)

            let whole = n div d
            let rem = n - whole * d
            let nanos = (rem * newInt(NanosecondsPerSecond)) div d

            result = (int64(getInt(whole)), int64(getInt(nanos)))
        else:
            result = (0'i64, 0'i64)

proc dateDifference*(a: DateTime, b: DateTime): VRational =
    ## the *real* elapsed time between two dates, in seconds, exactly.
    ##
    ## Both dates are reduced to absolute instants first, so UTC offsets are
    ## respected: two identical wall-clock times in different zones do *not*
    ## come out as zero.
    let dur = a.toTime() - b.toTime()

    let secs = dur.inSeconds()
    let nanos = dur.inNanoseconds() - secs * NanosecondsPerSecond

    result = toRational(int(secs))
    if nanos != 0:
        result = result + toRational(int(nanos), NanosecondsPerSecond)

proc shiftDate*(dt: DateTime, q: VQuantity, negative: static bool = false): DateTime =
    ## shift given date by given time quantity
    ##
    ## Months and years are applied as *calendar* steps (so that adding a year
    ## keeps the same month/day and time-of-day); anything else is applied as
    ## an exact duration, down to the nanosecond.

    # calendar-aware shifts, for whole months/years
    let (isMonths, nMonths) = isWholeCalendarUnit(q, parseAtoms("mo"))
    if isMonths:
        let n = when negative: -nMonths else: nMonths
        return dt + initTimeInterval(months = n)

    let (isYears, nYears) = isWholeCalendarUnit(q, parseAtoms("yr"))
    if isYears:
        let n = when negative: -nYears else: nYears
        return dt + initTimeInterval(years = n)

    # everything else: an exact duration
    #
    # Note: we deliberately avoid going through `toFloat` here. A float64 has
    # a 53-bit mantissa, so it cannot hold a nanosecond count beyond ~104 days
    # without silently rounding. Instead we split the *rational* into whole
    # seconds + nanoseconds using integer division only, which is exact for
    # the full range Nim's `Duration` can represent.
    var secs = asSeconds(q)

    when negative:
        secs = secs * toRational(-1)

    let (wholeSecs, nanos) = splitSecondsExactly(secs)

    result = dt + initDuration(seconds = int(wholeSecs), nanoseconds = int(nanos))
