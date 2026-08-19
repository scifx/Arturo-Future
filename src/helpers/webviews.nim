#=======================================================
# Arturo
# Programming Language + Bytecode VM compiler
# (c) 2019-2026 Yanis Zafirópulos
#
# @file: helpers/webview.nim
#=======================================================

#=======================================
# Libraries
#=======================================

import os, strutils
import vm/errors

when defined(posix):
    import posix

when defined(windows):
    import osproc

when defined(WEBVIEW):
    import std/json

    import extras/webview
    when defined(macosx):
        import extras/menubar
    import helpers/jsonobject
    import helpers/url
    import helpers/windows
    import vm/values/value

    export webview

#=======================================
# Types
#=======================================

when defined(WEBVIEW):
    type
        WebviewCallKind* = enum
            FunctionCall,
            ExecuteCode,
            WebviewEvent,
            UnrecognizedCall

        WebviewCallHandler* = proc (call: WebviewCallKind, value: Value): Value

#=======================================
# Variables
#=======================================

when defined(WEBVIEW):
    var
        mainWebview* {.global.}      : Webview
        mainCallHandler* {.global.}  : WebviewCallHandler

#=======================================
# Forward declarations
#=======================================

when defined(WEBVIEW):
    proc getWindow*(w: Webview): Window 

#=======================================
# Methods
#=======================================

proc openChromeWindow*(port: int, flags: seq[string] = @[]) =
    var args = @[
        "--app=http://localhost:" & port.intToStr & "/ ",
        "--disable-http-cache",
        "--disable-background-networking",
        "--disable-background-timer-throttling", 
        "--disable-backgrounding-occluded-windows", 
        "--disable-breakpad", 
        "--disable-client-side-phishing-detection", 
        "--disable-default-apps", 
        "--disable-dev-shm-usage", 
        "--disable-infobars", 
        "--disable-extensions", 
        "--disable-features=site-per-process", 
        "--disable-hang-monitor", 
        "--disable-ipc-flooding-protection", 
        "--disable-popup-blocking", 
        "--disable-prompt-on-repost", 
        "--disable-renderer-backgrounding", 
        "--disable-sync", 
        "--disable-translate", 
        "--disable-windows10-custom-titlebar", 
        "--metrics-recording-only", 
        "--no-first-run", 
        "--no-default-browser-check", 
        "--safebrowsing-disable-auto-update", 
        "--enable-automation", 
        "--password-store=basic", 
        "--use-mock-keychain"
    ]

    for flag in flags:
        args &= flag.strip

    var chromeBinaries: seq[string]
    var chromePath: string

    when hostOS == "macosx":
        chromeBinaries = @[
            r"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            r"/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
            r"/Applications/Chromium.app/Contents/MacOS/Chromium",
            r"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            r"/usr/bin/google-chrome-stable",
            r"/usr/bin/google-chrome",
            r"/usr/bin/chromium",
            r"/usr/bin/chromium-browser"
        ]
    elif hostOS == "windows":
        chromeBinaries = @[
            getEnv("LocalAppData") & r"/Google/Chrome/Application/chrome.exe",
            getEnv("ProgramFiles") & r"/Google/Chrome/Application/chrome.exe",
            getEnv("ProgramFiles(x86)") & r"/Google/Chrome/Application/chrome.exe",
            getEnv("LocalAppData") & r"/Chromium/Application/chrome.exe",
            getEnv("ProgramFiles") & r"/Chromium/Application/chrome.exe",
            getEnv("ProgramFiles(x86)") & r"/Chromium/Application/chrome.exe",
            getEnv("ProgramFiles(x86)") & r"/Microsoft/Edge/Application/msedge.exe",
            getEnv("ProgramFiles") & r"/Microsoft/Edge/Application/msedge.exe"
        ]
    elif hostOS == "linux":
        chromeBinaries = @[
            r"/usr/bin/google-chrome-stable",
            r"/usr/bin/google-chrome",
            r"/usr/bin/chromium",
            r"/usr/bin/chromium-browser",
            r"/snap/bin/chromium"
        ]

    for bin in chromeBinaries:
        if fileExists(bin):
            chromePath = bin
            break

    if chromePath == "":
        Error_CompatibleBrowserNotFound()
    else:
        let command = chromePath.replace(" ", r"\ ") & " " & args.join(" ")

        # launch the browser WITHOUT blocking the caller:
        #
        # `execCmd` here would wait for the window to close, stalling
        # everything (`serve .chrome` would only start serving after
        # the user closes the browser!). the browser is launched fully
        # detached instead - its lifetime is none of our business and
        # the server must never depend on a GUI window staying open.
        when defined(posix):
            # pre-build everything in the parent, so nothing has to be
            # allocated after fork (fork-safety inside a threaded VM)
            let shellCmd = "exec " & command & " >/dev/null 2>&1 </dev/null"

            let shPath = "/bin/sh".cstring
            let shArg0 = "sh".cstring
            let shArgC = "-c".cstring
            let shCmdC = shellCmd.cstring

            let pid = fork()

            if pid == Pid(0):
                # first child: break free of the server's session &
                # process group, so Ctrl+C on the server can't reach
                # the browser window
                discard setsid()

                let pid2 = fork()

                if pid2 == Pid(0):
                    # grandchild: the actual browser, fully detached -
                    # stdio goes to /dev/null so it can never block on
                    # a pipe we're not reading
                    discard execle(shPath, shArg0, shArgC, shCmdC, nil, nil)

                    # execle failed - exit quietly, there's nobody left
                    # to report it to anyway
                    exitnow(127)

                # middle child has done its job: exit right away so the
                # browser gets re-parented to init and reaped on its own
                exitnow(0)

            elif pid > Pid(0):
                # reap the middle child - it exits the moment it forks,
                # so this never blocks meaningfully
                var exitStatus: cint
                discard waitpid(pid, exitStatus, 0)
            else:
                Error_CompatibleBrowserCouldNotOpenWindow()
        elif defined(windows):
            # CreateProcess without waiting - the browser runs on its own.
            # `poDaemon` adds CREATE_NO_WINDOW, so no console window pops
            # up. dropping the returned handle is safe: it does not
            # terminate the child process.
            try:
                discard startProcess(command,
                                     options = {poUsePath, poEvalCommand, poDaemon})
            except OSError:
                Error_CompatibleBrowserCouldNotOpenWindow()
        else:
            # no meaningful way to open a browser window here
            discard

