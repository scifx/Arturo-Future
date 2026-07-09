#=======================================================
# Arturo
# Programming Language + Bytecode VM compiler
# (c) 2019-2026 Yanis Zafirópulos
#
# @file: helpers/iteratorstate.nim
#=======================================================

## Runtime backing for Arturo's `:iterator` values.
##
## Design note:
## - `:iterator` is the runtime value being consumed.
## - `generator` is one elegant way to create such a value.
## - `to :iterator` also creates one, but does so lazily by wiring the
##   source into the same channel/yield pipeline, not by materializing
##   another list first.

#=======================================
# Libraries
#=======================================

import std/[asyncfutures, deques, os, strutils, tables, unicode]
import parsecsv, streams

import helpers/objects
import helpers/parallelism

import vm/[errors, exec, globals, stack]
import vm/values/custom/[verror, vrange]
import vm/values/value

#=======================================
# Constants
#=======================================

const
    IteratorTypeName*    = "iterator"
    IteratorIdField*     = "__iteratorId"
    IteratorSourceField* = "source"
    IteratorDoneField*   = "exhausted"
    IteratorRewindField* = "rewindable"

#=======================================
# Types
#=======================================

type
    IteratorState* = ref object
        sourceName*  : string
        stream*      : VChannel
        pull*        : proc(value: var Value): bool {.closure.}
        seekTo*      : proc(position: int64) {.closure.}
        tellPos*     : proc(): int64 {.closure.}
        lengthOf*    : proc(): int64 {.closure.}
        finished*    : bool
        hasPeeked*   : bool
        peeked*      : Value
        rebuild*     : proc(): Value {.closure.}

#=======================================
# Variables
#=======================================

var
    iteratorPrototype: Prototype
    iteratorCounter: int
    iteratorStates = initTable[string, IteratorState]()

#=======================================
# Helpers
#=======================================

proc ensureIteratorPrototype*(): Prototype =
    if iteratorPrototype.isNil:
        iteratorPrototype = newPrototype(
            IteratorTypeName,
            newOrderedTable[string,Value](),
            VNULL
        )
        setType(IteratorTypeName, iteratorPrototype)

    result = iteratorPrototype

func canRewind*(state: IteratorState): bool {.inline.} =
    (not state.isNil) and (not state.rebuild.isNil)

proc syncMeta(it: Value, state: IteratorState) =
    if it.kind == Object:
        it.o[IteratorDoneField] = newLogical(state.finished)
        it.o[IteratorRewindField] = newLogical(canRewind(state))

func isIteratorObject*(v: Value): bool {.inline.} =
    v.kind == Object and
    (not v.proto.isNil) and
    v.proto.name == IteratorTypeName and
    v.o.hasKey(IteratorIdField) and
    v.o[IteratorIdField].kind == String

proc getIteratorState*(it: Value): IteratorState =
    if not isIteratorObject(it):
        Error_OperationNotPermitted("Expected a :iterator value")

    let iteratorId = it.o[IteratorIdField].s
    if not iteratorStates.hasKey(iteratorId):
        Error_OperationNotPermitted("Iterator state is no longer available")

    result = iteratorStates[iteratorId]

proc newInternalChannel(name: string): VChannel =
    ## Small bounded buffer reduces per-item producer/consumer ping-pong
    ## while keeping memory usage effectively streaming-friendly.
    VChannel(
        name: name,
        capacity: 256,
        closed: false,
        buffer: initDeque[Value](),
        senders: initDeque[tuple[v: Value, f: Future[void]]](),
        receivers: initDeque[Future[Value]]()
    )

proc wrapYieldPacket(v: Value): Value {.inline.} =
    newBlock(@[VTRUE, v])

proc wrapFailurePacket(v: Value): Value {.inline.} =
    newBlock(@[VFALSE, v])

proc registerIterator(state: IteratorState): string =
    discard ensureIteratorPrototype()

    inc iteratorCounter
    result = "iterator#" & $iteratorCounter
    iteratorStates[result] = state

proc iteratorFromState(state: IteratorState): Value =
    var fields = newOrderedTable[string,Value]()
    let iteratorId = registerIterator(state)

    fields[IteratorIdField] = newString(iteratorId)
    fields[IteratorSourceField] = newLiteral(state.sourceName)
    fields[IteratorDoneField] = VFALSE
    fields[IteratorRewindField] = newLogical(canRewind(state))

    result = newObject(ensureIteratorPrototype(), fields)

