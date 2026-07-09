#=======================================================
# Arturo
# Programming Language + Bytecode VM compiler
# (c) 2019-2026 Yanis Zafirópulos
#
# @file: library/Files.nim
#=======================================================

## The main Files module 
## (part of the standard library)

#=======================================
# Pragmas
#=======================================

{.used.}

#=======================================
# Libraries
#=======================================

when not defined(WEB):

    import os, sequtils, sugar, times, unicode

    import extras/miniz
 
    when defined(PARSERS):
        import helpers/html
        import helpers/markdown
        import helpers/toml
        import helpers/xml

    import helpers/csv
    import helpers/datasource
    import helpers/io
    import helpers/iteratorstate
    import helpers/jsonobject
    import helpers/parallelism
    import helpers/url

    import vm/lib
    import vm/[bytecode, errors, parse]

when defined(BUNDLE):
    import vm/bundle/resources

#=======================================
# Definitions
#=======================================

# TODO(Files) more potential built-in function candidates?
#  labels: library, enhancement, open discussion

# TODO(Files) add function to enable writing/reading to/from binary files
#  this should obviously support writing a 16-bit int, and all this
#  labels: library, enhancement, new feature, open discussion

when not defined(WEB):

    proc writeBufferedTextSource(path: string, source: Value, chunkSize: int, append = false, seekPos: int64 = -1) =
        if chunkSize < 1:
            Error_OperationNotPermitted("`write.buffer:` expects a positive size")
        if seekPos < -1:
            Error_OperationNotPermitted("`.seek:` expects a non-negative offset")
        if append and seekPos >= 0:
            Error_OperationNotPermitted("`.append` cannot combine with `.seek:`")

        var collected = newStringOfCap(chunkSize * 2)

        proc addText(s: string) =
            collected.add(s)

        proc feed(v: Value) =
            case v.kind:
                of String: addText(v.s)
                of Char: addText(toUTF8(v.c))
                of Binary:
                    var s = newString(v.n.len)
                    if v.n.len > 0:
                        copyMem(addr s[0], unsafeAddr v.n[0], v.n.len)
                    addText(s)
                of Block:
                    for item in v.a:
                        feed(item)
                of Object:
                    if isIteratorObject(v):
                        var item: Value
                        while nextIteratorValue(v, item):
                            feed(item)
                    else:
                        addText($(v))
                else:
                    addText($(v))

        feed(source)

        if seekPos >= 0:
            var existing = if fileExists(path): readFile(path) else: ""
            let pos = int(seekPos)
            if existing.len < pos:
                existing &= repeat('\0', pos - existing.len)
            let suffixStart = pos + collected.len
            let prefix = existing[0 ..< pos]
            let suffix =
                if suffixStart < existing.len:
                    existing[suffixStart .. ^1]
                else:
                    ""
            writeToFile(path, prefix & collected & suffix)
        else:
            writeToFile(path, collected, append = append)

    proc writeBufferedBinarySource(path: string, source: Value, chunkSize: int, append = false, seekPos: int64 = -1) =
        if chunkSize < 1:
            Error_OperationNotPermitted("`write.buffer:` expects a positive size")
        if seekPos < -1:
            Error_OperationNotPermitted("`.seek:` expects a non-negative offset")
        if append and seekPos >= 0:
            Error_OperationNotPermitted("`.append` cannot combine with `.seek:`")

        var collected = newSeqOfCap[byte](chunkSize * 2)

        proc addBytes(bs: openArray[byte]) =
            for b in bs:
                collected.add(b)

        proc addStringBytes(s: string) =
            if s.len == 0:
                return
            var bs = newSeq[byte](s.len)
            copyMem(addr bs[0], unsafeAddr s[0], s.len)
            addBytes(bs)

        proc feed(v: Value) =
            case v.kind:
                of Binary: addBytes(v.n)
                of String: addStringBytes(v.s)
                of Char: addStringBytes(toUTF8(v.c))
                of Block:
                    for item in v.a:
                        feed(item)
                of Object:
                    if isIteratorObject(v):
                        var item: Value
                        while nextIteratorValue(v, item):
                            feed(item)
                    else:
                        Error_OperationNotPermitted("`write.binary.buffer` expects binary/string chunks or an iterator of such chunks")
                else:
                    Error_OperationNotPermitted("`write.binary.buffer` expects binary/string chunks or an iterator of such chunks")

        feed(source)

        if seekPos >= 0:
            var existing: seq[byte]
            if fileExists(path):
                var f: File
                if open(f, path, fmRead):
                    existing = newSeq[byte](f.getFileSize())
                    if existing.len > 0:
                        discard f.readBytes(existing, 0, existing.len)
                    f.close()
            let pos = int(seekPos)
            if existing.len < pos:
                existing.setLen(pos)
            let needed = pos + collected.len
            if existing.len < needed:
                existing.setLen(needed)
            for i, b in collected:
                existing[pos + i] = b
            writeToFile(path, existing)
        else:
            writeToFile(path, collected, append = append)
 
