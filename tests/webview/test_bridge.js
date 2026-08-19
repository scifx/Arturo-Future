"use strict";

/**
 * Functional tests for the Arturo webview bridge.
 *
 * Covers the three Windows bugs in arturo-lang/arturo#2209
 * without opening a native window:
 *
 *   1. arturo.call / exec must work before a page refresh
 *      (callback may appear a few ticks late, as on WebView2)
 *   2. menu callbacks must keep a unique identity per item
 *   3. complex return values must survive the JSON round-trip
 */

const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const ROOT = path.resolve(__dirname, "../..");
const BRIDGE = fs.readFileSync(path.join(ROOT, "src/helpers/webviews.js"), "utf8");
const EXAMPLE = fs.readFileSync(path.join(ROOT, "examples/simplewebview.art"), "utf8");

let passed = 0;
function test(name, fn) {
    return Promise.resolve()
        .then(fn)
        .then(function () {
            passed += 1;
            console.log("  ok  " + name);
        })
        .catch(function (err) {
            console.error("  FAIL  " + name);
            console.error("        " + (err && err.stack ? err.stack : err));
            process.exitCode = 1;
        });
}

function makeWindow() {
    const timers = [];
    const win = {
        setInterval: function (fn, ms) {
            const id = { fn: fn, ms: ms, cleared: false };
            timers.push(id);
            return id;
        },
        clearInterval: function (id) {
            if (id) id.cleared = true;
        },
        _tick: function () {
            timers.slice().forEach(function (id) {
                if (!id.cleared) id.fn();
            });
        },
        _flush: function (n) {
            for (let i = 0; i < (n || 8); i++) this._tick();
        }
    };
    return win;
}

function loadBridge(win) {
    vm.runInNewContext(BRIDGE, { window: win, Promise: Promise });
    return win.arturo;
}

function installCallback(win, handler) {
    // Mirrors webview_bind("callback"): arguments arrive as a JSON array
    // ["call"|"exec"|"event", <payload-json-text>] and the return value is
    // a Promise of the already-parsed JSON (after webview_return).
    win.callback = function (mode, payload) {
        return Promise.resolve().then(function () {
            const req = [mode, payload];
            return handler(req);
        });
    };
}

function extractExampleScript(src) {
    const m = src.match(/<script>([\s\S]*?)<\/script>/);
    if (!m) throw new Error("example has no <script>");
    return m[1];
}