proc emitIteratorValue(state: IteratorState, v: Value) =
    coopWait chanSend(state.stream, wrapYieldPacket(v))

proc emitIteratorFailure(state: IteratorState, v: Value) =
    coopWait chanSend(state.stream, wrapFailurePacket(v))

proc finishIteratorProducer(state: IteratorState) =
    chanClose(state.stream)

proc yieldToIterator*(state: IteratorState, v: Value) =
    emitIteratorValue(state, v)

proc newProducedIterator*(
    sourceName: string,
    rebuild: proc(): Value {.closure.} = nil,
    producer: proc(state: IteratorState) {.closure.}
): Value =
    let state = IteratorState(
        sourceName: sourceName,
        stream: newInternalChannel("iterator:" & sourceName & ":" & $(iteratorCounter + 1)),
        pull: nil,
        seekTo: nil,
        tellPos: nil,
        lengthOf: nil,
        finished: false,
        hasPeeked: false,
        peeked: VNULL,
        rebuild: rebuild
    )

    result = iteratorFromState(state)

    discard spawnFiber(proc () =
        let ctx = currentVMContext()
        if not ctx.isNil:
            ctx.generatorId = ""

        try:
            producer(state)
        except CatchableError as e:
            emitIteratorFailure(state, newError(RuntimeErr, e.msg))
        finally:
            finishIteratorProducer(state)
    , Syms)

proc newPullIterator*(
    sourceName: string,
    rebuild: proc(): Value {.closure.} = nil,
    pull: proc(value: var Value): bool {.closure.},
    seekTo: proc(position: int64) {.closure.} = nil,
    tellPos: proc(): int64 {.closure.} = nil,
    lengthOf: proc(): int64 {.closure.} = nil
): Value =
    let state = IteratorState(
        sourceName: sourceName,
        stream: nil,
        pull: pull,
        seekTo: seekTo,
        tellPos: tellPos,
        lengthOf: lengthOf,
        finished: false,
        hasPeeked: false,
        peeked: VNULL,
        rebuild: rebuild
    )

    result = iteratorFromState(state)

proc yieldFromCurrentGenerator*(v: Value) =
    let ctx = currentVMContext()
    if ctx.isNil or ctx.generatorId.len == 0:
        Error_OperationNotPermitted("`yield` may only be used inside a `generator` body")

    let iteratorId = ctx.generatorId
    if not iteratorStates.hasKey(iteratorId):
        Error_OperationNotPermitted("Generator iterator state is no longer available")

    emitIteratorValue(iteratorStates[iteratorId], v)

proc spawnSourceProducer(state: IteratorState, source: Value) =
    discard spawnFiber(proc () =
        let ctx = currentVMContext()
        if not ctx.isNil:
            ctx.generatorId = ""

        try:
            case source.kind:
                of Block, Inline:
                    for item in source.a:
                        emitIteratorValue(state, item)

                of Range:
                    let rng = source.rng
                    var current = rng.start
                    let step =
                        if rng.forward: rng.step
                        else:          -rng.step
                    var produced = 0
                    while produced < rng.len:
                        if rng.numeric:
                            emitIteratorValue(state, newInteger(current))
                        else:
                            emitIteratorValue(state, newChar(char(current)))
                        current += step
                        inc produced

                of String:
                    for r in runes(source.s):
                        emitIteratorValue(state, newChar(r))

                of Dictionary:
                    for k,v in source.d.pairs:
                        emitIteratorValue(state, newString(k))
                        emitIteratorValue(state, v)

                of Object:
                    for k,v in source.o.objectPairs:
                        emitIteratorValue(state, newString(k))
                        emitIteratorValue(state, v)

                of Integer:
                    for i in 1..source.i:
                        emitIteratorValue(state, newInteger(i))

                else:
                    emitIteratorFailure(state,
                        newError(RuntimeErr, "Cannot convert " & $(source.kind) & " to :iterator"))
        except CatchableError as e:
            emitIteratorFailure(state, newError(RuntimeErr, e.msg))
        finally:
            finishIteratorProducer(state)
    , Syms)

proc spawnBodyProducer(iteratorId: string, state: IteratorState, body: Value) =
    discard spawnFiber(proc () =
        let ctx = currentVMContext()
        if not ctx.isNil:
            ctx.generatorId = iteratorId

        try:
            let prevSP = SP
            execUnscoped(body)
            if SP > prevSP:
                discard pop()
        except CatchableError as e:
            emitIteratorFailure(state, newError(RuntimeErr, e.msg))
        finally:
            if not ctx.isNil:
                ctx.generatorId = ""
            finishIteratorProducer(state)
    , Syms)

