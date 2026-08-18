#=======================================================
# Arturo
# Programming Language + Bytecode VM compiler
# (c) 2019-2026 Yanis Zafirópulos
#
# @file: helpers/streaming.nim
#=======================================================

## Incremental producers for `execute.stream` and `request.stream`.
##
## Design note:
## - Neither of these introduces a new kind of "stream" value. They both
##   produce plain `:iterator` values, built on `newProducedIterator`, so
##   every existing consumer (`loop`, `map`, `take`, `next`, `empty?`, ...)
##   works on them unchanged.
## - Back-pressure comes for free: the producer fiber blocks on the bounded
##   channel inside `emitIteratorValue`, which stops us draining the pipe /
##   socket, which pushes back on the child process / TCP window.

#=======================================
# Pragmas
#=======================================

{.used.}

#=======================================
# Libraries
#=======================================

when not defined(WEB):
    import asyncdispatch
    import httpclient, httpcore
    import osproc, strutils, tables

    when defined(posix):
        import asyncfile
        import posix
    else:
        # On Windows `osproc` builds its stdout pipe with `CreatePipe`, which
        # yields a *synchronous* handle. Handing that to `newAsyncFile` (i.e.
        # IOCP + OVERLAPPED reads) fails with ERROR_INVALID_PARAMETER, so we
        # poll the pipe with `PeekNamedPipe` and read it synchronously instead.
        import winlean

    import helpers/iteratorstate
    import helpers/jsonobject
    import helpers/parallelism

    import vm/values/value
    import vm/values/custom/verror

#=======================================
# Types
#=======================================

when not defined(WEB):
    type
        StreamUnit* = enum
            ## How raw bytes coming off the wire are cut into iterator items.
            StreamLines     ## one item per line (default; pipeline-friendly)
            StreamBuffer    ## one item per fixed-size chunk, as received
            StreamEvents    ## one item per SSE event (`request` only)

#=======================================
# Helpers
#=======================================

