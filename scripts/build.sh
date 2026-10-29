#!/bin/bash
# SPDX-License-Identifier: 0BSD
# See common.sh for the packaging scripts' license.
set -euo pipefail
source "$(dirname "$0")/common.sh"
require_toolchain

# Discover public identity metadata only. No certificates, private keys, or
# notarization credentials are exported or included in any distribution.
identity="${SIGN_IDENTITY:-}"
identity_name=''
developer_id=''
developer_name=''
development_id=''
development_name=''
if [[ "$identity" != '-' ]]; then
    identities="$(security find-identity -v -p codesigning)" || fail 'Cannot enumerate code-signing identities.'
    identity_pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"(.*)"$'
    while IFS= read -r line; do
        if [[ "$line" =~ $identity_pattern ]]; then
            candidate="${BASH_REMATCH[1]}"
            candidate_name="${BASH_REMATCH[2]}"
            if [[ "$identity" == "$candidate" || "$identity" == "$candidate_name" ]]; then
                identity="$candidate"
                identity_name="$candidate_name"
            fi
            case "$candidate_name" in
                'Developer ID Application:'*)
                    if [[ -z "$developer_id" ]]; then
                        developer_id="$candidate"; developer_name="$candidate_name"
                    fi
                    ;;
                'Apple Development:'*)
                    if [[ -z "$development_id" ]]; then
                        development_id="$candidate"; development_name="$candidate_name"
                    fi
                    ;;
            esac
        fi
    done <<< "$identities"
    if [[ -n "$identity" ]]; then
        [[ -n "$identity_name" ]] || fail 'SIGN_IDENTITY does not match a valid code-signing identity (use its SHA-1 or full name).'
    elif [[ -n "$developer_id" ]]; then
        identity="$developer_id"; identity_name="$developer_name"
    elif [[ -n "$development_id" ]]; then
        identity="$development_id"; identity_name="$development_name"
    elif [[ "${ALLOW_ADHOC_SIGNING:-0}" == 1 ]]; then
        identity='-'
    else
        fail 'No signing identity. Install Developer ID Application/Apple Development, or explicitly set ALLOW_ADHOC_SIGNING=1 for local-only signing.'
    fi
fi
if [[ "$identity" == '-' ]]; then
    [[ "${ALLOW_ADHOC_SIGNING:-0}" == 1 ]] || fail 'Ad-hoc signing requires ALLOW_ADHOC_SIGNING=1.'
    identity_name='Ad-hoc (local use only)'
fi

is_developer_id=no
[[ "$identity_name" != 'Developer ID Application:'* ]] || is_developer_id=yes
if [[ -n "${NOTARY_PROFILE:-}" && "$is_developer_id" != yes ]]; then
    fail 'Notarization requires a Developer ID Application identity; Apple Development and ad-hoc signatures cannot be notarized.'
fi
printf 'Signing identity: %s\n' "$identity_name"

/bin/bash "$ROOT/scripts/build-wimlib.sh"
executables=()
for architecture in arm64 x86_64; do
    swift_arguments=(
        --package-path "$ROOT" --scratch-path "$ROOT/.build/swift-$architecture"
        --configuration release --product WinWriter
        --triple "$architecture-apple-macosx12.0" --sdk "$SDKROOT"
        -Xswiftc -Osize -Xlinker -dead_strip
    )
    xcrun swift build "${swift_arguments[@]}"
    binary_directory="$(xcrun swift build "${swift_arguments[@]}" --show-bin-path)"
    executables+=("$binary_directory/WinWriter")
done

stage="$ROOT/.build/package"
app_name='Win11 USB Creator.app'
app="$stage/$app_name"
rm -rf "$stage"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Licenses"
xcrun lipo -create "${executables[@]}" -output "$app/Contents/MacOS/WinWriter"
xcrun strip -S -x "$app/Contents/MacOS/WinWriter"
cp "$ROOT/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$ROOT/Resources/wimlib-imagex" "$app/Contents/Resources/wimlib-imagex"
cp "$ROOT/Resources/ThirdPartyNotices.txt" "$app/Contents/Resources/Licenses/"
cp "$ROOT/LICENSE" "$app/Contents/Resources/Licenses/WinWriter-LICENSE.txt"
cp "$WIM_SOURCE/COPYING" "$WIM_SOURCE/COPYING.GPLv3" \
    "$WIM_SOURCE/COPYING.LGPL" "$app/Contents/Resources/Licenses/"