proc newSourceIteratorImpl(source: Value, sourceName: string, rewindable = true): Value
proc newGeneratorIteratorFromBody*(bodyBuilder: proc(): Value {.closure.}, sourceName: string = "generator"): Value
proc newTakeIterator*(source: Value, count: int): Value
proc newDropIterator*(source: Value, count: int): Value
proc newCsvStreamIterator*(path: string, withHeaders: bool = false, delimiter: char = ','): Value
proc newBufferStreamIterator*(path: string, chunkSize: int, asBinary = false, startOffset: int64 = 0): Value
proc newIterator*(source: Value): Value
proc nextIteratorValue*(it: Value, value: var Value): bool

proc newSourceIteratorImpl(source: Value, sourceName: string, rewindable = true): Value =
    let state = IteratorState(
        sourceName: sourceName,
        stream: newInternalChannel("iterator:" & sourceName & ":" & $(iteratorCounter + 1)),
        finished: false,
        hasPeeked: false,
        peeked: VNULL,
        rebuild: if rewindable: (proc(): Value = newSourceIteratorImpl(source, sourceName, rewindable)) else: nil
    )

    result = iteratorFromState(state)
    spawnSourceProducer(state, source)

proc newGeneratorIteratorFromBody*(bodyBuilder: proc(): Value {.closure.}, sourceName: string = "generator"): Value =
    let state = IteratorState(
        sourceName: sourceName,
        stream: newInternalChannel("iterator:" & sourceName & ":" & $(iteratorCounter + 1)),
        finished: false,
        hasPeeked: false,
        peeked: VNULL,
        rebuild: proc(): Value = newGeneratorIteratorFromBody(bodyBuilder, sourceName)
    )

    result = iteratorFromState(state)
    let iteratorId = result.o[IteratorIdField].s
    spawnBodyProducer(iteratorId, state, bodyBuilder())

proc newLineStreamIterator*(path: string): Value =
    if not fileExists(path):
        Error_FileNotFound(path)

    let state = IteratorState(
        sourceName: "lines",
        stream: newInternalChannel("iterator:lines:" & $(iteratorCounter + 1)),
        finished: false,
        hasPeeked: false,
        peeked: VNULL,
        rebuild: proc(): Value = newLineStreamIterator(path)
    )

    result = iteratorFromState(state)

    discard spawnFiber(proc () =
        let ctx = currentVMContext()
        if not ctx.isNil:
            ctx.generatorId = ""

        var f: File
        var fileOpened = false
        try:
            if not open(f, path, fmRead):
                Error_FileNotFound(path)
            fileOpened = true

            var line: string
            while f.readLine(line):
                emitIteratorValue(state, newString(line))
        except CatchableError as e:
            emitIteratorFailure(state, newError(RuntimeErr, e.msg))
        finally:
            try:
                if fileOpened:
                    f.close()
            except CatchableError:
                discard
            finishIteratorProducer(state)
    , Syms)

proc newCsvStreamIterator*(path: string, withHeaders: bool = false, delimiter: char = ','): Value =
    if not fileExists(path):
        Error_FileNotFound(path)

    let state = IteratorState(
        sourceName: "csv",
        stream: newInternalChannel("iterator:csv:" & $(iteratorCounter + 1)),
        finished: false,
        hasPeeked: false,
        peeked: VNULL,
        rebuild: proc(): Value = newCsvStreamIterator(path, withHeaders, delimiter)
    )

    result = iteratorFromState(state)

    discard spawnFiber(proc () =
        let ctx = currentVMContext()
        if not ctx.isNil:
            ctx.generatorId = ""

        var fs: Stream = nil
        var csv: CsvParser
        try:
            fs = newFileStream(path, fmRead)
            if fs.isNil:
                Error_FileNotFound(path)

            open(csv, fs, path, separator=delimiter)
            if withHeaders:
                readHeaderRow(csv)

            while readRow(csv):
                if withHeaders:
                    var row: ValueDict = initOrderedTable[string,Value]()
                    for col in items(csv.headers):
                        row[col] = newString(csv.rowEntry(col))
                    emitIteratorValue(state, newDictionary(row))
                else:
                    var row: ValueArray
                    for val in items(csv.row):
                        row.add(newString(val))
                    emitIteratorValue(state, newBlock(row))
        except CatchableError as e:
            emitIteratorFailure(state, newError(RuntimeErr, e.msg))
        finally:
            try:
                close(csv)
            except CatchableError:
                discard
            try:
                if not fs.isNil:
                    fs.close()
            except CatchableError:
                discard
            finishIteratorProducer(state)
    , Syms)

