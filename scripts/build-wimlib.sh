#!/bin/bash
# SPDX-License-Identifier: 0BSD
# See common.sh for the packaging scripts' license.
set -euo pipefail
source "$(dirname "$0")/common.sh"
require_toolchain

mkdir -p "$CACHE"
if [[ ! -f "$WIM_ARCHIVE" ]]; then
    download="$(mktemp "$CACHE/.wimlib-download.XXXXXX")"
    trap 'rm -f "$download"' EXIT
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
        --output "$download" "$WIMLIB_URL"
    check_source_checksum "$download"
    mv "$download" "$WIM_ARCHIVE"
    trap - EXIT
fi
check_source_checksum "$WIM_ARCHIVE"

# Only the source archive is cached. Fresh out-of-tree builds cannot accidentally
# reuse objects from another SDK, architecture, or compiler configuration.
rm -rf "$WIM_BUILD"
mkdir -p "$WIM_BUILD/source" "$ROOT/Resources"
tar -xzf "$WIM_ARCHIVE" -C "$WIM_BUILD/source"
[[ -x "$WIM_SOURCE/configure" ]] || fail 'The pinned source archive lacks its pre-generated configure script.'
# Split otherwise inherits source integrity tables even without --check.
patch -t -N -F 0 -p1 -d "$WIM_SOURCE" -i "$ROOT/scripts/wimlib-split-nocheck.patch"
build_host="$(/bin/sh "$WIM_SOURCE/build-aux/config.guess")"

for architecture in arm64 x86_64; do
    case "$architecture" in
        arm64) host=aarch64-apple-darwin ;;
        x86_64) host=x86_64-apple-darwin ;;
    esac
    build_directory="$WIM_BUILD/$architecture"
    mkdir -p "$build_directory"
    (
        cd "$build_directory"
        # Both --host and --build prevent configure from executing the other
        # architecture's probe binaries; Rosetta is not a build prerequisite.
        CC='xcrun clang' AR="$(xcrun --find ar)" RANLIB="$(xcrun --find ranlib)" \
        CFLAGS="-Oz -arch $architecture -isysroot $SDKROOT -mmacosx-version-min=12.0" \
        CPPFLAGS='' LDFLAGS="-arch $architecture -isysroot $SDKROOT -mmacosx-version-min=12.0 -Wl,-dead_strip" \
        PKG_CONFIG="$PKG_CONFIG" \
        "$WIM_SOURCE/configure" \
            --build="$build_host" --host="$host" \
            --disable-shared --enable-static --disable-dependency-tracking \
            --without-ntfs-3g --without-fuse --disable-test-support
        make -j "$JOBS" wimlib-imagex
    )
    # --disable-shared links libwim into this CLI, not into the Swift app.
    assert_system_dependencies "$build_directory/wimlib-imagex"
done

xcrun lipo -create "$WIM_BUILD/arm64/wimlib-imagex" \
    "$WIM_BUILD/x86_64/wimlib-imagex" -output "$ROOT/Resources/wimlib-imagex"
xcrun strip -S -x "$ROOT/Resources/wimlib-imagex"
chmod 755 "$ROOT/Resources/wimlib-imagex"
assert_universal "$ROOT/Resources/wimlib-imagex"
assert_system_dependencies "$ROOT/Resources/wimlib-imagex"
printf 'Universal static-libwim CLI: %s\n' "$ROOT/Resources/wimlib-imagex"
