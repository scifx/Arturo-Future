#!/bin/sh
# Functional tests for the webview Windows fixes (issue #2209).
set -e
cd "$(dirname "$0")/../.."
node tests/webview/test_bridge.js
python3 tests/webview/test_webview.py