when defined(WEBVIEW):

    proc normalizeWebviewNewlines*(html: string): string =
        ## WebView2 + `{...}` curly strings on Windows inject CR LF.
        ## Keep a single LF so inline `<script>` stays valid everywhere.
        result = newStringOfCap(html.len)
        var i = 0
        while i < html.len:
            if html[i] == '\r':
                result.add('\n')
                if i + 1 < html.len and html[i + 1] == '\n':
                    inc i
            else:
                result.add(html[i])
            inc i

    proc looksLikeHtmlDocument*(html: string): bool =
        var i = 0
        while i < html.len and html[i] in {' ', '\t', '\n', '\r'}:
            inc i
        if i >= html.len:
            return false
        let head = html[i .. min(html.high, i + 20)].toLowerAscii()
        result = head.startsWith("<!doctype") or head.startsWith("<html")

    proc prepareWebviewHtml*(html: string): string =
        ## Make a fragment a real UTF-8 document. Full pages are left alone
        ## (apart from newline normalization). Init scripts still do the
        ## real bridge work; this only gives WebView2 a stable first load.
        let src = normalizeWebviewNewlines(html)
        if looksLikeHtmlDocument(src):
            return src
        result = "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n</head>\n<body>\n"
        result.add(src)
        result.add("\n</body>\n</html>\n")

    proc newWebView*(title       : string                = "Arturo",
                     content     : string                = "",
                     width       : int                   = 640,
                     height      : int                   = 480,
                     resizable   : bool                  = true,
                     maximized   : bool                  = false,
                     fullscreen  : bool                  = false,
                     borderless  : bool                  = false,
                     topmost     : bool                  = false,
                     debug       : bool                  = false,
                     initializer : string                = "",
                     callHandler : WebviewCallHandler    = nil): Webview =

        result = webview_create(debug.cint)
        discard webview_set_title(result, title=title.cstring)
        discard webview_set_size(result, width.cint, height.cint, if resizable: Constraints.Default else: Constraints.Fixed)

        # Bind + inject BEFORE the first navigation. WebView2 applies
        # AddScriptToExecuteOnDocumentCreated only to later documents;
        # set_html-first was why Windows needed a manual refresh.
        let bridgeJs = (static readFile(parentDir(currentSourcePath()) & "/webviews.js")) &
                       "\n" &
                       initializer
        discard webview_init(result, bridgeJs.cstring)

        let handler = proc (seqId: ccstring, req: ccstring, arg: pointer) {.cdecl.} =
            let replyId = $(cast[cstring](seqId))
            let raw = $(cast[cstring](req))
            var status = 0
            var payload = "null"

            try:
                let request = parseJson(raw)
                let mode = request.elems[0].str
                let value = valueFromJson(request.elems[1].str)

                var callKind: WebviewCallKind
                case mode:
                    of "call"   : callKind = FunctionCall
                    of "exec"   : callKind = ExecuteCode
                    of "event"  : callKind = WebviewEvent
                    else:
                        status = 1
                        callKind = UnrecognizedCall

                if callKind != UnrecognizedCall:
                    payload = jsonFromValue(mainCallHandler(callKind, value), pretty=false)
                    if payload.len == 0:
                        payload = "null"
            except CatchableError:
                status = 1
                payload = $newJString(getCurrentExceptionMsg())

            discard webview_return(mainWebview, replyId.cstring, status.cint, payload.cstring)

        mainWebview = result
        mainCallHandler = callHandler
        discard result.webview_bind("callback", handler, cast[pointer](0))

        if content.isUrl():
            discard webview_navigate(result, content.cstring)
        else:
            let html = prepareWebviewHtml(content)
            discard webview_set_html(result, html.cstring)

        if maximized:
            result.getWindow().maximize()

        if fullscreen:
            result.getWindow().fullscreen()

        if borderless:
            result.getWindow().makeBorderless()
            result.getWindow().show()

        if topmost or borderless:
            result.getWindow().topmost()

    proc show*(w: Webview) =
        # A webview is just a window + a page. No dummy File/Share bar —
        # that leftover test menu was Windows-only and every Share item
        # collapsed onto the last callback.
        discard webview_run(w)
        discard webview_destroy(w)

    proc evaluate*(w: Webview, js: string) =
        discard webview_eval(w, js.cstring)

    proc getWindow*(w: Webview): Window =
        webview_get_window(w)
