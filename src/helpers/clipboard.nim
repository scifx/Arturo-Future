#=======================================================
# Arturo
# Programming Language + Bytecode VM compiler
# (c) 2019-2026 Yanis Zafirópulos
#
# @file: helpers/clipboard.nim
#=======================================================

#=======================================
# Libraries
#=======================================

when defined(NOUI):
    import os, osproc, strformat
else:
    import extras/libclipboard

#=======================================
# Helpers
#=======================================

when defined(NOUI):
    proc hasCommand(cmd: string): bool =
        findExe(cmd) != ""

    proc tempClipboardFile(): string =
        getTempDir() / fmt"arturo-clipboard-{getCurrentProcessId()}"

    proc pipeTo(command: string, content: string): bool =
        let tmp = tempClipboardFile()
        try:
            tmp.writeFile(content)
            result = execShellCmd(command & " < " & quoteShell(tmp)) == 0
        finally:
            try:
                removeFile(tmp)
            except OSError:
                discard

    proc readFrom(command: string): string =
        let res = execCmdEx(command)
        if res.exitCode == 0:
            result = res.output
        else:
            result = ""

#=======================================
# Methods
#=======================================

when defined(NOUI):
    proc setClipboard*(content: string) =
        when defined(windows):
            if hasCommand("clip"):
                discard pipeTo("clip", content)
        elif defined(macosx):
            if hasCommand("pbcopy"):
                discard pipeTo("pbcopy", content)
        else:
            if hasCommand("termux-clipboard-set"):
                discard pipeTo("termux-clipboard-set", content)
            elif hasCommand("wl-copy"):
                discard pipeTo("wl-copy", content)
            elif hasCommand("xclip"):
                discard pipeTo("xclip -selection clipboard", content)
            elif hasCommand("xsel"):
                discard pipeTo("xsel --clipboard --input", content)

    proc getClipboard*(): string =
        when defined(windows):
            if hasCommand("powershell"):
                result = readFrom("powershell -NoProfile -Command Get-Clipboard")
            else:
                result = ""
        elif defined(macosx):
            if hasCommand("pbpaste"):
                result = readFrom("pbpaste")
            else:
                result = ""
        else:
            if hasCommand("termux-clipboard-get"):
                result = readFrom("termux-clipboard-get")
            elif hasCommand("wl-paste"):
                result = readFrom("wl-paste --no-newline")
            elif hasCommand("xclip"):
                result = readFrom("xclip -selection clipboard -o")
            elif hasCommand("xsel"):
                result = readFrom("xsel --clipboard --output")
            else:
                result = ""
else:
    proc setClipboard*(content: string) =
        var clipboard = clipboard_new(nil)
        clipboard.clipboard_clear(LCB_CLIPBOARD)
        clipboard.clipboard_set_text(content.cstring)
        clipboard.clipboard_free()

    proc getClipboard*(): string =
        var clipboard = clipboard_new(nil)
        let cresult = clipboard.clipboard_text()
        return $(cresult)
