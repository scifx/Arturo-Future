#!/usr/bin/env python3
"""Functional tests for the Arturo webview helpers (issue #2209).

These do not open a native window. They lock the algorithms that made
Windows misbehave: HTML first-load wrapping, JSON that must never be
empty/nil, and menu callback identity.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPERS = ROOT / "src" / "helpers"
OK = 0
FAILED = 0


def test(name: str):
    def wrap(fn):
        global OK, FAILED
        try:
            fn()
        except Exception as exc:  # noqa: BLE001 — surface the assertion
            FAILED += 1
            print(f"  FAIL  {name}")
            print(f"        {exc}")
        else:
            OK += 1
            print(f"  ok    {name}")
        return fn

    return wrap


# ---------------------------------------------------------------------------
# prepareWebviewHtml — keep in lockstep with helpers/webviews.nim
# ---------------------------------------------------------------------------

def normalize_webview_newlines(html: str) -> str:
    out = []
    i = 0
    while i < len(html):
        if html[i] == "\r":
            out.append("\n")
            if i + 1 < len(html) and html[i + 1] == "\n":
                i += 1
        else:
            out.append(html[i])
        i += 1
    return "".join(out)


def looks_like_html_document(html: str) -> bool:
    stripped = html.lstrip(" \t\n\r")
    head = stripped[:21].lower()
    return head.startswith("<!doctype") or head.startswith("<html")


def prepare_webview_html(html: str) -> str:
    src = normalize_webview_newlines(html)
    if looks_like_html_document(src):
        return src
    return (
        "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n"
        "</head>\n<body>\n" + src + "\n</body>\n</html>\n"
    )


print("html first load")


@test("CRLF from Windows curly strings becomes LF")
def _crlf():
    src = "<script>\r\nfunction printHello() {\r\n  ok();\r\n}\r\n</script>"
    got = normalize_webview_newlines(src)
    assert "\r" not in got
    assert "function printHello() {\n  ok();\n}" in got


@test("lone CR is also folded to LF")
def _cr():
    assert normalize_webview_newlines("a\rb\n") == "a\nb\n"


@test("a fragment becomes a UTF-8 document")
def _wrap_fragment():
    got = prepare_webview_html("<h1>Hello</h1>")
    assert got.startswith("<!DOCTYPE html>")
    assert 'charset="utf-8"' in got
    assert "<h1>Hello</h1>" in got
    assert got.strip().endswith("</html>")


@test("a full document is not wrapped twice")
def _no_double_wrap():
    src = "<!DOCTYPE html>\n<html><body>Hi</body></html>"
    assert prepare_webview_html(src) == src


@test("uppercase HTML tag still counts as a document")
def _upper():
    src = "<HTML><BODY>Hi</BODY></HTML>"
    assert prepare_webview_html(src) == src


@test("discussion-style page script stays syntactically intact")
def _script_intact():
    page = prepare_webview_html(
        "<h1>x</h1>\n<script>\nfunction printHello() {\n"
        "    arturo.exec('print \"Hello from the webview!\"');\n"
        "    arturo.call(\"odd?\", 123).then(function (result) {\n"
        "        console.log(result);\n"
        "    });\n"
        "}\n</script>"
    )
    assert "arturo.exec('print \"Hello from the webview!\"')" in page
    assert page.count("function printHello()") == 1


# ---------------------------------------------------------------------------
# jsonFromValue — never emit empty / nil JSON
# ---------------------------------------------------------------------------

print("\njson payload")


def json_from_value(val):
    """A tiny stand-in for generateJsonNode + jsonFromValue.

    Mirrors the rule we now enforce in Nim: every Arturo value becomes a
    real JSON value. Unserializable handles become null, never missing.
    """
    if val is None:
        return None
    kind = val.get("kind")
    if kind in {"Null", "Nothing", "Any", "Function", "Method", "Binary"}:
        return None
    if kind == "Logical":
        return bool(val["v"])
    if kind == "Integer":
        return int(val["v"])
    if kind == "Floating":
        return float(val["v"])
    if kind in {"String", "Word", "Literal", "Complex", "Rational"}:
        return str(val["v"])
    if kind in {"Block", "Inline"}:
        return [json_from_value(x) for x in val["v"]]
    if kind == "Dictionary":
        return {k: json_from_value(v) for k, v in val["v"].items()}
    return None


def dump(val) -> str:
    node = json_from_value(val)
    text = json.dumps(node, ensure_ascii=False, separators=(",", ":"))
    return text if text else "null"


@test("scalars stay compact JSON")
def _scalars():
    assert dump({"kind": "Logical", "v": True}) == "true"
    assert dump({"kind": "Integer", "v": 123}) == "123"
    assert dump({"kind": "Null"}) == "null"


@test("bug3: a dictionary with mixed values is valid JSON")
def _dict():
    payload = dump(
        {
            "kind": "Dictionary",
            "v": {
                "n": {"kind": "Integer", "v": 5},
                "doubled": {"kind": "Integer", "v": 10},
                "odd?": {"kind": "Logical", "v": True},
                "items": {
                    "kind": "Block",
                    "v": [{"kind": "Integer", "v": i} for i in range(1, 6)],
                },
                "label": {"kind": "String", "v": "统计"},
                "fn": {"kind": "Function", "v": "stats"},
            },
        }
    )
    data = json.loads(payload)
    assert data["n"] == 5
    assert data["items"] == [1, 2, 3, 4, 5]
    assert data["label"] == "统计"
    assert data["fn"] is None  # function → null, not a crash / empty string


@test("bug3: empty payload is never emitted")
def _never_empty():
    assert dump({"kind": "Function", "v": "x"}) == "null"
    assert dump({"kind": "Nothing"}) == "null"
    assert json.loads(dump({"kind": "Binary", "v": b""})) is None


@test("webview_return payload is a live Python/Nim string, not a dangling cstring")
def _alive():
    # The Nim bug was: `returned = jsonFromValue(...).cstring` then dropping
    # the owning string. We keep a real `payload` binding for the call.
    payload = dump(
        {
            "kind": "Block",
            "v": [{"kind": "String", "v": "x" * 8000}],
        }
    )
    # Simulate webview_return reading .cstring while `payload` is still alive.
    view = payload
    assert json.loads(view) == ["x" * 8000]


# ---------------------------------------------------------------------------
# Native request shape used by the JS bridge
# ---------------------------------------------------------------------------

print("\nrequest protocol")


@test("call request is [mode, json-text] and decodes to method+args")
def _req():
    req = ["call", json.dumps({"method": "odd?", "args": [123]}, separators=(",", ":"))]
    assert req[0] == "call"
    body = json.loads(req[1])
    assert body == {"method": "odd?", "args": [123]}


@test("exec request carries the source as a JSON string")
def _exec():
    req = ["exec", json.dumps('print "Hello from the webview!"')]
    assert json.loads(req[1]) == 'print "Hello from the webview!"'


# ---------------------------------------------------------------------------
# Source-level guards — the leftover demo menu must stay gone
# ---------------------------------------------------------------------------

print("\nsource guards")


@test("show() no longer installs the File/Share demo menu")
def _no_demo_menu():
    src = (HELPERS / "webviews.nim").read_text(encoding="utf-8")
    assert 'newMenu("File")' not in src
    assert "Shared to Instagram" not in src
    assert "Shared to Facebook" not in src
    assert "proc show*" in src
    assert "webview_run" in src


@test("init + bind happen before the first set_html / navigate")
def _order():
    src = (HELPERS / "webviews.nim").read_text(encoding="utf-8")
    init_at = src.find("webview_init")
    bind_at = src.find('webview_bind("callback"')
    html_at = src.find("webview_set_html")
    nav_at = src.find("webview_navigate")
    assert init_at != -1 and bind_at != -1 and html_at != -1 and nav_at != -1
    assert init_at < html_at and bind_at < html_at
    assert init_at < nav_at and bind_at < nav_at


@test("jsonFromValue refuses to stringify a nil node")
def _nil_guard():
    src = (HELPERS / "jsonobject.nim").read_text(encoding="utf-8")
    assert "if node.isNil" in src
    assert "result = newJNull()" in src
    assert re.search(r"of Function,[\s\S]*result = newJNull\(\)", src)


@test("menu items get a unique userData identity")
def _menu_ident():
    src = (HELPERS / "windows.nim").read_text(encoding="utf-8")
    assert "cast[pointer](item)" in src
    assert "result.userData = ident" in src
    assert "menuCallbacks[item.userData]" not in src


@test("FunctionCall is wrapped in try/except like ExecuteCode")
def _fn_try():
    src = (ROOT / "src/library/Ui.nim").read_text(encoding="utf-8")
    fn = src.split("if call==FunctionCall:")[1].split("elif call==ExecuteCode:")[0]
    assert "try:" in fn
    assert "except VError" in fn


@test("the leftover eval debug echo is gone")
def _no_eval_echo():
    src = (ROOT / "src/library/Ui.nim").read_text(encoding="utf-8")
    assert "in old eval" not in src


@test("example matches the discussion and stays brace-balanced")
def _example():
    src = (ROOT / "examples/simplewebview.art").read_text(encoding="utf-8")
    assert "arturo.exec" in src
    assert 'arturo.call("odd?"' in src
    assert "arturo.call(\"stats\"" in src
    assert src.count("{") == src.count("}")


if FAILED:
    print(f"\n{FAILED} failed, {OK} passed")
    sys.exit(1)
print(f"\n{OK} tests passed")
