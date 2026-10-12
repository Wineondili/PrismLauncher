#!/usr/bin/env bash
#
# Build the Qt modules Prism Launcher needs on macOS, with fixes for the
# accessibility crash in Qt's Cocoa bridge applied (accessibility stays enabled):
# https://github.com/PrismLauncher/PrismLauncher/issues/6117
# https://bugreports.qt.io/browse/QTBUG-149612
#
# The fixes are the patches in qt-patches/ (named <module>-*.patch, applied in
# order after extracting the sources). They are still under review upstream.
#
# Apart from the patches, Qt is configured with its defaults, matching the
# official Qt binaries the launcher is normally built against. Homebrew
# prefixes are ignored so that every third-party library Qt needs comes from
# Qt's bundled copies or the macOS SDK, keeping the result relocatable.
#
# After installing, the accessibility autotests touched by the patches are built
# and run; their output is saved to <install-prefix>/prism-qt-tests.txt.
#
# Usage: macos-build-qt-a11y-fix.sh <install-prefix>
#
# Environment:
#   QT_OSX_ARCHITECTURES      architectures to build for (default: arm64)
#   MACOSX_DEPLOYMENT_TARGET  minimum macOS version (default: 13.0)
#   QT_WORK_DIR               scratch directory for sources and build trees

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <install-prefix>" >&2
    exit 1
fi

QT_VERSION="6.11.2"
QT_MODULES="qtbase qtsvg qtimageformats qtnetworkauth"

PREFIX="$1"
ARCHS="${QT_OSX_ARCHITECTURES:-arm64}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
WORK_DIR="${QT_WORK_DIR:-${RUNNER_TEMP:-/tmp}/qt-a11y-fix}"
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)/qt-patches"

QT_MIRRORS="
https://download.qt.io/archive/qt/6.11/${QT_VERSION}/submodules
https://download.qt.io/official_releases/qt/6.11/${QT_VERSION}/submodules
https://qt.mirror.constant.com/archive/qt/6.11/${QT_VERSION}/submodules
https://ftp.fau.de/qtproject/archive/qt/6.11/${QT_VERSION}/submodules
"

# SHA-256 of <module>-everywhere-src-${QT_VERSION}.tar.xz
module_sha256() {
    case "$1" in
        qtbase) echo "5b2e00eccaf5a4d8c14134ffa0ea8dfd0a35ae1ffc7f8d87fa4305a1ed23cf22" ;;
        qtsvg) echo "d594337feca84c26fb67fe87b85e6a5c12fda404b611d905f9d138210c311876" ;;
        qtimageformats) echo "cecd8900f34b6550076309bc94f62f828008b633a4239e0a08c86788f41001f8" ;;
        qtnetworkauth) echo "0c83c23077ab7824393fa15bb0015c3c5acaf5678544aa789e3fcbb4d41fa05b" ;;
        *) echo "Unknown module $1" >&2; return 1 ;;
    esac
}

NINJA="$(command -v ninja)"
SYSROOT="$(xcrun --sdk macosx --show-sdk-path)"
IGNORED_PREFIXES="/opt/homebrew;/usr/local"

# Qt loads OpenSSL at runtime (like the official binaries); only the headers
# are needed at build time. Copy them out of Homebrew so the Homebrew prefix
# itself can stay ignored.
OPENSSL_HEADERS="$WORK_DIR/openssl-headers"
prepare_openssl_headers() {
    local brew_openssl
    brew_openssl="$(brew --prefix openssl@3)"
    if [ ! -f "$brew_openssl/include/openssl/ssl.h" ]; then
        brew install openssl@3
    fi
    rm -rf "$OPENSSL_HEADERS"
    mkdir -p "$OPENSSL_HEADERS"
    cp -R "$brew_openssl/include" "$OPENSSL_HEADERS/"
}

APPLIED_PATCHES=""
apply_patches() {
    local module="$1"
    for patch_file in "$PATCH_DIR/$module"-*.patch; do
        [ -f "$patch_file" ] || continue
        echo "Applying $(basename "$patch_file")"
        patch -d "$WORK_DIR/$module-everywhere-src-$QT_VERSION" -p1 --forward < "$patch_file"
        APPLIED_PATCHES="$APPLIED_PATCHES $(basename "$patch_file")"
    done
}

download_module() {
    local module="$1"
    local tarball="$module-everywhere-src-$QT_VERSION.tar.xz"
    local expected
    expected="$(module_sha256 "$module")"

    for mirror in $QT_MIRRORS; do
        echo "Downloading $tarball from $mirror"
        if curl -fL --retry 3 --retry-delay 5 -o "$WORK_DIR/$tarball" "$mirror/$tarball" \
            && echo "$expected  $WORK_DIR/$tarball" | shasum -a 256 -c -; then
            rm -rf "$WORK_DIR/$module-everywhere-src-$QT_VERSION"
            tar -xf "$WORK_DIR/$tarball" -C "$WORK_DIR"
            apply_patches "$module"
            return 0
        fi
    done

    echo "Failed to download $tarball with the expected checksum" >&2
    return 1
}

