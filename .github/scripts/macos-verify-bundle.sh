#!/usr/bin/env bash
#
# Verify that a packaged Prism Launcher.app ships a Qt with accessibility
# enabled, and that the bundle is self-contained.
#
# Usage: macos-verify-bundle.sh <app-bundle> [<reference-app-bundle>]
#
# The optional reference bundle (e.g. an official release) is used to diff
# bundle contents.
# Checks marked FAIL make the script exit non-zero; WARN/INFO are reported only.

set -uo pipefail

APP="$1"
REFERENCE_APP="${2:-}"
ARCH="${VERIFY_ARCH:-arm64}"
FAILURES=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
warn() { echo "WARN: $*"; }
info() { echo "INFO: $*"; }

# Mach-O files of a bundle, one per line
macho_files() {
    find "$1" -type f -print0 | while IFS= read -r -d '' file; do
        if file -b "$file" | grep -q "Mach-O"; then
            echo "$file"
        fi
    done
}

framework_binary() {
    echo "$1/Contents/Frameworks/$2.framework/Versions/A/$2"
}

plugin_binary() {
    find "$1/Contents/PlugIns" -name "$2" -type f | head -n 1
}

count_symbols() {
    nm -gU -arch "$ARCH" "$1" 2>/dev/null | grep -c "$2"
}

count_strings() {
    strings -a -arch "$ARCH" "$1" 2>/dev/null | grep -c "$2"
}

# Succeeds if version $1 is greater than version $2
version_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, x, "."); m = split(b, y, ".");
        for (i = 1; i <= (n > m ? n : m); i++) {
            if ((x[i] + 0) > (y[i] + 0)) exit 0;
            if ((x[i] + 0) < (y[i] + 0)) exit 1;
        }
        exit 1
    }'
}

# Print stdin indented, or "(none)" if it is empty
print_or_none() {
    local text
    text="$(cat)"
    if [ -n "$text" ]; then
        echo "$text" | sed 's/^/    /'
    else
        echo "    (none)"
    fi
}

if [ ! -d "$APP" ]; then
    echo "App bundle not found: $APP" >&2
    exit 1
fi

echo "== Accessibility support in the bundled Qt (expected: enabled, with fixes applied)"

qtgui="$(framework_binary "$APP" QtGui)"
qtwidgets="$(framework_binary "$APP" QtWidgets)"
qcocoa="$(plugin_binary "$APP" libqcocoa.dylib)"

for binary in "$qtgui" "$qtwidgets" "$qcocoa"; do
    if [ ! -f "$binary" ]; then
        fail "missing ${binary:-libqcocoa.dylib}"
    fi
done

if [ "$FAILURES" -eq 0 ]; then
    symbols="$(count_symbols "$qtgui" "QAccessible")"
    if [ "$symbols" -gt 0 ]; then
        pass "QtGui exports $symbols QAccessible symbols (accessibility enabled)"
    else
        fail "QtGui exports no QAccessible symbols; accessibility is disabled"
    fi

    found="$(count_strings "$qcocoa" "QMacAccessibilityElement")"
    if [ "$found" -gt 0 ]; then
        pass "libqcocoa.dylib contains the Cocoa accessibility bridge"
    else
        fail "libqcocoa.dylib does not contain QMacAccessibilityElement"
    fi
fi

echo
echo "== Bundle self-containment"

machos="$(macho_files "$APP")"
info "$(echo "$machos" | grep -c .) Mach-O files in the bundle"