proc defineModule*(moduleName: string) =

    #----------------------------
    # Functions
    #----------------------------

    when not defined(WEB):

        builtin "copy",
            alias       = unaliased, 
            op          = opNop,
            rule        = PrefixPrecedence,
            description = "copy file at path to given destination",
            args        = {
                "file"          : {String},
                "destination"   : {String}
            },
            attrs       = {
                "directory" : ({Logical},"path is a directory")
            },
            returns     = {Nothing},
            example     = """
            copy "testscript.art" normalize.tilde "~/Desktop/testscript.art"
            ; copied file
            ..........
            copy "testfolder" normalize.tilde "~/Desktop/testfolder"
            ; copied whole folder
            """:
                #=======================================================
                var target = y.s
                if (hadAttr("directory")): 
                    try:
                        copyDirWithPermissions(x.s, move target)
                    except OSError:
                        discard
                else: 
                    try:
                        copyFileWithPermissions(x.s, move target)
                    except OSError:
                        discard

        builtin "delete",
            alias       = unaliased, 
            op          = opNop,
            rule        = PrefixPrecedence,
            description = "delete file at given path",
            args        = {
                "file"  : {String}
            },
            attrs       = {
                "directory" : ({Logical},"path is a directory")
            },
            returns     = {Nothing},
            example     = """
            delete "testscript.art"
            ; file deleted
            """:
                #=======================================================
                if (hadAttr("directory")): 
                    try:
                        removeDir(x.s)
                    except OSError:
                        discard
                else: 
                    discard tryRemoveFile(x.s)

        builtin "move",
            alias       = unaliased, 
            op          = opNop,
            rule        = PrefixPrecedence,
            description = "move file at path to given destination",
            args        = {
                "file"          : {String},
                "destination"   : {String}
            },
            attrs       = {
                "directory" : ({Logical},"path is a directory")
            },
            returns     = {Nothing},
            example     = """
            move "testscript.art" normalize.tilde "~/Desktop/testscript.art"
            ; moved file
            ..........
            move "testfolder" normalize.tilde "~/Desktop/testfolder"
            ; moved whole folder
            """:
                #=======================================================
                var target = y.s
                if (hadAttr("directory")): 
                    try:
                        moveDir(x.s, move target)
                    except OSError:
                        discard
                else: 
                    try:
                        moveFile(x.s, move target)
                    except OSError:
                        discard

        builtin "permissions",
            alias       = unaliased, 
            op          = opNop,
            rule        = PrefixPrecedence,
            description = "check permissions of given file",
            args        = {
                "file"  : {String}
            },
            attrs       = {
                "set"   : ({Dictionary},"set using given file permissions")
            },
            returns     = {Dictionary,Null},
            example     = """
            inspect permissions "bin/arturo"
            ; [ :dictionary
            ;     user    :	[ :dictionary
            ;         read     :		true :boolean
            ;         write    :		true :boolean
            ;         execute  :		true :boolean
            ;     ]
            ;     group   :	[ :dictionary
            ;         read     :		true :boolean
            ;         write    :		false :boolean
            ;         execute  :		true :boolean
            ;     ]
            ;     others  :	[ :dictionary
            ;         read     :		true :boolean
            ;         write    :		false :boolean
            ;         execute  :		true :boolean
            ;     ]
            ; ]
            ..........
            permissions.set:#[others:#[write:true]] "bin/arturo"
            ; gave write permission to 'others'
            """:
                #=======================================================
                try:
                    if (checkAttr("set")):
                        var source = x.s
                        var perms: set[FilePermission]

                        if aSet.d.hasKey("user") and aSet.d["user"].d.hasKey("read"): perms.incl(fpUserRead)
                        if aSet.d.hasKey("user") and aSet.d["user"].d.hasKey("write"): perms.incl(fpUserWrite)
                        if aSet.d.hasKey("user") and aSet.d["user"].d.hasKey("execute"): perms.incl(fpUserExec)

                        if aSet.d.hasKey("group") and aSet.d["group"].d.hasKey("read"): perms.incl(fpGroupRead)
                        if aSet.d.hasKey("group") and aSet.d["group"].d.hasKey("write"): perms.incl(fpGroupWrite)
                        if aSet.d.hasKey("group") and aSet.d["group"].d.hasKey("execute"): perms.incl(fpGroupExec)

                        if aSet.d.hasKey("others") and aSet.d["others"].d.hasKey("read"): perms.incl(fpOthersRead)
                        if aSet.d.hasKey("others") and aSet.d["others"].d.hasKey("write"): perms.incl(fpOthersWrite)
                        if aSet.d.hasKey("others") and aSet.d["others"].d.hasKey("execute"): perms.incl(fpOthersExec)

                        setFilePermissions(move source, move perms)
                    else:
                        let perms = getFilePermissions(x.s)
                        var permsDict: ValueDict = {
                            "user": newDictionary({
                                "read"      : newLogical(fpUserRead in perms),
                                "write"     : newLogical(fpUserWrite in perms),
                                "execute"   : newLogical(fpUserExec in perms)
                            }.toOrderedTable),
                            "group": newDictionary({
                                "read"      : newLogical(fpGroupRead in perms),
                                "write"     : newLogical(fpGroupWrite in perms),
                                "execute"   : newLogical(fpGroupExec in perms)
                            }.toOrderedTable),
                            "others": newDictionary({
                                "read"      : newLogical(fpOthersRead in perms),
                                "write"     : newLogical(fpOthersWrite in perms),
                                "execute"   : newLogical(fpOthersExec in perms)
                            }.toOrderedTable)
                        }.toOrderedTable

                        push(newDictionary(permsDict))

                except OSError:
                    push(VNULL)

        # TODO(Files\read) add support for different delimiters when in `.csv` mode
        #  this could be something as simple as `.with:` or `.delimiter:`, or `.delimited:`
        #  also see: https://github.com/arturo-lang/arturo/pull/1008#issuecomment-1450571702
        #  labels:library,enhancement

        builtin "read",
            alias       = doublearrowleft, 
            op          = opNop,
            rule        = PrefixPrecedence,
            description = "read file from given path",
            args        = {
                "file"  : {String}
            },
            attrs       =
                when defined(PARSERS):
                    {
                        "lines"         : ({Logical},"read file lines into block"),
                        "stream"        : ({Logical},"when combined with `.lines` or `.csv`, lazily stream records as an iterator"),
                        "iterator"      : ({Logical},"legacy alias for `.stream` when combined with `.lines` or `.csv`"),
                        "buffer"        : ({Integer},"read file in fixed-size chunks as an iterator; argument is chunk size"),
                        "seek"          : ({Integer},"start reading from the given byte offset (for `.buffer`)"),
                        "json"          : ({Logical},"read Json into value"),
                        "csv"           : ({Logical},"read CSV file into a block of rows"),
                        "delimiter"     : ({Char},   "read CSV file with a specific delimiter"),
                        "withHeaders"   : ({Logical},"read CSV headers"),
                        "html"          : ({Logical},"read HTML into node dictionary"),
                        "xml"           : ({Logical},"read XML into node dictionary"),
                        "markdown"      : ({Logical},"read Markdown and convert to HTML"),
                        "toml"          : ({Logical},"read TOML into value"),
                        "bytecode"      : ({Logical},"read file as Arturo bytecode"),
                        "binary"        : ({Logical},"read as binary"),
                        "file"          : ({Logical},"read as file (throws an error if not valid)"),
                        "async"         : ({Logical},"read asynchronously and return a `:task`")
                    }
                else:
                    {
                        "lines"         : ({Logical},"read file lines into block"),
                        "stream"        : ({Logical},"when combined with `.lines` or `.csv`, lazily stream records as an iterator"),
                        "iterator"      : ({Logical},"legacy alias for `.stream` when combined with `.lines` or `.csv`"),
                        "buffer"        : ({Integer},"read file in fixed-size chunks as an iterator; argument is chunk size"),
                        "seek"          : ({Integer},"start reading from the given byte offset (for `.buffer`)"),
                        "json"          : ({Logical},"read Json into value"),
                        "csv"           : ({Logical},"read CSV file into a block of rows"),
                        "delimiter"     : ({Char},   "read CSV file with a specific delimiter"),
                        "withHeaders"   : ({Logical},"read CSV headers"),
                        "bytecode"      : ({Logical},"read file as Arturo bytecode"),
                        "binary"        : ({Logical},"read as binary"),
                        "file"          : ({Logical},"read as file (throws an error if not valid)"),
                        "async"         : ({Logical},"read asynchronously and return a `:task`")
                    },
            returns     = {String,Block,Binary,Task,Object},
            example     = """
            ; reading a simple local file
            str: read "somefile.txt"
            ..........
            ; also works with remote urls
            page: read "http://www.somewebsite.com/page.html"
            ..........
            ; we can also "read" JSON data as an object
            data: read.json "mydata.json"
            ..........
            ; lazily stream lines from a local file
            lines: read.lines.stream "somefile.txt"
            head: take lines 10
            ..........
            ; lazily stream csv rows
            rows: read.csv.stream "table.csv"
            first rows
            ..........
            ; read fixed-size text buffers lazily
            chunks: read.buffer:4 "somefile.txt"
            first chunks
            ..........
            ; begin reading from a specific byte offset
            later: read.buffer:4.seek:8 "somefile.txt"
            first later
            ..........
            ; read fixed-size binary buffers lazily
            bytes: read.binary.buffer:1024 "image.bin"
            first bytes
            ..........
            ; or even convert Markdown to HTML on-the-fly
            html: read.markdown "## Hello"     ; "<h2>Hello</h2>"
            """:
                #=======================================================
                let explicitAsync = hadAttr("async")
                let wantsStream = (getAttr("stream") != VNULL) or (getAttr("iterator") != VNULL)
                let wantsBuffer = (getAttr("buffer") != VNULL)

                if wantsBuffer:
                    let bufferVal = popAttr("buffer")
                    let seekVal = popAttr("seek")
                    discard popAttr("stream")
                    discard popAttr("iterator")
                    if explicitAsync:
                        Error_OperationNotPermitted("`.buffer` cannot combine with `.async`")
                    if x.s.isUrl():
                        Error_OperationNotPermitted("`.buffer` currently supports local files only")
                    if bufferVal.kind != Integer or bufferVal.i < 1:
                        Error_OperationNotPermitted("`.buffer:` expects a positive integer")
                    if (not seekVal.isNil) and (seekVal.kind != Integer or seekVal.i < 0):
                        Error_OperationNotPermitted("`.seek:` expects a non-negative integer")
                    if hadAttr("lines") or hadAttr("csv") or hadAttr("json") or hadAttr("bytecode") or hadAttr("file"):
                        Error_OperationNotPermitted("`.buffer` is a raw chunk reader and cannot combine with `.lines` / `.csv` / `.json` / `.bytecode` / `.file`")
                    when defined(PARSERS):
                        if hadAttr("html") or hadAttr("xml") or hadAttr("markdown") or hadAttr("toml"):
                            Error_OperationNotPermitted("`.buffer` cannot combine with parser/structured read modes")
                    push(newBufferStreamIterator(x.s, bufferVal.i, asBinary=hadAttr("binary"), startOffset = (if seekVal.isNil: 0'i64 else: int64(seekVal.i))))
                    return

                if wantsStream:
                    discard popAttr("stream")
                    discard popAttr("iterator")
                    if getAttr("seek") != VNULL:
                        Error_OperationNotPermitted("`.seek:` currently works with `.buffer` reads only")
                    if explicitAsync:
                        Error_OperationNotPermitted("`.stream` cannot combine with `.async`")
                    if x.s.isUrl():
                        Error_OperationNotPermitted("`.stream` currently supports local files only")

                    if hadAttr("lines"):
                        push(newLineStreamIterator(x.s))
                    elif hadAttr("csv"):
                        let delim = if checkAttr("delimiter"): aDelimiter.c.char() else: ','
                        push(newCsvStreamIterator(x.s, withHeaders=hadAttr("withHeaders"), delimiter=delim))
                    else:
                        Error_OperationNotPermitted("`.stream` currently requires `.lines` or `.csv`")
                    return

                if explicitAsync and hadAttr("bytecode"):
                    var attrSuffix = ""
                    if hadAttr("lines"):       attrSuffix &= ".lines"
                    if hadAttr("json"):        attrSuffix &= ".json"
                    if hadAttr("csv"):         attrSuffix &= ".csv"
                    if hadAttr("withHeaders"): attrSuffix &= ".withHeaders"
                    if hadAttr("bytecode"):    attrSuffix &= ".bytecode"
                    if hadAttr("binary"):      attrSuffix &= ".binary"
                    if hadAttr("file"):        attrSuffix &= ".file"
                    when defined(PARSERS):
                        if hadAttr("html"):     attrSuffix &= ".html"
                        if hadAttr("xml"):      attrSuffix &= ".xml"
                        if hadAttr("markdown"): attrSuffix &= ".markdown"
                        if hadAttr("toml"):     attrSuffix &= ".toml"
                    if checkAttr("delimiter"): attrSuffix &= ".delimiter:" & codify(aDelimiter)
                    push spawnAsTask("read" & attrSuffix & " " & codify(x))
                    return

                if (explicitAsync or not onMainFiber()) and not hadAttr("bytecode"):
                    let asLines       = hadAttr("lines")
                    let asJson        = hadAttr("json")
                    let asCsv         = hadAttr("csv")
                    let asWithHeaders = hadAttr("withHeaders")
                    let asBinary      = hadAttr("binary")
                    let hasDelim      = checkAttr("delimiter")
                    let delim         = if hasDelim: aDelimiter.c.char() else: ','
                    when defined(PARSERS):
                        let asHtml     = hadAttr("html")
                        let asXml      = hadAttr("xml")
                        let asMarkdown = hadAttr("markdown")
                        let asToml     = hadAttr("toml")
                    let post = proc(src: string): Value =
                        if asBinary:
                            var bs: seq[byte] = newSeq[byte](src.len)
                            if src.len > 0: copyMem(addr bs[0], unsafeAddr src[0], src.len)
                            return newBinary(bs)
                        if asLines: return newStringBlock(src.splitLines())
                        if asJson: return valueFromJson(src)
                        if asCsv:
                            if hasDelim:
                                return parseCsvInput(src, withHeaders=asWithHeaders, withDelimiter=delim)
                            else:
                                return parseCsvInput(src, asWithHeaders)
                        when defined(PARSERS):
                            if asToml: return parseTomlString(src)
                            if asMarkdown: return parseMarkdownInput(src)
                            if asHtml: return parseHtmlInput(src)
                            if asXml: return parseXMLInput(src)
                        return newString(src)
                    let asyncTask =
                        if x.s.isUrl(): spawnAsyncReadUrl(x.s, post)
                        else:           spawnAsyncRead(x.s, post)
                    if explicitAsync:
                        push asyncTask
                    else:
                        push coopWait(asyncTask.tsk.future)
                    return

                if (hadAttr("binary")):
                    var f: File
                    discard f.open(x.s)
                    var b: seq[byte] = newSeq[byte](f.getFileSize())
                    discard f.readBytes(b, 0, f.getFileSize())

                    f.close()

                    push(newBinary(b))
                else:
                    when defined(BUNDLE):
                        let (src, tp) = (getBundledResource(x.s)[0], FileData)
                    else:
                        let (src, tp) = getSource(x.s)

                    if (hadAttr("file") and tp != FileData):
                        Error_FileNotFound(src)

                    if (hadAttr("lines")):
                        push(newStringBlock(src.splitLines()))
                    elif (hadAttr("json")):
                        push(valueFromJson(src))
                    elif (hadAttr("csv")):
                        if checkAttr("delimiter"):
                            let delimiter = aDelimiter.c.char()
                            push(parseCsvInput(src, withHeaders=hadAttr("withHeaders"), withDelimiter=delimiter))
                        else:
                            push(parseCsvInput(src, (hadAttr("withHeaders"))))
                    elif (hadAttr("bytecode")):
                        let bcode = readBytecode(x.s)
                        let parsed = doParse(bcode[0], isFile=false).a[0]
                        push(newBytecode(Translation(constants: parsed.a, instructions: bcode[1])))
                    else:
                        when defined(PARSERS):
                            if (hadAttr("toml")):
                                push(parseTomlString(src))
                            elif (hadAttr("markdown")):
                                push(parseMarkdownInput(src))
                            elif (hadAttr("html")):
                                push(parseHtmlInput(src))
                            elif (hadAttr("xml")):
                                push(parseXMLInput(src))
                            else:
                                push(newString(src))
                        else:
                            push(newString(src))
                            
                    # elif attrs.hasKey("xml"):
                    #     push(parseXmlNode(parseXml(action(x.s))))

        builtin "rename",
            alias       = unaliased, 
            op          = opNop,
            rule        = PrefixPrecedence,
            description = "rename file at path using given new path name",
            args        = {
                "file"  : {String},
                "name"  : {String}
            },
            attrs       = {
                "directory" : ({Logical},"path is a directory")
            },
            returns     = {Nothing},
            example     = """
            rename "README.md" "READIT.md"
            ; file renamed
            """:
                #=======================================================
                var source = x.s
                var target = y.s
                if (hadAttr("directory")): 
                    try:
                        moveDir(move source, move target)
                    except OSError:
                        discard
                else: 
                    try:
                        moveFile(move source, move target)
                    except OSError:
                        discard

        builtin "symlink",
            alias       = unaliased,
            op          = opNop, 
            rule        = PrefixPrecedence,
            description = "create symbolic link of file to given destination",
            args        = {
                "file"          : {String},
                "destination"   : {String}
            },
            attrs       = {
                "hard"  : ({Logical},"create a hard link")
            },
            returns     = {Nothing},
            example     = """
            symlink relative "arturo/README.md" 
                    "/Users/drkameleon/Desktop/gotoREADME.md"
            ; creates a symbolic link to our readme file
            ; in our desktop
            ..........
            symlink.hard relative "arturo/README.md" 
                    "/Users/drkameleon/Desktop/gotoREADME.md"
            ; hard-links (effectively copies) our readme file
            ; to our desktop
            """:
                #=======================================================
                var source = x.s
                var target = y.s
                try:
                    if (hadAttr("hard")):
                        createHardlink(move source, move target)
                    else:
                        createSymlink(move source, move target)
                except OSError:
                    discard
        
        builtin "timestamp",
            alias       = unaliased, 
            op          = opNop,
            rule        = PrefixPrecedence,
            description = "get file timestamps",
            args        = {
                "file"  : {String}
            },
            attrs       = NoAttrs,
            returns     = {Dictionary,Null},
            example     = """
            timestamp "README.md"
            ; =>  [created:2022-09-21T12:35:04+02:00 accessed:2022-09-21T12:35:04+02:00 modified:2022-09-21T12:35:04+02:00]

            timestamp "some-file-that-does-not-exist.txt"
            ; => null
            """:
                #=======================================================
                try:
                    push newDictionary({
                        "created": newDate(local(getCreationTime(x.s))),
                        "accessed": newDate(local(getLastAccessTime(x.s))),
                        "modified": newDate(local(getLastModificationTime(x.s)))
                    }.toOrderedTable)
                except CatchableError:
                    push VNULL
                        
        builtin "unzip",
            alias       = unaliased, 
            op          = opNop,
            rule        = PrefixPrecedence,
            description = "unzip given archive to destination",
            args        = {
                "destination"   : {String},
                "original"      : {String}
            },
            attrs       = NoAttrs,
            returns     = {Nothing},
            example     = """
            unzip "folder" "archive.zip"
            """:
                #=======================================================
                miniz.unzip(y.s, x.s)

        builtin "volume",
            alias       = unaliased, 
            op          = opNop,
            rule        = PrefixPrecedence,
            description = "get file size for given path",
            args        = {
                "file"      : {String}
            },
            attrs       = NoAttrs,
            returns     = {Quantity},
            example     = """
            volume "README.md"
            ; => 13704B 
            ; (size in bytes)
            """:
                #=======================================================
                push newQuantity(toQuantity(int(getFileSize(x.s)), parseAtoms("B")))

        builtin "write",
            alias       = doublearrowright, 
            op          = opNop,
            rule        = InfixPrecedence,
            description = "write content to file at given path",
            args        = {
                "content"   : {Any},
                "file"      : {String,Null}
            },
            attrs       = {
                "append"        : ({Logical},"append to given file"),
                "directory"     : ({Logical},"create directory at path"),
                "json"          : ({Logical},"write value as Json"),
                "compact"       : ({Logical},"produce compact, non-prettified Json code"),
                "binary"        : ({Logical},"write as binary"),
                "buffer"        : ({Integer},"write content in fixed-size chunks; argument is chunk size"),
                "seek"          : ({Integer},"start writing at the given byte offset"),
                "async"         : ({Logical},"write in a child process and return a `:task`")
            },
            returns     = {Nothing,Task},
            example     = """
            ; write some string data to given file path
            write "Hello world!" "somefile.txt"
            ..........
            ; we can also write any type of data as JSON
            write.json myData "data.json"
            ..........
            ; append to an existing file
            write.append "Yes, Hello again!" "somefile.txt"
            ..........
            ; stream text chunks to disk
            chunks: read.buffer:4 "source.txt"
            write.buffer:4 chunks "copy.txt"
            ..........
            ; overwrite from a specific byte offset
            write.buffer:2.seek:4 ["XY" "ZZ"] "copy.txt"
            ..........
            ; stream binary chunks to disk
            bytes: read.binary.buffer:1024 "image.bin"
            write.binary.buffer:1024 bytes "copy.bin"
            """:
                #=======================================================
                let explicitAsync = hadAttr("async")

                let bufferMode = getAttr("buffer")
                if bufferMode != VNULL:
                    if explicitAsync:
                        Error_OperationNotPermitted("`.buffer` cannot combine with `.async`")
                    if hadAttr("directory"):
                        Error_OperationNotPermitted("`.buffer` cannot combine with `.directory`")
                    if hadAttr("json"):
                        Error_OperationNotPermitted("`.buffer` cannot combine with `.json`")
                    if xKind == Bytecode or y.kind == Null:
                        Error_OperationNotPermitted("`.buffer` does not support bytecode or null destinations")
                    let bufferVal = popAttr("buffer")
                    let seekVal = popAttr("seek")
                    if bufferVal.kind != Integer or bufferVal.i < 1:
                        Error_OperationNotPermitted("`.buffer:` expects a positive integer")
                    if (not seekVal.isNil) and (seekVal.kind != Integer or seekVal.i < 0):
                        Error_OperationNotPermitted("`.seek:` expects a non-negative integer")
                    let seekPos = if seekVal.isNil: -1'i64 else: int64(seekVal.i)

                    if hadAttr("binary"):
                        writeBufferedBinarySource(y.s, x, bufferVal.i, append = hadAttr("append"), seekPos = seekPos)
                    else:
                        writeBufferedTextSource(y.s, x, bufferVal.i, append = hadAttr("append"), seekPos = seekPos)
                    return

                if explicitAsync and (xKind == Bytecode or hadAttr("directory") or y.kind == Null):
                    var attrSuffix = ""
                    if hadAttr("append"):    attrSuffix &= ".append"
                    if hadAttr("directory"): attrSuffix &= ".directory"
                    if hadAttr("json"):      attrSuffix &= ".json"
                    if hadAttr("compact"):   attrSuffix &= ".compact"
                    if hadAttr("binary"):    attrSuffix &= ".binary"
                    let pathSrc = if y.kind == Null: "null" else: codify(y)
                    push spawnAsTask("write" & attrSuffix & " " & codify(x) & " " & pathSrc)
                    return

                if (explicitAsync or not onMainFiber()) and
                   xKind != Bytecode and not hadAttr("directory") and y.kind != Null:
                    let path = y.s
                    let append = hadAttr("append")
                    let payload =
                        if hadAttr("binary"):
                            var s = newString(x.n.len)
                            if x.n.len > 0: copyMem(addr s[0], unsafeAddr x.n[0], x.n.len)
                            s
                        elif hadAttr("json"):
                            jsonFromValue(x, pretty=(not hadAttr("compact")))
                        else:
                            x.s
                    let asyncTask = spawnAsyncWrite(path, payload, append)
                    if explicitAsync:
                        push asyncTask
                    else:
                        push coopWait(asyncTask.tsk.future)
                    return

                if xKind==Bytecode:
                    let dataS = codify(newBlock(y.trans.constants), unwrapped=true, safeStrings=true)
                    let codeS = x.trans.instructions
                    discard writeBytecode(dataS, codeS, y.s)
                else:
                    if (hadAttr("directory")):
                        createDir(y.s)
                    else:
                        if (hadAttr("binary")):
                            writeToFile(y.s, x.n, append = (hadAttr("append")))
                        else:
                            if (hadAttr("json")):
                                let rez = jsonFromValue(x, pretty=(not hadAttr("compact")))
                                if y.kind==String:
                                    writeToFile(y.s, rez, append = (hadAttr("append")))
                                else:
                                    push(newString(rez))
                            else:
                                writeToFile(y.s, x.s, append = (hadAttr("append")))

        builtin "zip",
            alias       = unaliased, 
            op          = opNop,
            rule        = PrefixPrecedence,
            description = "zip given files to file at destination",
            args        = {
                "destination"   : {String},
                "files"         : {Block}
            },
            attrs       = NoAttrs,
            returns     = {Nothing},
            example     = """
            zip "dest.zip" ["file1.txt" "img.png"]
            """:
                #=======================================================
                let files: seq[string] = y.a.map((z)=>z.s)
                miniz.zip(files, x.s)

    #----------------------------
    # Predicates
    #----------------------------

        builtin "directory?",
            alias       = unaliased, 
            op          = opNop,
            rule        = PrefixPrecedence,
            description = "check if given path exists and corresponds to a directory",
            args        = {
                "path"  : {String}
            },
            attrs       = NoAttrs,
            returns     = {Logical},
            example     = """
            if directory? "src" [ 
                print "directory exists!" 
            ]
            """:
                #=======================================================
                push newLogical(dirExists(x.s))

        builtin "exists?",
            alias       = unaliased, 
            op          = opNop,
            rule        = PrefixPrecedence,
            description = "check if file/directory at given path exists",
            args        = {
                "path"  : {String}
            },
            attrs       = NoAttrs,
            returns     = {Logical},
            example     = """
            if exists? "somefile.txt" [ 
                print "path exists!" 
            ]
            """:
                #=======================================================
                push newLogical(fileExists(x.s) or dirExists(x.s) or symlinkExists(x.s))

        builtin "file?",
            alias       = unaliased, 
            op          = opNop,
            rule        = PrefixPrecedence,
            description = "check if given path exists and corresponds to a file",
            args        = {
                "path"  : {String}
            },
            attrs       = NoAttrs,
            returns     = {Logical},
            example     = """
            if file? "somefile.txt" [ 
                print "file exists!" 
            ]
            """:
                #=======================================================
                push newLogical(fileExists(x.s))

        builtin "hidden?",
            alias       = unaliased, 
            op          = opNop,
            rule        = PrefixPrecedence,
            description = "check if file/folder at given path is hidden",
            args        = {
                "file"      : {String}
            },
            attrs       = NoAttrs,
            returns     = {Logical},
            example     = """
            hidden? "README.md"     ; => false
            hidden? ".git"          ; => true
            """:
                #=======================================================
                push newLogical(isHidden(x.s))

        builtin "symlink?",
            alias       = unaliased, 
            op          = opNop,
            rule        = PrefixPrecedence,
            description = "check if given path exists and corresponds to a symlink",
            args        = {
                "path"  : {String}
            },
            attrs       = NoAttrs,
            returns     = {Logical},
            example     = """
            if symlink? "somefile" [ 
                print "symlink exists!" 
            ]
            """:
                #=======================================================
                push newLogical(symlinkExists(x.s))
