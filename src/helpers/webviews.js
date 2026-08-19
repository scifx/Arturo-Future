// Arturo <-> page bridge.
// Keep this conservative (ES5): it is injected before the first document
// on every backend, including older WebView2 builds.
(function (root) {
    "use strict";

    if (root.arturo && typeof root.arturo.call === "function") {
        return;
    }

    var CALLBACK_WAIT_MS = 25;
    var CALLBACK_WAIT_TICKS = 200;

    function whenCallbackReady() {
        if (typeof root.callback === "function") {
            return Promise.resolve();
        }
        return new Promise(function (resolve, reject) {
            var ticks = 0;
            var timer = root.setInterval(function () {
                if (typeof root.callback === "function") {
                    root.clearInterval(timer);
                    resolve();
                    return;
                }
                ticks += 1;
                if (ticks > CALLBACK_WAIT_TICKS) {
                    root.clearInterval(timer);
                    reject(new Error("arturo cannot be loaded"));
                }
            }, CALLBACK_WAIT_MS);
        });
    }

    function invoke(mode, payload) {
        var encoded = JSON.stringify(payload);
        if (typeof root.callback === "function") {
            return root.callback(mode, encoded);
        }
        return whenCallbackReady().then(function () {
            return root.callback(mode, encoded);
        });
    }

    function execCode(code) {
        return invoke("exec", code);
    }

    root.arturo = {
        call: function (method) {
            var args = Array.prototype.slice.call(arguments, 1);
            return invoke("call", {
                method: method,
                args: args
            });
        },

        exec: execCode,

        window: {
            get minimized() { return execCode("window\\minimized?"); },
            set minimized(value) { execCode("window\\minimized?: " + value); },

            get minimizable() { return execCode("window\\minimizable?"); },
            set minimizable(value) { execCode("window\\minimizable?: " + value); },

            get maximized() { return execCode("window\\maximized?"); },
            set maximized(value) { execCode("window\\maximized?: " + value); },

            get maximizable() { return execCode("window\\maximizable?"); },
            set maximizable(value) { execCode("window\\maximizable?: " + value); },

            get closable() { return execCode("window\\closable?"); },
            set closable(value) { execCode("window\\closable?: " + value); },

            get focused() { return execCode("window\\focused?"); },
            set focused(value) { execCode("window\\focused?: " + value); },

            get visible() { return execCode("window\\visible?"); },
            set visible(value) { execCode("window\\visible?: " + value); },

            get fullscreen() { return execCode("window\\fullscreen?"); },
            set fullscreen(value) { execCode("window\\fullscreen?: " + value); }
        }
    };
})(typeof window !== "undefined" ? window : this);