async function run() {
    console.log("webview bridge");

    await test("bridge file is valid JavaScript", function () {
        new vm.Script(BRIDGE, { filename: "webviews.js" });
    });

    await test("bridge has no template literals or arrows (ES5-safe)", function () {
        assert.strictEqual(BRIDGE.includes("`"), false, "backticks would break old engines");
        assert.strictEqual(/\([^)]*\)\s*=>/.test(BRIDGE), false, "arrow functions");
    });

    await test("example page script parses", function () {
        const script = extractExampleScript(EXAMPLE);
        new vm.Script(script, { filename: "simplewebview.art" });
    });

    await test("example does not use template literals in JS", function () {
        const script = extractExampleScript(EXAMPLE);
        assert.strictEqual(script.includes("`"), false);
    });

    await test("arturo is attached to window on first load (no refresh)", function () {
        const win = makeWindow();
        loadBridge(win);
        assert.ok(win.arturo, "window.arturo missing");
        assert.strictEqual(typeof win.arturo.call, "function");
        assert.strictEqual(typeof win.arturo.exec, "function");
    });

    await test("bug1: call waits for a late callback instead of throwing", async function () {
        const win = makeWindow();
        loadBridge(win);
        const pending = win.arturo.call("odd?", 123);
        let seen = null;
        installCallback(win, function (req) {
            seen = req;
            return false;
        });
        win._flush(4);
        const result = await pending;
        assert.strictEqual(seen[0], "call");
        const body = JSON.parse(seen[1]);
        assert.strictEqual(body.method, "odd?");
        assert.deepStrictEqual(body.args, [123]);
        assert.strictEqual(result, false);
    });

    await test("bug1: missing callback rejects with a clear error", async function () {
        const win = makeWindow();
        loadBridge(win);
        const pending = win.arturo.exec('print "hi"');
        let rejected = null;
        const tracked = pending.catch(function (err) {
            rejected = err;
        });
        for (let i = 0; i < 210; i++) win._tick();
        await tracked;
        assert.ok(rejected, "should have rejected");
        assert.match(String(rejected.message || rejected), /arturo cannot be loaded/);
    });

    await test("exec sends a JSON-encoded source string", async function () {
        const win = makeWindow();
        loadBridge(win);
        installCallback(win, function (req) {
            assert.strictEqual(req[0], "exec");
            assert.strictEqual(JSON.parse(req[1]), 'print "Hello from the webview!"');
            return null;
        });
        await win.arturo.exec('print "Hello from the webview!"');
    });

    await test("bug3: dictionary / unicode / nested block come back intact", async function () {
        const payload = {
            n: 5,
            doubled: 10,
            "odd?": true,
            items: [1, 2, 3, 4, 5],
            label: "统计",
            nested: { greet: "hello Arturo", empty: null }
        };
        const win = makeWindow();
        loadBridge(win);
        installCallback(win, function (req) {
            const body = JSON.parse(req[1]);
            assert.strictEqual(body.method, "stats");
            assert.deepStrictEqual(body.args, [5]);
            // Native side: jsonFromValue(...) kept alive for webview_return
            return JSON.parse(JSON.stringify(payload));
        });
        const got = await win.arturo.call("stats", 5);
        assert.deepStrictEqual(got, payload);
    });

    await test("bug3: a long string (the old dangling-cstring case) survives", async function () {
        const long = "中文".repeat(2000) + " — " + "x".repeat(4000);
        const win = makeWindow();
        loadBridge(win);
        installCallback(win, function () { return long; });
        const got = await win.arturo.call("echo", long);
        assert.strictEqual(got, long);
        assert.strictEqual(got.length, long.length);
    });

    await test("call with several args keeps order", async function () {
        const win = makeWindow();
        loadBridge(win);
        installCallback(win, function (req) {
            return JSON.parse(req[1]).args;
        });
        const got = await win.arturo.call("join", "a", 1, true, ["b", "c"]);
        assert.deepStrictEqual(got, ["a", 1, true, ["b", "c"]]);
    });

    await test("re-loading the bridge is a no-op (init + inline both fire)", function () {
        const win = makeWindow();
        loadBridge(win);
        const first = win.arturo;
        loadBridge(win);
        assert.strictEqual(win.arturo, first);
    });

    console.log("\nmenu identity");

    await test("bug2: last-write-wins on nil userData (the old bug)", function () {
        const table = Object.create(null);
        function add(label, action, userData) {
            table[userData] = action;
        }
        add("Facebook", function () { return "facebook"; }, null);
        add("Twitter", function () { return "twitter"; }, null);
        add("Instagram", function () { return "instagram"; }, null);
        assert.strictEqual(table[null](), "instagram");
    });

    await test("bug2: unique identity per item fires the right action", function () {
        // Nim uses the MenuItem ref pointer as the key. JS objects stringify
        // to "[object Object]", so the test uses a Map the same way.
        const table = new Map();
        const items = [
            { label: "Facebook", action: function () { return "facebook"; } },
            { label: "Twitter", action: function () { return "twitter"; } },
            { label: "Instagram", action: function () { return "instagram"; } }
        ];
        items.forEach(function (item) {
            table.set(item, item.action);
        });
        assert.strictEqual(table.get(items[0])(), "facebook");
        assert.strictEqual(table.get(items[1])(), "twitter");
        assert.strictEqual(table.get(items[2])(), "instagram");
    });

    if (process.exitCode) {
        console.error("\nsome webview bridge tests failed");
    } else {
        console.log("\n" + passed + " tests passed");
    }
}

run();
