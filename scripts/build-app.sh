#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
configuration="${1:-release}"
app_root="$repo_root/dist/prWatcher.app"
user_applications_dir="$HOME/Applications"
installed_app="$user_applications_dir/prWatcher.app"
legacy_installed_app="$user_applications_dir/prVisualizer.app"

swift build --disable-sandbox --package-path "$repo_root" -c "$configuration"
binary_path="$(swift build --disable-sandbox --package-path "$repo_root" -c "$configuration" --show-bin-path)/prWatcher"

mkdir -p "$app_root/Contents/MacOS" "$app_root/Contents/Resources"
cp "$binary_path" "$app_root/Contents/MacOS/prWatcher"
cp "$repo_root/support/Info.plist" "$app_root/Contents/Info.plist"
cp "$repo_root/support/AppIcon.icns" "$app_root/Contents/Resources/AppIcon.icns"
chmod +x "$app_root/Contents/MacOS/prWatcher"

codesign --force --deep --sign - "$app_root"
print "Built $app_root"

stop_running_app() {
    local process_name="$1"
    local bundle_identifier="$2"
    if ! pgrep -x "$process_name" >/dev/null 2>&1; then
        return
    fi

    print "Stopping the running $process_name…"
    osascript -e "tell application id \"$bundle_identifier\" to quit" >/dev/null 2>&1 || true

    for attempt in {1..30}; do
        if ! pgrep -x "$process_name" >/dev/null 2>&1; then
            return
        fi
        sleep 0.1
    done

    pkill -x "$process_name" || true
}

stop_running_app prWatcher com.local.prWatcher
stop_running_app prVisualizer com.local.prVisualizer

mkdir -p "$user_applications_dir"
/usr/bin/ditto "$app_root" "$installed_app"
codesign --verify --deep --strict "$installed_app"
if [[ -d "$legacy_installed_app" ]]; then
    /bin/rm -rf "$legacy_installed_app"
    print "Removed the superseded $legacy_installed_app"
fi
/usr/bin/open "$installed_app"

print "Installed and launched $installed_app"
