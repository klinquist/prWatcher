#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
local_release_env="${LOCAL_RELEASE_ENV:-$repo_root/scripts/release.local.env}"

if [[ -f "$local_release_env" ]]; then
    source "$local_release_env"
fi

cd "$repo_root"

if ! command -v gh >/dev/null 2>&1; then
    print -u2 "GitHub CLI (gh) is required for publishing releases."
    exit 1
fi
if [[ -n "$(git status --short)" ]]; then
    print -u2 "Working tree is not clean. Commit or stash changes before publishing."
    exit 1
fi

project_version="$(<"$repo_root/VERSION")"
version="${1:-$project_version}"
tag="v$version"
dmg_path="$repo_root/dist/prWatcher-${version}-macOS.dmg"

export SIGN_FOR_DISTRIBUTION="${SIGN_FOR_DISTRIBUTION:-1}"
export NOTARIZE_DMG="${NOTARIZE_DMG:-1}"
export ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-1}"

if [[ "$NOTARIZE_DMG" == "1" ]]; then
    if [[ -n "${ASC_KEY_PATH:-}" || -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" ]]; then
        if [[ -z "${ASC_KEY_PATH:-}" || -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
            print -u2 "ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID must be set together."
            exit 1
        fi
    elif [[ -z "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]]; then
        print -u2 "Set NOTARYTOOL_KEYCHAIN_PROFILE, or the three ASC_KEY_* variables."
        exit 1
    fi
fi

"$repo_root/scripts/build-macos-dmg.sh" "$version"

if [[ ! -f "$dmg_path" ]]; then
    print -u2 "Expected DMG not found at $dmg_path"
    exit 1
fi

if git rev-parse "$tag" >/dev/null 2>&1; then
    if [[ "$(git rev-list -n 1 "$tag")" != "$(git rev-parse HEAD)" ]]; then
        print -u2 "Tag $tag already exists and does not point to HEAD."
        exit 1
    fi
else
    git tag -a "$tag" -m "prWatcher $version"
fi

git push origin HEAD
git push origin "$tag"

if gh release view "$tag" >/dev/null 2>&1; then
    gh release upload "$tag" "$dmg_path" --clobber
else
    gh release create "$tag" "$dmg_path" \
        --title "prWatcher $version" \
        --generate-notes
fi

print "Published notarized GitHub release $tag"
