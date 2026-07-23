# Changelog

All notable changes to prWatcher are documented here. Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.7.0] - 2026-07-23

### Added

- Use GitHub native auto-merge when the repository supports it, allowing GitHub to complete the merge while prWatcher is closed or the Mac is asleep.
- Keep the existing polling-based Merge When Ready behavior as an automatic fallback, with a visible polling indicator.
- Expand a PR row on single-click to show exact merge blockers, requested reviewers, review outcomes, unresolved conversations, and required versus informational CI checks.
- Link individual CI checks to their GitHub details while loading expanded details only on demand to preserve polling quota.

### Changed

- Open PR pages from the context menu instead of opening them with a single row click.

## [0.6.2] - 2026-07-23

### Changed

- Check armed Merge When Ready pull requests immediately after the Mac wakes when automatic polling is eligible.
- Attempt an armed automatic merge whenever the latest completed poll reports the PR ready, preventing stale transition state from stranding it.

### Fixed

- Log Merge When Ready decisions on every completed poll, including specific approval, CI, draft, conflict, permission, and status-fetch blockers.
- Log automatic merge attempts, successes, failures, cancellations, and removal of completed registrations.
- Distinguish actual Mac sleep and wake events from the locked-session polling schedule in the refresh log.

## [0.6.1] - 2026-07-23

### Changed

- Run independent GraphQL classification and hydration batches with bounded three-request parallelism.
- Spread large direct-review reconciliations across refreshes in batches of at most 100 candidates.
- Report per-batch reconciliation progress in the refresh log.

### Fixed

- Prevent large GitHub CLI responses from deadlocking when they exceed the process pipe buffer.
- Stop an unresponsive GitHub CLI request after 30 seconds instead of allowing refresh to hang indefinitely.

## [0.6.0] - 2026-07-23

### Added

- Add a configurable local-time polling sleep window, enabled by default from 7:00 PM to 7:00 AM.
- Add Settings quota checks for both GitHub GraphQL points and the separate REST search allowance, including reset times and the measured cost of the latest refresh.

### Changed

- Pace or defer automatic polling when measured refresh cost and remaining GitHub quota indicate that the configured interval is unsafe.
- Limit review-request discovery to PRs updated during the past 14 days.
- Replace rich GraphQL review searches with lightweight REST candidate discovery and batched GraphQL hydration.
- Incrementally scan direct review requests between hourly full reconciliations while revalidating cached direct requests on every poll.

### Fixed

- Distinguish direct user review requests from requests inherited through GitHub teams without repeatedly resolving hundreds of team candidates in one GraphQL search.

## [0.5.0] - 2026-07-23

### Added

- Add a native Launch at Login setting with macOS approval-state handling and a shortcut to Login Items settings.

### Changed

- Refresh actionable, watched, assigned, and custom sections before the lower-priority Drafts and Merged sections.

### Security

- Keep App Store Connect key identifiers and paths out of normal Xcode build invocations unless explicitly enabled.

## [0.4.0] - 2026-07-23

### Added

- Configure separate automatic refresh schedules for active and locked/inactive user sessions, including an option to pause polling while locked.
- Add Developer ID signing, DMG notarization, and GitHub release scripts backed by Keychain or environment-provided credentials.
- Add an optional one-time preference migration script for the new bundle identifier.

### Changed

- Change the bundle identifier to `com.linquist.prwatcher`.
- Automatically migrate preferences from both prior local bundle identifiers on first launch.

## [0.3.2] - 2026-07-22

### Fixed

- Move an authored PR into Merged immediately after Merge When Ready receives a successful merge response.

## [0.3.1] - 2026-07-22

### Fixed

- Ignore pending or failing non-blocking checks when classifying Waiting for CI and Failing CI.

## [0.3.0] - 2026-07-22

### Added

- Add a persistent option to hide prWatcher from the Dock and app switcher.

### Fixed

- Query direct review requests by explicit GitHub username so team review requests are not fetched and discarded in direct-only mode.

## [0.2.0] - 2026-07-22

### Added

- Display the GitHub author alongside the opened time on PR rows not authored by the signed-in user.

## [0.1.0] - 2026-07-22

### Added

- Native, resizable macOS pull-request dashboard with persistent collapsible sections.
- Built-in Watched, Assigned to me, Failing CI, Ready to merge, Waiting for CI, Waiting for review, Drafts, and Merged sections.
- Organization filtering, configurable polling, teammate monitoring, and cached user switching.
- Named, colored, reorderable custom sections backed by GitHub search queries.
- Persistent watched PRs, including context-menu watching from teammate views.
- Permission-aware PR actions, manual merging, and Merge When Ready automation.
- Notifications, unread highlighting, collapsed-section badges, and relative opened times.
- Progressive refresh results, gateway retries, retained stale data, and a live refresh log.
- Network monitoring that pauses polling offline and refreshes immediately after reconnection.
- App icon, Xcode project, Swift Package build, tests, and an install-and-restart build script.
