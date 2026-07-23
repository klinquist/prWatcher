#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
local_release_env="${LOCAL_RELEASE_ENV:-$repo_root/scripts/release.local.env}"

if [[ -f "$local_release_env" ]]; then
    source "$local_release_env"
fi

version="$(<"$repo_root/VERSION")"
dmg_path="${1:-$repo_root/dist/prWatcher-${version}-macOS.dmg}"
notarytool_keychain_profile="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"
developer_id_application_identity="${DEVELOPER_ID_APPLICATION_IDENTITY:-Developer ID Application}"
sign_dmg="${SIGN_DMG:-1}"

usage() {
    print -u2 "Usage: NOTARYTOOL_KEYCHAIN_PROFILE=prwatcher $0 [path-to-dmg]"
    print -u2 "   or: ASC_KEY_PATH=/path/AuthKey_XXXXXXXXXX.p8 ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=uuid $0 [path-to-dmg]"
}

resolve_developer_id_identity() {
    if [[ "$developer_id_application_identity" != "Developer ID Application" ]]; then
        return
    fi

    local resolved_identity
    resolved_identity="$(
        security find-identity -v -p codesigning 2>/dev/null |
            awk '/"Developer ID Application:/ { print $2; exit }'
    )"
    if [[ -z "$resolved_identity" ]]; then
        print -u2 "Could not find a valid Developer ID Application signing identity."
        print -u2 "Set DEVELOPER_ID_APPLICATION_IDENTITY to its SHA-1 hash or full name."
        exit 1
    fi
    developer_id_application_identity="$resolved_identity"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

notarytool_auth_args=()
if [[ -n "${ASC_KEY_PATH:-}" || -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" ]]; then
    if [[ -z "${ASC_KEY_PATH:-}" || -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
        print -u2 "ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID must be set together."
        exit 1
    fi
    if [[ ! -f "$ASC_KEY_PATH" ]]; then
        print -u2 "App Store Connect key not found at ASC_KEY_PATH."
        exit 1
    fi
    notarytool_auth_args=(
        --key "$ASC_KEY_PATH"
        --key-id "$ASC_KEY_ID"
        --issuer "$ASC_ISSUER_ID"
    )
elif [[ -n "$notarytool_keychain_profile" ]]; then
    notarytool_auth_args=(--keychain-profile "$notarytool_keychain_profile")
else
    print -u2 "Notarization credentials are required."
    usage
    exit 1
fi

if [[ ! -f "$dmg_path" ]]; then
    print -u2 "DMG not found at $dmg_path"
    exit 1
fi

if [[ "$sign_dmg" == "1" ]]; then
    resolve_developer_id_identity
    print "Signing ${dmg_path:t}"
    codesign --force --sign "$developer_id_application_identity" --timestamp "$dmg_path"
fi

codesign --verify --verbose=2 "$dmg_path"

print "Submitting ${dmg_path:t} for notarization"
xcrun notarytool submit "$dmg_path" "${notarytool_auth_args[@]}" --wait

print "Stapling notarization ticket"
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"

print "Checking Gatekeeper assessment"
spctl -a -t open --context context:primary-signature -vv "$dmg_path"

print "Notarized DMG: $dmg_path"
