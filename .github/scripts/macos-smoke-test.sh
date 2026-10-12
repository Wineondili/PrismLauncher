#!/usr/bin/env bash
#
# Launch a Prism Launcher.app with an empty data directory and check that it
# starts, stays up, and only loads the Qt bundled inside the app. Also dumps
# what the app exposes to accessibility clients and then reads the selected
# children of every item view, like the accessibility clients that trigger
# PrismLauncher/PrismLauncher#6117 do (best effort: this needs the runner to
# grant System Events assistive access). The Quick Setup window shown on first
# launch has a language list with a selected row, which is enough to trigger
# the crash with an affected Qt.
#
# Usage: macos-smoke-test.sh <app-bundle> [<seconds-to-run>]

set -uo pipefail

APP="$(cd "$1" && pwd -P)"
RUN_SECONDS="${2:-30}"
DATA_DIR="$(mktemp -d "${RUNNER_TEMP:-/tmp}/prism-smoke.XXXXXX")"
LOG="$DATA_DIR/stdout.log"
FAILURES=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
info() { echo "INFO: $*"; }

run_with_timeout() {
    local seconds="$1"
    shift
    perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
}

ax_probe() {
    local script="$DATA_DIR/ax-probe.applescript"
    cat > "$script" << 'APPLESCRIPT'
on run argv
    set targetPid to (item 1 of argv) as integer
    tell application "System Events"
        set targetProcess to first process whose unix id is targetPid
        set windowCount to count of windows of targetProcess
        if windowCount is 0 then return "windows=0"
        set windowTitle to name of window 1 of targetProcess
        set uiElements to entire contents of window 1 of targetProcess
        set elementCount to count of uiElements
        set roleNames to {}
        repeat with i from 1 to elementCount
            if i > 40 then exit repeat
            set end of roleNames to (role of item i of uiElements) as text
        end repeat
    end tell
    set AppleScript's text item delimiters to ","
    return "windows=" & windowCount & " title=\"" & windowTitle & "\" elements=" & elementCount & " roles=" & (roleNames as text)
end run
APPLESCRIPT
    run_with_timeout 90 osascript "$script" "$1" 2>&1
}

ax_selection_stress() {
    local script="$DATA_DIR/ax-selection-stress.applescript"
    cat > "$script" << 'APPLESCRIPT'
on run argv
    set targetPid to (item 1 of argv) as integer
    set rounds to (item 2 of argv) as integer
    set itemViews to 0
    set selectionReads to 0
    tell application "System Events"
        set targetProcess to first process whose unix id is targetPid
        repeat with r from 1 to rounds
            set uiElements to entire contents of window 1 of targetProcess
            repeat with uiElement in uiElements
                try
                    set elementRole to role of uiElement
                    if elementRole is in {"AXOutline", "AXTable", "AXList"} then
                        if r = 1 then set itemViews to itemViews + 1
                        try
                            get value of attribute "AXRows" of uiElement
                        end try
                        try
                            get value of attribute "AXSelectedChildren" of uiElement
                            set selectionReads to selectionReads + 1
                        end try
                        try
                            get value of attribute "AXSelectedRows" of uiElement
                        end try
                    end if
                end try
            end repeat
        end repeat
    end tell
    return "item views=" & itemViews & " selected-children reads=" & selectionReads
end run
APPLESCRIPT
    run_with_timeout 120 osascript "$script" "$1" "$2" 2>&1
}

# Prints the exception and the top frames of the crashed thread of an .ips report
summarize_crash_report() {
    python3 -I - "$1" << 'PYTHON'
import json
import sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
_, _, body = text.partition("\n")
try:
    report = json.loads(body)
except ValueError:
    print(text[:4000])
    sys.exit(0)
exception = report.get("exception", {})
print(f"    exception: {exception.get('type')} {exception.get('signal')} {exception.get('subtype', '')}")
images = report.get("usedImages", [])
thread = report.get("threads", [])[report.get("faultingThread", 0)]
for number, frame in enumerate(thread.get("frames", [])[:14]):
    index = frame.get("imageIndex", -1)
    image = images[index].get("name", "?") if 0 <= index < len(images) else "?"
    symbol = frame.get("symbol", "+" + hex(frame.get("imageOffset", 0)))
    print(f"    {number:2d} {image:24s} {symbol}")
PYTHON
}

check_still_running() {
    if kill -0 "$pid" 2> /dev/null; then
        pass "prismlauncher is still running after $1"
    else
        wait "$pid"
        fail "prismlauncher exited with status $? during $1"
    fi
}

start_marker="$DATA_DIR/.started"
touch "$start_marker"
info "launching $APP with data directory $DATA_DIR"
"$APP/Contents/MacOS/prismlauncher" --dir "$DATA_DIR" > "$LOG" 2>&1 &
pid=$!

sleep "$RUN_SECONDS"
check_still_running "${RUN_SECONDS}s"

if kill -0 "$pid" 2> /dev/null; then
    echo
    echo "== Qt binaries loaded by the running process"
    loaded="$(lsof -p "$pid" -Fn 2> /dev/null | sed -n 's/^n//p' | grep -E '/Qt[A-Za-z]*\.framework/|/libq[a-z0-9]*\.dylib$' | sort -u)"
    echo "$loaded" | sed 's/^/    /'
    outside="$(echo "$loaded" | grep -v "^$APP/" || true)"
    if [ -z "$loaded" ]; then
        fail "could not list the Qt binaries loaded by the process"
    elif [ -n "$outside" ]; then
        fail "Qt binaries loaded from outside the bundle:"
        echo "$outside" | sed 's/^/    /'
    else
        pass "all loaded Qt binaries come from inside the bundle"
    fi
fi

if kill -0 "$pid" 2> /dev/null; then
    echo
    echo "== Accessibility tree of the first window (best effort)"
    info "$(ax_probe "$pid")"
    sleep 2
    check_still_running "the accessibility probe"
fi

if kill -0 "$pid" 2> /dev/null; then
    echo
    echo "== Reading the selected children of every item view (best effort)"
    info "$(ax_selection_stress "$pid" 5)"
    sleep 2
    check_still_running "reading the selected children"
fi

if kill -0 "$pid" 2> /dev/null; then
    kill "$pid" 2> /dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2> /dev/null || break
        sleep 1
    done
    kill -9 "$pid" 2> /dev/null
fi
wait "$pid" 2> /dev/null

# macOS writes crash reports asynchronously
sleep 5
crash_reports="$(find "$HOME/Library/Logs/DiagnosticReports" -name 'prismlauncher*' -newer "$start_marker" 2> /dev/null || true)"
if [ -n "$crash_reports" ]; then
    fail "crash report(s) written:"
    for report in $crash_reports; do
        echo "---- $report"
        summarize_crash_report "$report"
    done
else
    pass "no crash reports were written"
fi

echo
echo "== Launcher log"
launcher_log="$(find "$DATA_DIR/logs" -name '*.log' 2> /dev/null | head -n 1)"
if [ -n "$launcher_log" ]; then
    head -n 40 "$launcher_log" | sed 's/^/    /'
else
    head -n 40 "$LOG" | sed 's/^/    /'
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "Smoke test passed."
else
    echo "$FAILURES check(s) failed."
    exit 1
fi
