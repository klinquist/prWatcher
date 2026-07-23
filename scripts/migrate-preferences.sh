#!/bin/zsh
set -euo pipefail

old_domain="com.local.prWatcher"
new_domain="com.linquist.prwatcher"
force=0

if [[ "${1:-}" == "--force" ]]; then
    force=1
elif [[ -n "${1:-}" ]]; then
    print -u2 "Usage: $0 [--force]"
    exit 2
fi

if defaults export "$new_domain" - >/dev/null 2>&1 && [[ "$force" != "1" ]]; then
    print -u2 "Preferences already exist for $new_domain."
    print -u2 "No changes were made. Re-run with --force only if you intend to replace them."
    exit 1
fi

migration_directory="$(mktemp -d "${TMPDIR:-/tmp}/prwatcher-preferences.XXXXXX")"
trap '/bin/rm -rf "$migration_directory"' EXIT
export_path="$migration_directory/preferences.plist"

if ! defaults export "$old_domain" "$export_path" >/dev/null 2>&1; then
    print -u2 "No preferences were found for $old_domain."
    exit 1
fi

defaults import "$new_domain" "$export_path"
defaults write "$new_domain" "didMigratePreferencesFrom.$old_domain" -bool true

print "Migrated prWatcher preferences from $old_domain to $new_domain."
print "You can now launch the new prWatcher build."
