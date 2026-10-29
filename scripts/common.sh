#!/bin/bash
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Win11 USB Creator contributors
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted. THE SOFTWARE IS PROVIDED
# "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE
# INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT
# SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL
# DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
# WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
# OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

set -euo pipefail
# Preserve a caller-installed pkg-config before restricting the build PATH.
PKG_CONFIG="${PKG_CONFIG:-$(command -v pkg-config || true)}"
export PKG_CONFIG
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export MACOSX_DEPLOYMENT_TARGET=12.0
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIMLIB_VERSION=1.14.5
WIMLIB_SHA256=84221a3abd5b91228f15f8e6065c335a336237b5738197b75bf419eea561a194
WIMLIB_URL="https://wimlib.net/downloads/wimlib-${WIMLIB_VERSION}.tar.gz"
CACHE="$ROOT/.cache"
WIM_ARCHIVE="$CACHE/wimlib-${WIMLIB_VERSION}.tar.gz"
WIM_BUILD="$ROOT/.build/wimlib"
WIM_SOURCE="$WIM_BUILD/source/wimlib-${WIMLIB_VERSION}"

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

require_toolchain() {
    [[ "$(uname -s)" == Darwin ]] || fail 'Building requires macOS with Xcode Command Line Tools (xcode-select --install).'
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    export SDKROOT
    xcrun --find clang >/dev/null
    xcrun --find swift >/dev/null
    [[ -n "$PKG_CONFIG" && -x "$PKG_CONFIG" ]] || fail 'Building wimlib requires pkg-config (build-time only). Install pkg-config or set PKG_CONFIG to its executable path.'
    JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail 'JOBS must be a positive integer.'
}

check_source_checksum() {
    local checksum ignored
    read -r checksum ignored < <(shasum -a 256 "$1")
    [[ "$checksum" == "$WIMLIB_SHA256" ]] || fail "Checksum mismatch for $1. Delete the cached archive and rebuild."
}

assert_universal() {
    local architectures
    architectures="$(xcrun lipo -archs "$1")"
    [[ " $architectures " == *' arm64 '* && " $architectures " == *' x86_64 '* ]] || fail "Missing universal slices in $1: $architectures"
}

assert_system_dependencies() {
    local binary="$1" allow_swift="${2:-no}" dependency rest libraries
    libraries="$(xcrun otool -L "$binary")"
    while read -r dependency rest; do
        case "$dependency" in
            /usr/lib/*|/System/Library/*|'') ;;
            @rpath/libswift*.dylib)
                [[ "$allow_swift" == yes ]] || fail "Non-system dependency in $binary: $dependency"
                ;;
            *)
                # otool prints a filename/architecture heading without a version.
                [[ "$rest" != *'compatibility version'* ]] || fail "Non-system dependency in $binary: $dependency"
                ;;
        esac
    done <<< "$libraries"
}
