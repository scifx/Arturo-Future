#=======================================================
# Arturo
# Programming Language + Bytecode VM compiler
# (c) 2019-2026 Yanis Zafirópulos
#
# @file: helpers/environment.nim
#=======================================================

## Runtime backing for Arturo's `:environment` value - the live view
## of the current process' environment variables, as returned by `env`.
##
## Design note:
## - `env` used to return a plain `:dictionary` snapshot; writing to it
##   (`env\PATH: ...`) silently modified a throwaway copy.
## - Now it returns a single, cached `:environment` object whose `get`/`set`
##   magic methods talk directly to the process environment, so
##   `env\PATH: env\PATH ++ ":/opt/bin"` actually works - and is visible to
##   any child process spawned afterwards.
## - Setting a key to `null` *removes* the variable, mirroring Arturo's
##   general "null means absent" semantics.

#=======================================
# Libraries
#=======================================

import std/[os, tables]

import vm/values/value
import vm/values/printable
import vm/values/types
import vm/stack

#=======================================
# Constants
#=======================================

const
    EnvironmentTypeName* = "environment"

#=======================================
# Variables
#=======================================

var
    environmentPrototype: Prototype
    environmentValue: Value

#=======================================
# Helpers
#=======================================

proc syncEnvironmentFields(v: Value) =
    ## Mirror the *current* environment onto the object's own fields, so that
    ## `keys`, `values`, `loop`, `size`, `to :dictionary`, printing, etc. all
    ## keep working exactly as they did when `env` was a plain dictionary.
    v.o.clear()
    for k, val in envPairs():
        v.o[k] = newString(val)

proc environmentGet(args: ValueArray) =
    ## `get` magic method: consulted only when the key isn't already an
    ## object field. Re-reads the live environment so that variables set
    ## behind Arturo's back (e.g. by a child process helper) are still seen.
    let key = args[1].s
    if existsEnv(key):
        push(newString(getEnv(key)))
    else:
        push(VNULL)

proc environmentSet(args: ValueArray) =
    ## `set` magic method: writes straight through to the process environment.
    ## A `null` value deletes the variable.
    let this = args[0]
    let key = args[1].s
    let val = args[2]

    if val.kind == Null:
        if existsEnv(key):
            delEnv(key)
        this.o.del(key)
    else:
        let str =
            if val.kind == String: val.s
            else: $(val)
        putEnv(key, str)
        this.o[key] = newString(str)

proc ensureEnvironmentPrototype*(): Prototype =
    if environmentPrototype.isNil:
        environmentPrototype = newPrototype(
            EnvironmentTypeName,
            newOrderedTable[string, Value](),
            VNULL
        )
        setType(EnvironmentTypeName, environmentPrototype)

    result = environmentPrototype

#=======================================
# Methods
#=======================================

proc getEnvironmentValue*(): Value =
    ## Return the one-and-only `:environment` value, freshly synced with
    ## the actual process environment.
    if environmentValue.isNil:
        var magicMethods = MagicMethods()
        magicMethods[GetM] = environmentGet
        magicMethods[SetM] = environmentSet

        environmentValue = newObject(
            ensureEnvironmentPrototype(),
            newOrderedTable[string, Value](),
            magicMethods
        )

    syncEnvironmentFields(environmentValue)
    result = environmentValue

func isEnvironmentObject*(v: Value): bool {.inline.} =
    v.kind == Object and
    (not v.proto.isNil) and
    v.proto.name == EnvironmentTypeName