bad_links=0
while IFS= read -r binary; do
    [ -z "$binary" ] && continue
    while IFS= read -r dep; do
        case "$dep" in
            @rpath/* | @executable_path/* | @loader_path/* | /System/Library/* | /usr/lib/*) ;;
            *)
                fail "${binary#"$APP"/} links $dep"
                bad_links=$((bad_links + 1))
                ;;
        esac
    done < <(otool -L -arch "$ARCH" "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}')
done <<< "$machos"
if [ "$bad_links" -eq 0 ]; then
    pass "all Mach-O files only link bundled or system libraries"
fi

bad_qt=0
while IFS= read -r dep; do
    case "$dep" in
        @rpath/Qt*.framework/* | @executable_path/../Frameworks/Qt*.framework/* | @loader_path/*Qt*.framework/*) ;;
        *Qt*.framework*)
            fail "prismlauncher links Qt outside the bundle: $dep"
            bad_qt=$((bad_qt + 1))
            ;;
    esac
done < <(otool -L -arch "$ARCH" "$APP/Contents/MacOS/prismlauncher" | tail -n +2 | awk '{print $1}')

for framework in QtCore QtGui QtWidgets QtNetwork QtNetworkAuth QtXml QtConcurrent QtSvg; do
    if [ ! -f "$(framework_binary "$APP" "$framework")" ]; then
        fail "missing $framework.framework"
        bad_qt=$((bad_qt + 1))
    fi
done
if [ "$bad_qt" -eq 0 ]; then
    pass "Qt frameworks are bundled and linked from the bundle"
fi

info "LC_RPATH entries of prismlauncher:"
otool -l -arch "$ARCH" "$APP/Contents/MacOS/prismlauncher" | awk '/LC_RPATH/{f=1} f&&/ path /{print "    " $2; f=0}'

for plugin in libqcocoa.dylib libqmacstyle.dylib libqsvgicon.dylib libqsecuretransportbackend.dylib; do
    if [ -n "$(plugin_binary "$APP" "$plugin")" ]; then
        pass "plugin $plugin is bundled"
    else
        fail "plugin $plugin is missing"
    fi
done

echo
echo "== Architectures and deployment targets"

wrong_arch=0
max_minos="0"
while IFS= read -r binary; do
    [ -z "$binary" ] && continue
    archs="$(lipo -archs "$binary" 2>/dev/null)"
    case " $archs " in
        *" $ARCH "*) ;;
        *)
            fail "${binary#"$APP"/} has architectures '$archs', expected $ARCH"
            wrong_arch=$((wrong_arch + 1))
            ;;
    esac
    minos="$(otool -l -arch "$ARCH" "$binary" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
    if [ -n "$minos" ] && version_gt "$minos" "$max_minos"; then
        max_minos="$minos"
    fi
done <<< "$machos"
if [ "$wrong_arch" -eq 0 ]; then
    pass "all Mach-O files contain $ARCH"
fi
info "prismlauncher architectures: $(lipo -archs "$APP/Contents/MacOS/prismlauncher")"
info "highest minimum macOS version in the bundle: $max_minos"
if version_gt "$max_minos" "${MACOSX_DEPLOYMENT_TARGET:-13.0}"; then
    warn "some binaries require macOS $max_minos, newer than the ${MACOSX_DEPLOYMENT_TARGET:-13.0} deployment target"
fi

echo
echo "== Code signature"

info "$(codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Format|Signature|TeamIdentifier|Runtime)' | tr '\n' ' ')"
if codesign_output="$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)"; then
    pass "codesign --verify --deep --strict"
else
    # Ad-hoc signing (as used by official builds without a certificate) does not
    # always satisfy --strict; whether the app runs is checked by the smoke test.
    warn "codesign --verify --deep --strict reported problems:"
fi
echo "$codesign_output" | print_or_none

echo
echo "== Info.plist"

plist="$APP/Contents/Info.plist"
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion SUFeedURL SUPublicEDKey LSMinimumSystemVersion; do
    info "$key = $(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || echo '<unset>')"
done

if [ -n "$REFERENCE_APP" ] && [ -d "$REFERENCE_APP" ]; then
    echo
    echo "== Differences from $(basename "$REFERENCE_APP")"

    list_bundle() {
        (cd "$1" && find . \( -type f -o -type l \) ! -path "*/_CodeSignature/*" ! -name "CodeResources" | sort)
    }
    info "files only in this bundle (+) or only in the reference (-):"
    diff <(list_bundle "$REFERENCE_APP") <(list_bundle "$APP") | grep '^[<>]' | sed -e 's/^</-/' -e 's/^>/+/' | print_or_none

    info "Info.plist differences (reference -> this bundle):"
    diff <(plutil -convert xml1 -o - "$REFERENCE_APP/Contents/Info.plist") <(plutil -convert xml1 -o - "$plist") | grep '^[<>]' | print_or_none
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$FAILURES check(s) failed."
    exit 1
fi
