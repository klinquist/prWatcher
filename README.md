# prWatcher

<p align="center">
  <img src="support/AppIcon-1024.png" alt="prWatcher app icon" width="160">
</p>

prWatcher is a compact native macOS dashboard for the GitHub pull requests that need your attention. It lives comfortably in a corner of the display, talks to GitHub through your existing `gh` CLI login, and keeps useful results visible even when GitHub—or your network—is unavailable.

Current version: **0.6.0**

Created by **Kristopher Linquist**.

## Pull request sections

The built-in dashboard sections are:

- **Watched** — PRs explicitly added by URL or with **Watch This PR** from any PR’s context menu, including PRs viewed under a teammate. Watched PRs always belong to your **Me** view.
- **Assigned to me** — PRs authored by someone else where you are assigned or requested as a reviewer. A setting controls whether team review requests are included.
- **Failing CI** — open, non-draft PRs with merge-blocking failed checks or merge conflicts.
- **Ready to merge** — open PRs with the required approvals, passing checks, and no merge conflict.
- **Waiting for CI** — PRs whose required, merge-blocking checks are still pending; informational checks do not hold a PR here.
- **Waiting for review** — PRs that still need approval.
- **Drafts** — your authored draft PRs.
- **Merged** — your recently merged PRs, ordered by merge time.

Sections with no results are hidden automatically. Every section is collapsible, and its collapsed state is remembered between launches. In **Settings → Edit Sections**, sections can be reordered or disabled entirely; disabled sections are not queried.

## Monitoring your team

Add teammates by GitHub username in Settings. When at least one teammate is configured, a person picker appears in the main window and uses the person’s GitHub display name when available.

- Your **Me** results continue refreshing at the configured interval in the background.
- Selecting a teammate performs a one-time refresh of that person’s authored PRs.
- Switching back to **Me** uses the continuously maintained cache instead of launching another refresh.
- The selected organization filter is global: teammate results are restricted to that same organization.

## Watched pull requests

Use the eye toolbar button to paste a GitHub pull-request URL, or right-click any displayed PR and choose **Watch This PR**. Right-click a watched PR and choose **Stop Watching** to remove it.

Watching and unwatching update the Watched section immediately without refreshing every PR. prWatcher stores each watched PR’s last-known details, so the section remains visible during refreshes and after relaunch; the row updates when its current GitHub status arrives. Status changes are highlighted, badged when the section is collapsed, and eligible for notifications.

## Custom sections

Create custom sections in Settings with a name, color, and GitHub search query. `is:pr` is implied, and a PR may appear in both a custom section and a built-in section.

Before saving a query, you can:

- **Check Query** to see the number of matching results.
- Open the same query on GitHub to inspect the exact matches.

For example:

```text
is:open team-review-requested:example/web -author:octocat -reviewed-by:hubot draft:false
```

Custom sections appear under **Me**, refresh automatically, participate in unread highlighting and notifications, and can be reordered or disabled in **Edit Sections**.

## Actions and automation

Right-click a PR to copy its GitHub link, open it in the browser, or watch/unwatch it. When GitHub reports that your account has permission, the menu also offers the applicable management actions:

- Close the pull request.
- Convert it to a draft or mark it ready for review.
- Enable or cancel **Merge When Ready**.

A permission-aware **Merge** button appears on PRs that are ready. **Merge When Ready** remembers the request and automatically merges after a later poll observes that the PR has moved from waiting/failing/draft into the ready state, then sends a notification and immediately moves an authored PR into Merged. The automation can be canceled from the context menu.

## Refreshing, caching, and offline behavior

- Separate refresh intervals are configurable for unlocked and locked/inactive macOS sessions. They default to three and fifteen minutes respectively, and locked polling can be paused entirely.
- Automatic polling has a configurable local-time sleep window, enabled by default from **7:00 PM to 7:00 AM**. Manual Refresh remains available while polling is asleep, and automatic polling resumes at the end of the window.
- GitHub calls use `gh api`, so prWatcher uses your existing GitHub CLI authentication.
- Settings can check both the GraphQL point allowance and the separate REST search allowance, show their reset times, and report the GraphQL cost measured for the most recent refresh.
- Before each automatic refresh, prWatcher checks both relevant quota buckets. It uses the measured cost of the previous refresh to increase the polling interval when necessary, and defers polling until the applicable reset when there is not enough safe headroom for another refresh.
- Built-in categories use separate, bounded API calls to avoid oversized shared requests.
- Review requests are limited to PRs updated during the past 14 days. Candidate discovery uses GitHub’s lightweight REST search, then hydrates matching PRs in GraphQL batches instead of making one rich query per candidate.
- Direct-only review requests are classified by their actual requested reviewer. prWatcher performs incremental scans during normal polling, revalidates cached direct requests each time, and performs a full reconciliation once per hour so GitHub team requests do not leak into the direct-only view.
- Actionable, Assigned, Watched, and Custom results are fetched before the lower-priority Drafts and Merged sections.
- Results appear progressively as calls complete, while existing rows stay visible to prevent layout jumps.
- Previous results remain on screen when an individual category fails.
- Transient GitHub 502/503/504 gateway errors are retried and summarized without discarding cached data.
- macOS network monitoring pauses polling while offline, shows **Offline — refresh paused**, suppresses raw socket errors, and performs an immediate refresh when connectivity returns.
- The lower-right status displays **Refreshing…** or a minute-rounded **Last updated** age.
- Clicking that status opens a live refresh log with copy and clear controls.