proc newBufferStreamIterator*(path: string, chunkSize: int, asBinary = false, startOffset: int64 = 0): Value =
    if not fileExists(path):
        Error_FileNotFound(path)
    if chunkSize < 1:
        Error_OperationNotPermitted("`read.buffer:` expects a positive size")
    if startOffset < 0:
        Error_OperationNotPermitted("`seek` / `.seek:` expects a non-negative offset")

    var f: File
    var opened = false
    var offset = startOffset

    proc ensureOpen() =
        if not opened:
            if not open(f, path, fmRead):
                Error_FileNotFound(path)
            opened = true
            setFilePos(f, offset)

    proc doSeek(position: int64) =
        if position < 0:
            Error_OperationNotPermitted("`seek` expects a non-negative offset")
        offset = position
        if opened:
            setFilePos(f, offset)

    proc pull(value: var Value): bool =
        ensureOpen()
        if asBinary:
            var buf = newSeq[byte](chunkSize)
            let got = f.readBytes(buf, 0, chunkSize)
            if got <= 0:
                return false
            if got < chunkSize:
                buf.setLen(got)
            offset = getFilePos(f)
            value = newBinary(buf)
            return true
        else:
            var chunk = newString(chunkSize)
            let got = f.readChars(toOpenArray(chunk, 0, chunkSize - 1))
            if got <= 0:
                return false
            chunk.setLen(got)
            offset = getFilePos(f)
            value = newString(chunk)
            return true

    result = newPullIterator(
        "buffer",
        rebuild = proc(): Value = newBufferStreamIterator(path, chunkSize, asBinary, startOffset),
        pull = pull,
        seekTo = doSeek,
        tellPos = proc(): int64 = offset,
        lengthOf = proc(): int64 = getFileSize(path)
    )

proc newTakeIterator*(source: Value, count: int): Value =
    if count < 0:
        Error_OperationNotPermitted("`take.iterator` does not support negative counts")

    let rewindable = not isIteratorObject(source)
    let state = IteratorState(
        sourceName: "take",
        stream: newInternalChannel("iterator:take:" & $(iteratorCounter + 1)),
        finished: false,
        hasPeeked: false,
        peeked: VNULL,
        rebuild: if rewindable: (proc(): Value = newTakeIterator(source, count)) else: nil
    )

    result = iteratorFromState(state)

    discard spawnFiber(proc () =
        let ctx = currentVMContext()
        if not ctx.isNil:
            ctx.generatorId = ""

        let src = if isIteratorObject(source): source else: newIterator(source)
        try:
            var item: Value
            var left = count
            while left > 0 and nextIteratorValue(src, item):
                emitIteratorValue(state, item)
                dec left
        except CatchableError as e:
            emitIteratorFailure(state, newError(RuntimeErr, e.msg))
        finally:
            finishIteratorProducer(state)
    , Syms)

proc newDropIterator*(source: Value, count: int): Value =
    if count < 0:
        Error_OperationNotPermitted("`drop.iterator` does not support negative counts")

    let rewindable = not isIteratorObject(source)
    let state = IteratorState(
        sourceName: "drop",
        stream: newInternalChannel("iterator:drop:" & $(iteratorCounter + 1)),
        finished: false,
        hasPeeked: false,
        peeked: VNULL,
        rebuild: if rewindable: (proc(): Value = newDropIterator(source, count)) else: nil
    )

    result = iteratorFromState(state)

    discard spawnFiber(proc () =
        let ctx = currentVMContext()
        if not ctx.isNil:
            ctx.generatorId = ""

        let src = if isIteratorObject(source): source else: newIterator(source)
        try:
            var item: Value
            var left = count
            while left > 0 and nextIteratorValue(src, item):
                dec left

            while nextIteratorValue(src, item):
                emitIteratorValue(state, item)
        except CatchableError as e:
            emitIteratorFailure(state, newError(RuntimeErr, e.msg))
        finally:
            finishIteratorProducer(state)
    , Syms)

