import Foundation
import Testing
@testable import PRWatcherCore

@Test("Drafts take precedence over checks and reviews")
func draftClassification() {
    #expect(PRClassifier.section(
        isDraft: true,
        ciState: "FAILURE",
        reviewDecision: "APPROVED",
        mergeable: "MERGEABLE"
    ) == .drafts)
}

@Test("A failed check is classified as failing CI")
func failedCIClassification() {
    #expect(PRClassifier.section(
        isDraft: false,
        ciState: "FAILURE",
        reviewDecision: "APPROVED",
        mergeable: "MERGEABLE"
    ) == .failingCI)
}

@Test("Pending checks wait for CI")
func pendingCIClassification() {
    #expect(PRClassifier.section(
        isDraft: false,
        ciState: "PENDING",
        reviewDecision: "APPROVED",
        mergeable: "MERGEABLE"
    ) == .waitingForCI)
}

@Test("A pending non-blocking check does not wait for CI")
func nonBlockingPendingCIClassification() {
    #expect(PRClassifier.section(
        isDraft: false,
        ciState: "PENDING",
        reviewDecision: "APPROVED",
        mergeable: "MERGEABLE",
        mergeStateStatus: "UNSTABLE"
    ) == .readyToMerge)
}

@Test("A pending check that blocks merging waits for CI")
func blockingPendingCIClassification() {
    #expect(PRClassifier.section(
        isDraft: false,
        ciState: "PENDING",
        reviewDecision: "APPROVED",
        mergeable: "MERGEABLE",
        mergeStateStatus: "BLOCKED"
    ) == .waitingForCI)
}

@Test("A failing non-blocking check does not fail CI")
func nonBlockingFailedCIClassification() {
    #expect(PRClassifier.section(
        isDraft: false,
        ciState: "FAILURE",
        reviewDecision: "APPROVED",
        mergeable: "MERGEABLE",
        mergeStateStatus: "UNSTABLE"
    ) == .readyToMerge)
}

@Test("Passing checks without approval wait for review")
func reviewClassification() {
    #expect(PRClassifier.section(
        isDraft: false,
        ciState: "SUCCESS",
        reviewDecision: "REVIEW_REQUIRED",
        mergeable: "MERGEABLE"
    ) == .waitingForReview)
}

@Test("An approved PR with passing checks is ready")
func readyClassification() {
    #expect(PRClassifier.section(
        isDraft: false,
        ciState: "SUCCESS",
        reviewDecision: "APPROVED",
        mergeable: "MERGEABLE"
    ) == .readyToMerge)
}

@Test("A merge conflict is surfaced as a failure")
func conflictClassification() {
    #expect(PRClassifier.section(
        isDraft: false,
        ciState: "SUCCESS",
        reviewDecision: "APPROVED",
        mergeable: "CONFLICTING"
    ) == .failingCI)
}

@Test("A watched PR reports merge readiness without leaving Watched")
func watchedMergeReadiness() throws {
    let pullRequest = PullRequest(
        id: "watched",
        number: 123,
        title: "Watched change",
        url: try #require(URL(string: "https://github.com/acme/widgets/pull/123")),
        repository: "acme/widgets",
        author: "hubot",
        isDraft: false,
        mergedAt: nil,
        updatedAt: Date(),
        reviewDecision: "APPROVED",
        ciState: "SUCCESS",
        mergeable: "MERGEABLE",
        state: "OPEN",
        assignment: nil,
        section: .watched
    )

    #expect(pullRequest.section == .watched)
    #expect(pullRequest.isReadyToMerge)
    #expect(pullRequest.becameReadyToMerge(wasReady: false))
    #expect(!pullRequest.becameReadyToMerge(wasReady: true))
    #expect(pullRequest.stateDetail == "Approved")
}

@Test("A PR can move into Watched without losing its status or permissions")
func watchedRepresentation() throws {
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let pullRequest = PullRequest(
        id: "assigned",
        number: 456,
        title: "Assigned change",
        url: try #require(URL(string: "https://github.com/acme/widgets/pull/456")),
        repository: "acme/widgets",
        author: "octocat",
        isDraft: false,
        createdAt: createdAt,
        mergedAt: nil,
        updatedAt: updatedAt,
        reviewDecision: "REVIEW_REQUIRED",
        ciState: "PENDING",
        mergeable: "MERGEABLE",
        state: "OPEN",
        viewerCanClose: true,
        viewerCanUpdate: true,
        viewerCanMerge: true,
        assignment: .teams(["acme/widgets"]),
        section: .assigned
    )

    let watched = pullRequest.asWatched

    #expect(watched.section == .watched)
    #expect(watched.assignment == nil)
    #expect(watched.createdAt == createdAt)
    #expect(watched.updatedAt == updatedAt)
    #expect(watched.reviewDecision == "REVIEW_REQUIRED")
    #expect(watched.ciState == "PENDING")
    #expect(watched.viewerCanClose)
    #expect(watched.viewerCanUpdate)
    #expect(watched.viewerCanMerge)
}