## Notifications and unread results

prWatcher can notify when a PR first appears in a tracked section, changes section, or changes watched/custom status. Newly discovered or changed rows are highlighted. The first click marks a highlighted row as read instead of opening it, and collapsed sections show an unread badge.

macOS Focus and notification settings still control whether alerts are delivered. Notifications require the bundled `.app`; they are disabled when running the Swift Package executable directly.

## Window and display

- Starts at approximately 400 × 900 points near the upper-right of the screen.
- Remains fully resizable.
- Can stay above other apps with **Keep window above other apps** in Settings.
- Can hide its Dock and app-switcher icon while keeping the dashboard window available.
- Can register itself as a native macOS login item from Settings, including a direct link to approve it in Login Items when required.
- Shows each PR’s relative opened time, rounded to the minute.
- Shows the GitHub author on PRs not authored by the signed-in user, including Watched, Custom, Assigned, and teammate rows.
- Includes a native app icon and a quiet, non-animated refresh status.

## Requirements

- macOS 14 or later
- Xcode 16 or later / Swift 6
- [GitHub CLI](https://cli.github.com/) authenticated with `gh auth login`

Confirm GitHub CLI access with:

```sh
gh auth status
```

## Install a release

1. Download `prWatcher-<version>-macOS.dmg` from the project’s GitHub Releases page.
2. Open the downloaded DMG.
3. Drag **prWatcher** onto the **Applications** shortcut in the DMG window.
4. Eject the prWatcher disk image, then open prWatcher from Applications.

Release DMGs are Developer ID signed and notarized by Apple. The app still requires a local, authenticated `gh` CLI installation; no GitHub token is bundled into the download.

## Build and run

Open the native project in Xcode:

```sh
open prWatcher.xcodeproj
```

Select the `prWatcher` scheme and **My Mac**, then click Run.

Alternatively, build an ad-hoc signed app bundle and install it into `~/Applications`. The script stops the currently running app, replaces it, and relaunches the new build:

```sh
./scripts/build-app.sh
```

The staged bundle remains at `dist/prWatcher.app`. You can also run the Swift Package executable for development:

```sh
swift run prWatcher
```

Run the test suite with:

```sh
swift test
```

## Distribution

The release workflow builds a universal Developer ID-signed app, creates a standard drag-to-Applications DMG, submits it to Apple’s notary service, staples the ticket, verifies it with Gatekeeper, and uploads the DMG to a GitHub release.

Keep release credentials outside Git. The preferred setup stores notarization credentials in the login Keychain:

```sh
xcrun notarytool store-credentials prwatcher
cp scripts/release.local.env.example scripts/release.local.env
```

Set your Apple Developer Team ID in `scripts/release.local.env`, then publish the version in `VERSION`:

```sh
./scripts/release-github.sh
```

`scripts/release.local.env`, `.p8` keys, certificates, provisioning profiles, derived data, and built artifacts are ignored by Git. As an alternative to a Keychain profile, the scripts accept `ASC_KEY_PATH`, `ASC_KEY_ID`, and `ASC_ISSUER_ID`; the key file should live outside this repository.

If an existing project already has an untracked release environment file, set `LOCAL_RELEASE_ENV` to that absolute path instead of copying any credentials.

## Bundle identifier and preference migration

The bundle identifier is `com.linquist.prwatcher`. On its first launch, prWatcher automatically copies any existing preferences from `com.local.prWatcher` and the older `com.local.prVisualizer` domain, without replacing preferences already written under the new identifier.

If you prefer to migrate before launching the new app, quit prWatcher and run:

```sh
./scripts/migrate-preferences.sh
```

The one-time script refuses to overwrite an existing `com.linquist.prwatcher` preference domain. Its optional `--force` flag is intentionally required to replace that domain.

## Versioning

prWatcher follows Semantic Versioning. The current user-facing version is recorded in `VERSION`, `support/Info.plist`, and the Xcode target’s `MARKETING_VERSION`; the build number is recorded as `CFBundleVersion` and `CURRENT_PROJECT_VERSION`. Release notes live in [CHANGELOG.md](CHANGELOG.md), and releases are tagged as `vMAJOR.MINOR.PATCH`.