when not defined(WEB):

    const DefaultStreamBuffer* = 4096

    when not defined(posix):
        const WinPipePollMs = 15
            ## How long to park between `PeekNamedPipe` probes when the child
            ## has produced nothing yet. Small enough to stay responsive for
            ## interactive output, large enough not to spin the CPU.

        proc winPipeRead(handle: Handle, size: int,
                         stillRunning: proc(): bool {.closure.},
                         abandoned: proc(): bool {.closure.}): string =
            ## Cooperative, non-blocking read from a synchronous pipe.
            ##
            ## Returns "" only at real end-of-stream. A plain blocking
            ## `ReadFile` would stall the whole scheduler (every other fiber
            ## included) until the child writes, so we peek first and yield
            ## back to the dispatcher whenever the pipe is empty.
            var buf = newString(size)
            while true:
                # `unplug` may have closed the handle while we were parked
                if abandoned():
                    return ""

                var avail: int32 = 0
                if not peekNamedPipe(handle, nil, 0, nil, addr avail, nil):
                    # broken pipe == child closed its end == EOF
                    return ""

                if avail > 0:
                    var toRead = avail.int
                    if toRead > size:
                        toRead = size
                    var got: int32 = 0
                    if readFile(handle, addr buf[0], toRead.int32,
                                addr got, nil) == 0 or got <= 0:
                        return ""
                    buf.setLen(got)
                    return buf

                # nothing buffered: if the child is gone and the pipe stayed
                # empty, we're done; otherwise let other fibers run
                if not stillRunning():
                    var avail2: int32 = 0
                    if not peekNamedPipe(handle, nil, 0, nil, addr avail2, nil) or
                       avail2 <= 0:
                        return ""
                    continue

                coopWait sleepAsync(WinPipePollMs)

    proc emitLines(state: IteratorState, pending: var string, data: string) =
        ## Append `data` to `pending` and yield every *complete* line found.
        ## The trailing partial line stays in `pending`.
        pending.add(data)
        var start = 0
        while true:
            let nl = pending.find('\n', start)
            if nl < 0:
                break
            var line = pending[start ..< nl]
            if line.len > 0 and line[^1] == '\r':
                line.setLen(line.len - 1)
            yieldToIterator(state, newString(line))
            start = nl + 1
        if start > 0:
            pending = pending[start .. ^1]

    proc flushLines(state: IteratorState, pending: var string) =
        ## Yield whatever is left over once the source is done (a last line
        ## without a trailing newline is still a line).
        if pending.len > 0:
            var line = pending
            if line[^1] == '\r':
                line.setLen(line.len - 1)
            yieldToIterator(state, newString(line))
            pending.setLen(0)

    proc sseEventToValue(raw: string, ok: var bool): Value =
        ## Turn one raw SSE frame into `#[event: data: id: retry:]`, following
        ## the spec: `data:` fields accumulate joined by newlines, a leading
        ## space after the colon is stripped, `:`-prefixed lines are comments.
        ## `ok` comes back false for frames that carry no fields at all (e.g.
        ## keep-alive comments), which the caller should simply drop.
        var
            evName = ""
            evData: seq[string] = @[]
            evId = ""
            evRetry = ""

        ok = false

        for rawLine in raw.splitLines():
            var line = rawLine
            if line.len > 0 and line[^1] == '\r':
                line.setLen(line.len - 1)
            if line.len == 0 or line[0] == ':':
                continue

            var field = line
            var val = ""
            let colon = line.find(':')
            if colon >= 0:
                field = line[0 ..< colon]
                val = line[(colon + 1) .. ^1]
                if val.len > 0 and val[0] == ' ':
                    val = val[1 .. ^1]

            case field
                of "event": evName = val; ok = true
                of "data":  evData.add(val); ok = true
                of "id":    evId = val; ok = true
                of "retry": evRetry = val; ok = true
                else:       discard

        var d = initOrderedTable[string, Value]()
        let rawData = evData.join("\n")

        d["event"] = newString(evName)
        d["data"] = newString(rawData)
        d["id"] = newString(evId)
        d["retry"] = newString(evRetry)

        # Practically every SSE producer worth streaming (OpenAI & friends)
        # puts JSON in `data:`. Decode it here so the caller can reach straight
        # for `ev\json\...` instead of hand-writing `read.json ev\data` on every
        # single frame. Non-JSON payloads (`[DONE]`, plain text, keep-alives)
        # simply leave `json` as :null - `data` always stays the raw string.
        var decoded = VNULL
        let trimmed = rawData.strip()
        if trimmed.len > 1 and (trimmed[0] == '{' or trimmed[0] == '['):
            try:
                decoded = valueFromJson(trimmed)
            except CatchableError:
                decoded = VNULL
        d["json"] = decoded

        result = newDictionary(d)

    proc emitEvents(state: IteratorState, pending: var string, data: string) =
        ## SSE frames are separated by a blank line.
        pending.add(data)
        while true:
            var sep = pending.find("\n\n")
            var sepLen = 2
            let sepR = pending.find("\r\n\r\n")
            if sepR >= 0 and (sep < 0 or sepR < sep):
                sep = sepR
                sepLen = 4
            if sep < 0:
                break
            let frame = pending[0 ..< sep]
            pending = pending[(sep + sepLen) .. ^1]
            if frame.strip().len > 0:
                var ok = false
                let ev = sseEventToValue(frame, ok)
                if ok:
                    yieldToIterator(state, ev)

    proc flushEvents(state: IteratorState, pending: var string) =
        if pending.strip().len > 0:
            var ok = false
            let ev = sseEventToValue(pending, ok)
            if ok:
                yieldToIterator(state, ev)
            pending.setLen(0)

    proc feed(state: IteratorState, unit: StreamUnit,
              pending: var string, data: string) {.inline.} =
        case unit
            of StreamLines:  emitLines(state, pending, data)
            of StreamEvents: emitEvents(state, pending, data)
            of StreamBuffer: yieldToIterator(state, newString(data))

    proc flush(state: IteratorState, unit: StreamUnit,
               pending: var string) {.inline.} =
        case unit
            of StreamLines:  flushLines(state, pending)
            of StreamEvents: flushEvents(state, pending)
            of StreamBuffer: discard

