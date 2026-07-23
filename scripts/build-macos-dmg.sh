#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
local_release_env="${LOCAL_RELEASE_ENV:-$repo_root/scripts/release.local.env}"

if [[ -f "$local_release_env" ]]; then
    source "$local_release_env"
fi

project_path="$repo_root/prWatcher.xcodeproj"
scheme="prWatcher"
derived_data_path="${DERIVED_DATA_PATH:-$repo_root/.derived-release-macos}"
build_root="${BUILD_ROOT:-$repo_root/dist/macos}"
archive_path="$build_root/prWatcher.xcarchive"
export_directory="$build_root/export"
dmg_staging_directory="$build_root/dmg-staging"
export_options_plist="$build_root/export-options.plist"

sign_for_distribution="${SIGN_FOR_DISTRIBUTION:-0}"
notarize_dmg="${NOTARIZE_DMG:-0}"
allow_provisioning_updates="${ALLOW_PROVISIONING_UPDATES:-0}"
development_team="${DEVELOPMENT_TEAM:-}"
developer_id_application_identity="${DEVELOPER_ID_APPLICATION_IDENTITY:-Developer ID Application}"

if [[ "$notarize_dmg" == "1" ]]; then
    sign_for_distribution="1"
fi

if [[ ! -d "$project_path" ]]; then
    print -u2 "Could not find project at $project_path"
    exit 1
fi

project_version="$(<"$repo_root/VERSION")"
version="${1:-$project_version}"
app_name="prWatcher"
app_path="$export_directory/$app_name.app"
dmg_path="$repo_root/dist/${app_name}-${version}-macOS.dmg"

resolve_signing_configuration() {
    local identity_line
    identity_line="$(
        security find-identity -v -p codesigning 2>/dev/null |
            awk '/"Developer ID Application:/ { print; exit }'
    )"

    if [[ "$developer_id_application_identity" == "Developer ID Application" ]]; then
        developer_id_application_identity="$(print "$identity_line" | awk '{ print $2 }')"
    fi
    if [[ -z "$developer_id_application_identity" ]]; then
        print -u2 "Could not find a valid Developer ID Application signing identity."
        exit 1
    fi

    if [[ -z "$development_team" ]]; then
        development_team="$(
            print "$identity_line" |
                sed -nE 's/.*\(([A-Z0-9]{10})\)".*/\1/p'
        )"
    fi
    if [[ -z "$development_team" ]]; then
        print -u2 "Set DEVELOPMENT_TEAM to the 10-character Apple Developer Team ID."
        exit 1
    fi
}

xcodebuild_auth_args=()
if [[ -n "${ASC_KEY_PATH:-}" || -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" ]]; then
    if [[ -z "${ASC_KEY_PATH:-}" || -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
        print -u2 "ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID must be set together."
        exit 1
    fi
    xcodebuild_auth_args=(
        -authenticationKeyPath "$ASC_KEY_PATH"
        -authenticationKeyID "$ASC_KEY_ID"
        -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    )
fi

/bin/rm -rf "$build_root"
mkdir -p "$export_directory" "$dmg_staging_directory" "$repo_root/dist"

archive_args=(
    -project "$project_path"
    -scheme "$scheme"
    -configuration Release
    -destination "generic/platform=macOS"
    -derivedDataPath "$derived_data_path"
    -archivePath "$archive_path"
    archive
)

if [[ "$sign_for_distribution" == "1" ]]; then
    resolve_signing_configuration
    archive_args+=(
        CODE_SIGN_STYLE=Automatic
        CODE_SIGNING_ALLOWED=YES
        DEVELOPMENT_TEAM="$development_team"
    )
    if [[ "$allow_provisioning_updates" == "1" ]]; then
        archive_args=(-allowProvisioningUpdates "${xcodebuild_auth_args[@]}" "${archive_args[@]}")
    fi
    print "Building signed macOS archive for version $version"
else
    archive_args+=(CODE_SIGNING_ALLOWED=NO)
    print "Building unsigned macOS archive for version $version"
fi

xcodebuild "${archive_args[@]}"

app_source="$archive_path/Products/Applications/$app_name.app"
if [[ ! -d "$app_source" ]]; then
    print -u2 "Built app not found at $app_source"
    exit 1
fi

if [[ "$sign_for_distribution" == "1" ]]; then
    /bin/cat >"$export_options_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>signingCertificate</key>
  <string>${developer_id_application_identity}</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>teamID</key>
  <string>${development_team}</string>
</dict>
</plist>
EOF

    export_args=(
        -exportArchive
        -archivePath "$archive_path"
        -exportPath "$export_directory"
        -exportOptionsPlist "$export_options_plist"
    )
    if [[ "$allow_provisioning_updates" == "1" ]]; then
        export_args=(-allowProvisioningUpdates "${xcodebuild_auth_args[@]}" "${export_args[@]}")
    fi
    xcodebuild "${export_args[@]}"
else
    /usr/bin/ditto "$app_source" "$app_path"
fi

if [[ ! -d "$app_path" ]]; then
    print -u2 "Exported app not found at $app_path"
    exit 1
fi

if [[ "$sign_for_distribution" == "1" ]]; then
    codesign --verify --deep --strict --verbose=2 "$app_path"
fi

/bin/rm -rf "$dmg_staging_directory"
mkdir -p "$dmg_staging_directory"
/usr/bin/ditto "$app_path" "$dmg_staging_directory/$app_name.app"
ln -s /Applications "$dmg_staging_directory/Applications"

/bin/rm -f "$dmg_path"
hdiutil create \
    -volname "$app_name" \
    -srcfolder "$dmg_staging_directory" \
    -ov \
    -format UDZO \
    "$dmg_path" >/dev/null

if [[ "$notarize_dmg" == "1" ]]; then
    "$repo_root/scripts/notarize-macos-dmg.sh" "$dmg_path"
fi

print "Built app: $app_path"
print "Built DMG: $dmg_path"
