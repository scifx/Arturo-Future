#=======================================================
# Arturo
# Programming Language + Bytecode VM compiler
# (c) 2019-2026 Yanis Zafirópulos
#
# @file: vm/locales.nim
#=======================================================

## Keyword localization support.
##
## This module lets users write Arturo programs using
## keywords in their own language, by loading translation
## files (see the `setupLocales` proc) that map localized
## keywords onto their canonical English counterparts.

#=======================================
# Libraries
#=======================================

import os, tables

import helpers/jsonobject
import vm/[globals, values/value]

#=======================================
# Global Variables
#=======================================

var
    CmdlineLocalePath* : string = ""
        ## Path to a locale translation file,
        ## given via the `--locale` option

#=======================================
# Helpers
#=======================================

proc registerAliases(aliases: Value) =
    ## Register given keyword aliases in the symbol table
    ##
    ## `aliases` is expected to be a Dictionary where each
    ## key is a canonical (English) keyword and its value is
    ## either a single translated keyword - or a Block holding
    ## several of them (e.g. several words meaning the same thing)
    for sourceName, translated in pairs(aliases.d):
        let sym = Syms.getOrDefault(sourceName)
        if sym.isNil:
            continue

        case translated.kind:
            of String:
                SetSym(translated.s, sym)
            of Block:
                for t in translated.a:
                    if t.kind == String:
                        SetSym(t.s, sym)
            else:
                discard

proc loadLocaleFile(path: string) =
    ## Load a locale translation file and register
    ## its keyword aliases
    ##
    ## **Hint:** may raise if the file is missing or
    ## not valid JSON - callers should guard accordingly
    let content = valueFromJson(readFile(path))
    if content.kind == Dictionary:
        registerAliases(content)

proc setupLocales*() =
    ## Load any user-provided keyword translations:
    ##
    ## * an explicit file given via `--locale`
    ## * every `*.json` file inside `~/.arturo/locales/`
    ##
    ## Aliases are additive; later files override earlier ones.
    ## A malformed (or missing) locale file is skipped, with a
    ## warning printed to stderr - it should never be fatal.
    when not defined(WEB):
        if CmdlineLocalePath != "":
            try:
                loadLocaleFile(CmdlineLocalePath)
            except CatchableError:
                stderr.writeLine("warning: could not load locale file: " & CmdlineLocalePath)

        let localesDir = os.getHomeDir().joinPath(".arturo").joinPath("locales")
        if os.dirExists(localesDir):
            for file in os.walkFiles(localesDir / "*.json"):
                try:
                    loadLocaleFile(file)
                except CatchableError:
                    stderr.writeLine("warning: could not load locale file: " & file)