#=======================================
# Shell command streaming
#=======================================

when not defined(WEB):

    proc newShellStreamIterator*(fullCmd: string,
                                 unit: StreamUnit = StreamLines,
                                 bufSize: int = DefaultStreamBuffer): Value =
        ## `execute.stream` — yields the child's output as it is produced,
        ## rather than waiting for the process to finish.
        ##
        ## stderr is folded into stdout, matching plain `execute`. The exit
        ## code is published on the iterator object as `\exit` once the
        ## stream is exhausted.

        var
            child: Process = nil
            closed = false
        when defined(posix):
            var reader: AsyncFile = nil

        proc closeReader() =
            when defined(posix):
                if not reader.isNil:
                    try: reader.close()
                    except CatchableError: discard
                    reader = nil

        proc shutdown() =
            if closed:
                return
            closed = true
            closeReader()
            if not child.isNil:
                try:
                    if child.running:
                        child.terminate()
                        discard child.waitForExit()
                except CatchableError: discard
                try: child.close()
                except CatchableError: discard
                child = nil

        proc producer(state: IteratorState) =
            child = startProcess(
                command = fullCmd,
                options = {poUsePath, poEvalCommand, poStdErrToStdOut}
            )

            when defined(posix):
                # dup the read end so closing our AsyncFile never fights with
                # `Process.close()` over the same descriptor
                let fd = dup(cint(child.outputHandle))
                discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)
                reader = newAsyncFile(AsyncFD(fd))
            else:
                let pipeHandle = Handle(child.outputHandle)
                let liveChild = child
                proc childRunning(): bool {.closure.} =
                    try: liveChild.running
                    except CatchableError: false
                proc wasAbandoned(): bool {.closure.} = closed

            var pending = ""
            try:
                while true:
                    when defined(posix):
                        let data = coopWait reader.read(bufSize)
                    else:
                        if closed:
                            break
                        let data = winPipeRead(pipeHandle, bufSize,
                                               childRunning, wasAbandoned)
                    if data.len == 0:
                        break
                    feed(state, unit, pending, data)
                flush(state, unit, pending)
            finally:
                closeReader()

                var code = -1
                if not child.isNil:
                    try:
                        code = child.waitForExit()
                    except CatchableError: discard
                    try: child.close()
                    except CatchableError: discard
                    child = nil
                closed = true
                setIteratorMeta(state, "exit", newInteger(code))

        result = newProducedIterator(
            "shell",
            rebuild = proc(): Value = newShellStreamIterator(fullCmd, unit, bufSize),
            producer = producer,
            onState = proc(state: IteratorState) =
                state.closeHook = shutdown
                setIteratorMeta(state, "exit", VNULL)
        )

#=======================================
# HTTP response streaming
#=======================================

when not defined(WEB):

    proc newHttpStreamIterator*(client: AsyncHttpClient,
                                resp: AsyncResponse,
                                unit: StreamUnit = StreamLines): Value =
        ## The `\body` of a `request.stream` response: pulls chunks off the
        ## still-open connection as the server writes them.

        var closed = false

        proc shutdown() =
            if closed:
                return
            closed = true
            try: client.close()
            except CatchableError: discard

        proc producer(state: IteratorState) =
            var pending = ""
            try:
                while true:
                    let (hasData, data) = coopWait resp.bodyStream.read()
                    if not hasData:
                        break
                    if data.len > 0:
                        feed(state, unit, pending, data)
                flush(state, unit, pending)
            finally:
                shutdown()

        result = newProducedIterator(
            "http",
            rebuild = nil,          # a consumed connection cannot be replayed
            producer = producer,
            onState = proc(state: IteratorState) =
                state.closeHook = shutdown
        )