@Test("A confirmed merge can immediately move a PR into Merged")
func mergedRepresentation() throws {
    let mergedAt = Date(timeIntervalSince1970: 1_700_000_200)
    let pullRequest = PullRequest(
        id: "ready",
        number: 789,
        title: "Ready change",
        url: try #require(URL(string: "https://github.com/acme/widgets/pull/789")),
        repository: "acme/widgets",
        author: "octocat",
        isDraft: false,
        mergedAt: nil,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
        reviewDecision: "APPROVED",
        ciState: "SUCCESS",
        mergeable: "MERGEABLE",
        mergeStateStatus: "CLEAN",
        state: "OPEN",
        viewerCanClose: true,
        viewerCanUpdate: true,
        viewerCanMerge: true,
        assignment: nil,
        section: .readyToMerge
    )

    let merged = pullRequest.asMerged(at: mergedAt)

    #expect(merged.section == .merged)
    #expect(merged.state == "MERGED")
    #expect(merged.mergedAt == mergedAt)
    #expect(merged.updatedAt == mergedAt)
    #expect(!merged.isDraft)
    #expect(!merged.viewerCanClose)
    #expect(!merged.viewerCanUpdate)
    #expect(!merged.viewerCanMerge)
    #expect(merged.stateDetail == "Merged")
    #expect(!merged.isReadyToMerge)
}

@Test("A watched PR detects status changes but not its initial load")
func watchedStatusChangeDetection() throws {
    let pullRequest = PullRequest(
        id: "watched",
        number: 123,
        title: "Watched change",
        url: try #require(URL(string: "https://github.com/acme/widgets/pull/123")),
        repository: "acme/widgets",
        author: "hubot",
        isDraft: false,
        mergedAt: nil,
        updatedAt: Date(),
        reviewDecision: "APPROVED",
        ciState: "SUCCESS",
        mergeable: "MERGEABLE",
        state: "OPEN",
        assignment: nil,
        section: .watched
    )

    #expect(!pullRequest.isWatchedStatusChange(from: nil))
    #expect(!pullRequest.isWatchedStatusChange(from: pullRequest.statusFingerprint))
    #expect(pullRequest.isWatchedStatusChange(from: "watched|false|OPEN|REVIEW_REQUIRED|PENDING|MERGEABLE"))
    #expect(pullRequest.hasNotifiableStatusChange(
        from: "watched|false|OPEN|REVIEW_REQUIRED|PENDING|MERGEABLE"
    ))
}

@Test("Underlying CI changes do not re-announce an unchanged draft section")
func draftNotificationOnlyOnSectionChange() throws {
    let pullRequest = PullRequest(
        id: "draft",
        number: 44,
        title: "Long-running draft",
        url: try #require(URL(string: "https://github.com/acme/widgets/pull/44")),
        repository: "acme/widgets",
        author: "octocat",
        isDraft: true,
        mergedAt: nil,
        updatedAt: Date(),
        reviewDecision: nil,
        ciState: "SUCCESS",
        mergeable: "MERGEABLE",
        state: "OPEN",
        assignment: nil,
        section: .drafts
    )

    #expect(!pullRequest.hasNotifiableStatusChange(from: nil))
    #expect(!pullRequest.hasNotifiableStatusChange(
        from: "drafts|true|OPEN||PENDING|MERGEABLE"
    ))
    #expect(pullRequest.hasNotifiableStatusChange(
        from: "waitingForCI|false|OPEN||PENDING|MERGEABLE"
    ))
}

@Test("Custom sections persist their name, query, and color")
func customSectionPersistence() throws {
    let section = CustomPRSection(
        name: "Web Access reviews",
        query: "is:open team-review-requested:verkada/web-access",
        colorHex: "16A34A"
    )
    let decoded = try JSONDecoder().decode(
        CustomPRSection.self,
        from: JSONEncoder().encode(section)
    )

    #expect(decoded == section)
}

@Test("Custom sections created before colors default to purple")
func customSectionLegacyColor() throws {
    let json = #"{"id":"D4D555C4-0404-44EB-A41B-F21C4C6F04A1","name":"Reviews","query":"is:open"}"#
    let section = try JSONDecoder().decode(CustomPRSection.self, from: Data(json.utf8))

    #expect(section.colorHex == "8B5CF6")
}

@Test("GitHub pull request URLs parse into a canonical reference")
func pullRequestURLParsing() throws {
    let reference = try #require(GitHubPullRequestReference(
        string: " https://github.com/acme/widgets/pull/123/files?diff=split "
    ))
    #expect(reference.host == "github.com")
    #expect(reference.owner == "acme")
    #expect(reference.repository == "widgets")
    #expect(reference.number == 123)
    #expect(reference.canonicalURL.absoluteString == "https://github.com/acme/widgets/pull/123")
    #expect(GitHubPullRequestReference(string: "https://github.com/acme/widgets/issues/123") == nil)
}