build_qtbase() {
    local src="$WORK_DIR/qtbase-everywhere-src-$QT_VERSION"
    local build="$WORK_DIR/build-qtbase"

    # Tests are configured (but not built by default) so that the
    # accessibility autotests can be built and run afterwards.
    cmake -S "$src" -B "$build" -G Ninja \
        -DCMAKE_MAKE_PROGRAM="$NINJA" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_OSX_SYSROOT="$SYSROOT" \
        -DCMAKE_IGNORE_PREFIX_PATH="$IGNORED_PREFIXES" \
        -DQT_BUILD_EXAMPLES=OFF \
        -DQT_BUILD_TESTS=ON \
        -DQT_BUILD_TESTS_BY_DEFAULT=OFF \
        -DFEATURE_pkg_config=OFF \
        -DFEATURE_dbus=ON \
        -DFEATURE_dbus_linked=OFF \
        -DFEATURE_openssl_runtime=ON \
        -DOPENSSL_ROOT_DIR="$OPENSSL_HEADERS" \
        -DOPENSSL_INCLUDE_DIR="$OPENSSL_HEADERS/include"

    # Keep going after errors so that a failing build reports all of them.
    cmake --build "$build" --parallel -- -k 0
    cmake --install "$build"
}

build_module() {
    local module="$1"
    local src="$WORK_DIR/$module-everywhere-src-$QT_VERSION"
    local build="$WORK_DIR/build-$module"

    cmake -S "$src" -B "$build" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$PREFIX/lib/cmake/Qt6/qt.toolchain.cmake" \
        -DCMAKE_MAKE_PROGRAM="$NINJA" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_OSX_SYSROOT="$SYSROOT" \
        -DCMAKE_IGNORE_PREFIX_PATH="$IGNORED_PREFIXES" \
        -DQT_BUILD_EXAMPLES=OFF \
        -DQT_BUILD_TESTS=OFF

    cmake --build "$build" --parallel
    cmake --install "$build"
}

# Runs the accessibility autotests touched by the patches. Failures are
# recorded rather than fatal: the macOS test drives the native accessibility
# API, which the CI machine may not allow.
run_accessibility_tests() {
    local build="$WORK_DIR/build-qtbase"
    local log="$PREFIX/prism-qt-tests.txt"

    : > "$log"
    if ! cmake --build "$build" --parallel --target tst_qaccessibilitymac tst_qaccessibility >> "$log" 2>&1; then
        echo "Building the accessibility tests failed" | tee -a "$log"
        return 0
    fi

    local test_binary test_function status
    for test in "tst_qaccessibilitymac" "tst_qaccessibility tableStaleChildTest"; do
        test_binary="$(find "$build/tests" -name "${test%% *}" -type f -perm -u+x | head -n 1)"
        test_function="${test#* }"
        [ "$test_function" = "$test" ] && test_function=""
        echo "==== ${test}" | tee -a "$log"
        if [ -z "$test_binary" ]; then
            echo "test binary not found" | tee -a "$log"
            continue
        fi
        status=0
        # shellcheck disable=SC2086 # test_function is empty or a single word
        perl -e 'alarm shift; exec @ARGV' 600 "$test_binary" $test_function >> "$log" 2>&1 || status=$?
        echo "exit status: $status" | tee -a "$log"
    done
    grep -E '^(PASS|FAIL!|SKIP|XFAIL|XPASS|Totals:)' "$log" || true
}

mkdir -p "$WORK_DIR"
prepare_openssl_headers

for module in $QT_MODULES; do
    download_module "$module"
done

build_qtbase
for module in $QT_MODULES; do
    if [ "$module" != "qtbase" ]; then
        build_module "$module"
    fi
done

# Fail early if accessibility somehow ended up disabled.
gui_config="$(find "$PREFIX/lib/QtGui.framework" -name qtgui-config.h | head -n 1)"
if ! grep -Eq '^#define QT_FEATURE_accessibility 1$' "$gui_config"; then
    echo "QT_FEATURE_accessibility is not enabled in $gui_config" >&2
    exit 1
fi

run_accessibility_tests

{
    echo "Qt version:          $QT_VERSION"
    echo "Modules:             $QT_MODULES"
    echo "Architectures:       $ARCHS"
    echo "Deployment target:   $DEPLOYMENT_TARGET"
    echo "Accessibility:       enabled, with fixes applied"
    echo "Patches:            $APPLIED_PATCHES"
    echo "Xcode:               $(xcodebuild -version | tr '\n' ' ')"
    echo "SDK:                 $(xcrun --sdk macosx --show-sdk-version)"
    echo "CMake:               $(cmake --version | head -n 1)"
} > "$PREFIX/prism-qt-build-info.txt"

cat "$PREFIX/prism-qt-build-info.txt"
