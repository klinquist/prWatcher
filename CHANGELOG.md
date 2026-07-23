# Changelog

All notable changes to prWatcher are documented here. Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
