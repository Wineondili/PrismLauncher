#!/usr/bin/env bash
#
# Build the Qt modules Prism Launcher needs on macOS, with Qt's accessibility
# feature disabled (FEATURE_accessibility=OFF).
#
# With accessibility disabled, Qt does not compile its Cocoa accessibility
# bridge (QCocoaAccessibility, QMacAccessibilityElement and the QNSView
# accessibility category) into libqcocoa.dylib, which removes the code path
# that crashes when an accessibility client queries the app:
# https://github.com/PrismLauncher/PrismLauncher/issues/6117
#
# Apart from accessibility, Qt is configured with its defaults, matching the
# official Qt binaries the launcher is normally built against. Homebrew
# prefixes are ignored so that every third-party library Qt needs comes from
# Qt's bundled copies or the macOS SDK, keeping the result relocatable.
#
# Usage: macos-build-qt-no-a11y.sh <install-prefix>
#
# Environment:
#   QT_OSX_ARCHITECTURES      architectures to build for (default: arm64)
#   MACOSX_DEPLOYMENT_TARGET  minimum macOS version (default: 12.0)
#   QT_WORK_DIR               scratch directory for sources and build trees

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <install-prefix>" >&2
    exit 1
fi

QT_VERSION="6.9.3"
QT_MODULES="qtbase qtsvg qtimageformats qtnetworkauth"

PREFIX="$1"
ARCHS="${QT_OSX_ARCHITECTURES:-arm64}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
WORK_DIR="${QT_WORK_DIR:-${RUNNER_TEMP:-/tmp}/qt-no-a11y}"

QT_MIRRORS="
https://download.qt.io/archive/qt/6.9/${QT_VERSION}/submodules
https://qt.mirror.constant.com/archive/qt/6.9/${QT_VERSION}/submodules
https://ftp.fau.de/qtproject/archive/qt/6.9/${QT_VERSION}/submodules
"

# SHA-256 of <module>-everywhere-src-${QT_VERSION}.tar.xz
module_sha256() {
    case "$1" in
        qtbase) echo "c5a1a2f660356ec081febfa782998ae5ddbc5925117e64f50e4be9cd45b8dc6e" ;;
        qtsvg) echo "db76aa3358cbbe6fce7da576ff4669cb9801920188c750d3b12783bbe97026e2" ;;
        qtimageformats) echo "4fb26bdbfbd4b8e480087896514e11c33aba7b6b39246547355ea340c4572ffe" ;;
        qtnetworkauth) echo "67d9dc47ed133e22aa78bedef53963bee3761318e5e74dc98f82ad9814cc7ec7" ;;
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
            return 0
        fi
    done

    echo "Failed to download $tarball with the expected checksum" >&2
    return 1
}

build_qtbase() {
    local src="$WORK_DIR/qtbase-everywhere-src-$QT_VERSION"
    local build="$WORK_DIR/build-qtbase"

    cmake -S "$src" -B "$build" -G Ninja \
        -DCMAKE_MAKE_PROGRAM="$NINJA" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_OSX_SYSROOT="$SYSROOT" \
        -DCMAKE_IGNORE_PREFIX_PATH="$IGNORED_PREFIXES" \
        -DQT_BUILD_EXAMPLES=OFF \
        -DQT_BUILD_TESTS=OFF \
        -DFEATURE_accessibility=OFF \
        -DFEATURE_pkg_config=OFF \
        -DFEATURE_dbus=ON \
        -DFEATURE_dbus_linked=OFF \
        -DFEATURE_openssl_runtime=ON \
        -DOPENSSL_ROOT_DIR="$OPENSSL_HEADERS" \
        -DOPENSSL_INCLUDE_DIR="$OPENSSL_HEADERS/include"

    cmake --build "$build" --parallel
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

# Fail early if accessibility somehow ended up enabled.
gui_config="$(find "$PREFIX/lib/QtGui.framework" -name qtgui-config.h | head -n 1)"
if ! grep -Eq '^#define QT_FEATURE_accessibility -1$' "$gui_config"; then
    echo "QT_FEATURE_accessibility is not disabled in $gui_config" >&2
    exit 1
fi

{
    echo "Qt version:          $QT_VERSION"
    echo "Modules:             $QT_MODULES"
    echo "Architectures:       $ARCHS"
    echo "Deployment target:   $DEPLOYMENT_TARGET"
    echo "Accessibility:       disabled (FEATURE_accessibility=OFF)"
    echo "Xcode:               $(xcodebuild -version | tr '\n' ' ')"
    echo "SDK:                 $(xcrun --sdk macosx --show-sdk-version)"
    echo "CMake:               $(cmake --version | head -n 1)"
} > "$PREFIX/prism-qt-build-info.txt"

cat "$PREFIX/prism-qt-build-info.txt"