proc newIterator*(source: Value): Value =
    if isIteratorObject(source):
        return source

    case source.kind:
        of Block, Inline:
            newSourceIteratorImpl(source, "block")
        of Range:
            newSourceIteratorImpl(source, "range")
        of String:
            newSourceIteratorImpl(source, "string")
        of Dictionary:
            newSourceIteratorImpl(source, "dictionary")
        of Object:
            newSourceIteratorImpl(source, "object")
        of Integer:
            newSourceIteratorImpl(source, "integer")
        else:
            Error_OperationNotPermitted("Cannot convert :" & ($(source.kind)).toLowerAscii() & " to :iterator")
            VNULL

proc receiveIteratorPacket(state: IteratorState, value: var Value): bool =
    let packet = coopWait chanReceive(state.stream)
    if packet.kind == Null:
        state.finished = true
        value = VNULL
        return false

    if packet.kind == Block and packet.a.len == 2 and packet.a[0].kind == Logical:
        value = packet.a[1]
        if isFalse(packet.a[0]):
            state.finished = true
        return true

    value = packet
    true

proc nextIteratorValue*(it: Value, value: var Value): bool =
    let state = getIteratorState(it)

    if state.finished and not state.hasPeeked:
        value = VNULL
        syncMeta(it, state)
        return false

    if state.hasPeeked:
        state.hasPeeked = false
        value = state.peeked
        if state.finished:
            state.peeked = VNULL
        syncMeta(it, state)
        return true

    if not state.pull.isNil:
        result = state.pull(value)
        if not result:
            state.finished = true
            value = VNULL
    else:
        result = receiveIteratorPacket(state, value)
        if not result:
            value = VNULL

    syncMeta(it, state)

proc peekIteratorValue*(it: Value, value: var Value): bool =
    let state = getIteratorState(it)

    if state.finished and not state.hasPeeked:
        value = VNULL
        syncMeta(it, state)
        return false

    if state.hasPeeked:
        value = state.peeked
        syncMeta(it, state)
        return true

    if not state.pull.isNil:
        result = state.pull(state.peeked)
    else:
        result = receiveIteratorPacket(state, state.peeked)
    if result:
        state.hasPeeked = true
        value = state.peeked
    else:
        state.finished = true
        value = VNULL

    syncMeta(it, state)

proc tellIterator*(it: Value): int64 =
    let state = getIteratorState(it)
    if state.tellPos.isNil:
        Error_OperationNotPermitted("This iterator does not support tell")
    result = state.tellPos()

proc seekIterator*(it: Value, position: int64): Value =
    let state = getIteratorState(it)
    if state.seekTo.isNil:
        Error_OperationNotPermitted("This iterator does not support seek")

    state.seekTo(position)
    state.finished = false
    state.hasPeeked = false
    state.peeked = VNULL
    syncMeta(it, state)
    it

proc seekRelativeIterator*(it: Value, delta: int64): Value =
    let state = getIteratorState(it)
    if state.seekTo.isNil or state.tellPos.isNil:
        Error_OperationNotPermitted("This iterator does not support relative seek")
    let target = state.tellPos() + delta
    if target < 0:
        Error_OperationNotPermitted("Relative seek cannot move before the start of the source")
    seekIterator(it, target)

proc seekEndIterator*(it: Value, back: int64): Value =
    let state = getIteratorState(it)
    if state.seekTo.isNil or state.lengthOf.isNil:
        Error_OperationNotPermitted("This iterator does not support seek from end")
    let total = state.lengthOf()
    let target = total - back
    if target < 0:
        seekIterator(it, 0)
    else:
        seekIterator(it, target)

proc rewindIterator*(it: Value): Value =
    let state = getIteratorState(it)
    if not state.seekTo.isNil:
        discard seekIterator(it, 0)
        return it
    if state.rebuild.isNil:
        Error_OperationNotPermitted("This iterator cannot be rewound")

    let iteratorId = it.o[IteratorIdField].s
    let fresh = state.rebuild()
    let freshId = fresh.o[IteratorIdField].s
    iteratorStates[iteratorId] = iteratorStates[freshId]
    iteratorStates.del(freshId)

    syncMeta(it, iteratorStates[iteratorId])
    it

proc iteratorExhausted*(it: Value): bool =
    let state = getIteratorState(it)
    if state.finished and not state.hasPeeked:
        return true

    var peeked: Value
    return not peekIteratorValue(it, peeked)

proc iteratorRemainingHint*(it: Value): int =
    if iteratorExhausted(it): 0
    else: -1

proc iteratorDrain*(it: Value): ValueArray =
    ## Drain every remaining item from the iterator into a block. This is
    ## intentionally explicit: consumers that call it are choosing to
    ## materialize the stream.
    var item: Value
    while nextIteratorValue(it, item):
        result.add(item)
