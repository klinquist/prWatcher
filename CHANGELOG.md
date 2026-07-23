# Changelog

All notable changes to prWatcher are documented here. Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Add a persistent option to hide prWatcher from the Dock and app switcher.

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