# Preserve component-specific copyright and permissive license notices as well
# as the project's GPL/LGPL texts, without shipping source code in the app.
notices="$app/Contents/Resources/Licenses/wimlib-component-notices.txt"
for source_file in "$WIM_SOURCE"/src/*.c "$WIM_SOURCE"/include/wimlib/*.h \
    "$WIM_SOURCE"/include/wimlib.h "$WIM_SOURCE"/include/wimlib_tchar.h \
    "$WIM_SOURCE"/programs/imagex.c; do
    printf '\n--- %s ---\n' "${source_file#"$WIM_SOURCE/"}" >> "$notices"
    while IFS= read -r line; do
        case "$line" in
            '/*'*|' *'*|'*/'*|'') printf '%s\n' "$line" >> "$notices" ;;
            *) break ;;
        esac
    done < "$source_file"
done

assert_universal "$app/Contents/MacOS/WinWriter"
assert_universal "$app/Contents/Resources/wimlib-imagex"
assert_system_dependencies "$app/Contents/MacOS/WinWriter" yes
assert_system_dependencies "$app/Contents/Resources/wimlib-imagex"
plutil -lint "$app/Contents/Info.plist"

sign_arguments=(--force --sign "$identity" --options runtime)
if [[ "$is_developer_id" == yes ]]; then
    sign_arguments+=(--timestamp)
else
    sign_arguments+=(--timestamp=none)
fi
# Sign from the inside out; intentionally no sandbox or broad entitlements.
codesign "${sign_arguments[@]}" "$app/Contents/Resources/wimlib-imagex"
codesign "${sign_arguments[@]}" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

distribution="$ROOT/dist"
mkdir -p "$distribution"
rm -rf "$distribution/$app_name"
mv "$app" "$distribution/$app_name"
app="$distribution/$app_name"
zip="$distribution/Win11-USB-Creator.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format plist > "$stage/notarization.plist"
    status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$stage/notarization.plist")"
    [[ "$status" == Accepted ]] || fail "Notarization was not accepted ($status); see $stage/notarization.plist."
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
fi

# GPL corresponding source is delivered next to the binary, never in the app.
source_name="wimlib-${WIMLIB_VERSION}-corresponding-source"
source_package="$stage/$source_name"
mkdir -p "$source_package/.cache" "$source_package/scripts" "$source_package/Licenses"
cp "$WIM_ARCHIVE" "$source_package/.cache/"
cp "$ROOT/scripts/common.sh" "$ROOT/scripts/build-wimlib.sh" \
    "$ROOT/scripts/wimlib-split-nocheck.patch" "$source_package/scripts/"
cp "$ROOT/scripts/WIMLIB-SOURCE.txt" "$source_package/BUILDING.txt"
cp "$app/Contents/Resources/Licenses/"* "$source_package/Licenses/"
COPYFILE_DISABLE=1 tar -czf "$distribution/$source_name.tar.gz" -C "$stage" "$source_name"
rm -rf "$distribution/build-scripts" "$distribution/Licenses"
mkdir -p "$distribution/build-scripts" "$distribution/Licenses"
cp "$ROOT/scripts/"*.sh "$ROOT/scripts/wimlib-split-nocheck.patch" "$distribution/build-scripts/"
cp "$ROOT/scripts/BUILDING.txt" "$distribution/BUILDING.txt"
cp "$app/Contents/Resources/Licenses/"* "$distribution/Licenses/"
(
    cd "$distribution"
    shasum -a 256 'Win11-USB-Creator.zip' "$source_name.tar.gz" > SHA256SUMS
)

printf '\nApplication: %s\nDistribution: %s\nCorresponding source: %s\n' \
    "$app" "$zip" "$distribution/$source_name.tar.gz"
du -h "$zip" "$distribution/$source_name.tar.gz"
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    printf '\nNot notarized. Public Gatekeeper distribution needs Developer ID and NOTARY_PROFILE.\n'
fi
