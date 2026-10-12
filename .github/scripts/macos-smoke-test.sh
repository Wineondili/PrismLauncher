#!/usr/bin/env bash
#
# Launch a Prism Launcher.app with an empty data directory and check that it
# starts, stays up, and only loads the Qt bundled inside the app. Also dumps
# what the app exposes to accessibility clients (best effort: this needs the
# runner to grant System Events assistive access).
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
    cat > "$script" << 'EOF'
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
EOF
    run_with_timeout 90 osascript "$script" "$1" 2>&1
}

start_marker="$DATA_DIR/.started"
touch "$start_marker"
info "launching $APP with data directory $DATA_DIR"
"$APP/Contents/MacOS/prismlauncher" --dir "$DATA_DIR" > "$LOG" 2>&1 &
pid=$!

sleep "$RUN_SECONDS"

if kill -0 "$pid" 2> /dev/null; then
    pass "prismlauncher is still running after ${RUN_SECONDS}s"
else
    wait "$pid"
    fail "prismlauncher exited early with status $?"
fi

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

    echo
    echo "== Accessibility tree of the first window (best effort)"
    info "$(ax_probe "$pid")"
    sleep 2

    if kill -0 "$pid" 2> /dev/null; then
        pass "prismlauncher is still running after the accessibility probe"
    else
        wait "$pid"
        fail "prismlauncher exited with status $? during the accessibility probe"
    fi

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
        head -n 80 "$report"
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
