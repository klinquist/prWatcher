import Darwin
import Foundation

private final class ProcessPipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collectedData = Data()

    func append(_ data: Data) {
        lock.lock()
        collectedData.append(data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return collectedData
    }
}

private final class ConcurrentBatchResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Data?]
    private var firstError: Error?

    init(count: Int) {
        results = Array(repeating: nil, count: count)
    }

    var hasError: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstError != nil
    }

    func record(_ data: Data, at index: Int) {
        lock.lock()
        results[index] = data
        lock.unlock()
    }

    func record(_ error: Error) {
        lock.lock()
        if firstError == nil {
            firstError = error
        }
        lock.unlock()
    }

    func resolved() throws -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        if let firstError {
            throw firstError
        }
        guard results.allSatisfy({ $0 != nil }) else {
            throw GitHubClientError.invalidResponse("a concurrent GitHub request did not complete")
        }
        return results.compactMap { $0 }
    }
}

private final class DirectReviewRequestCache: @unchecked Sendable {
    struct Entry {
        var pullRequestIDs: [String]
        var lastScanAt: Date
        var lastFullReconciliationAt: Date
        var reconciliationNextPage: Int?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func entry(for key: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    func set(_ entry: Entry, for key: String) {
        lock.lock()
        entries[key] = entry
        lock.unlock()
    }
}

public enum GitHubClientError: LocalizedError {
    case ghNotFound
    case commandFailed(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .ghNotFound:
            return "GitHub CLI (gh) was not found. Install it with Homebrew, then sign in with ‘gh auth login’."
        case .commandFailed(let message):
            return message
        case .invalidResponse(let message):
            return "GitHub returned an invalid response: \(message)"
        }
    }
}

public struct GitHubClient: Sendable {
    public let executableURL: URL
    private let directReviewRequestCache: DirectReviewRequestCache

    public init(executableURL: URL? = nil) throws {
        if let executableURL {
            self.executableURL = executableURL
        } else if let found = Self.findExecutable() {
            self.executableURL = found
        } else {
            throw GitHubClientError.ghNotFound
        }
        directReviewRequestCache = DirectReviewRequestCache()
    }

    public static func findExecutable() -> URL? {
        let manager = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/local/homebrew/bin/gh",
            "/usr/bin/gh"
        ]
        if let path = candidates.first(where: { manager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["gh"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    public func fetchPullRequests(
        organization: String? = nil,
        watchedURLs: [URL] = [],
        authorLogin: String? = nil,
        customSections: [CustomPRSection] = [],
        includedSections: Set<PRSection> = Set(PRSection.allCases.filter { $0 != .custom }),
        includeTeamReviewRequests: Bool = true,
        onLog: (@Sendable (PRRefreshLogEvent) -> Void)? = nil,
        onUpdate: (@Sendable (PRFetchUpdate) async -> Void)? = nil
    ) async throws -> PRSnapshot {
        let executableURL = self.executableURL
        let directReviewRequestCache = self.directReviewRequestCache
        let organizationQualifier = Self.organizationQualifier(organization)
        let normalizedAuthor = authorLogin.flatMap(Self.normalizedGitHubLogin)
        if authorLogin != nil && normalizedAuthor == nil {
            throw GitHubClientError.invalidResponse("Invalid GitHub username")
        }
        let authorQualifier = normalizedAuthor.map { "author:\($0)" } ?? "author:@me"
        return try await Task.detached(priority: .userInitiated) {
            onLog?(PRRefreshLogEvent(
                level: .info,
                message: normalizedAuthor.map { "Refresh started for @\($0)." }
                    ?? "Refresh started for Me."
            ))
            var viewer = ""
            var authored: [PRNode] = []
            var assigned: [PRNode] = []
            var reviewRequested: [PRNode] = []
            var merged: [PRNode] = []
            var watched: [PRNode] = []
            var customSectionResults: [CustomPRSectionResult] = []
            var refreshedSections = Set<PRSection>()
            var refreshedCustomSectionIDs = Set<UUID>()
            var failedRefreshLabels: [String] = []

            let authoredSectionOrder = Self.priorityAuthoredSectionOrder
            for section in authoredSectionOrder where includedSections.contains(section) {
                let qualifier = Self.authoredSearchQualifier(for: section)
                let result: (viewer: String, nodes: [PRNode], hasNextPage: Bool, endCursor: String?)
                do {
                    result = try Self.fetchSearch(
                        executableURL: executableURL,
                        query: "is:pr is:open \(authorQualifier) \(qualifier) archived:false\(organizationQualifier) sort:updated-desc",
                        count: 50,
                        logLabel: section.title,
                        onLog: onLog
                    )
                } catch where Self.isTransientGatewayError(error.localizedDescription) {
                    failedRefreshLabels.append(section.title)
                    continue
                }
                viewer = result.viewer
                authored.append(contentsOf: result.nodes)
                refreshedSections.insert(section)
                if let onUpdate {
                    await onUpdate(PRFetchUpdate(
                        snapshot: Self.makeSnapshot(
                            viewer: viewer,
                            authored: authored,
                            assigned: assigned,
                            reviewRequested: reviewRequested,
                            merged: merged,
                            includedSections: includedSections
                        ),
                        refreshedSections: refreshedSections
                    ))
                }
            }

            if normalizedAuthor == nil && includedSections.contains(.assigned) {
                var assignedQueriesSucceeded = true
                do {
                    let assignedResult = try Self.fetchSearch(
                        executableURL: executableURL,
                        query: "is:pr is:open assignee:@me -author:@me archived:false\(organizationQualifier) sort:updated-desc",
                        count: 50,
                        logLabel: "Assigned to me — direct assignments",
                        onLog: onLog
                    )
                    viewer = assignedResult.viewer
                    assigned = assignedResult.nodes
                    if let onUpdate {
                        await onUpdate(PRFetchUpdate(
                            snapshot: Self.makeSnapshot(
                                viewer: viewer,
                                authored: authored,
                                assigned: assigned,
                                reviewRequested: reviewRequested,
                                merged: merged,
                                includedSections: includedSections
                            ),
                            refreshedSections: refreshedSections.union([.assigned])
                        ))
                    }
                } catch where Self.isTransientGatewayError(error.localizedDescription) {
                    assignedQueriesSucceeded = false
                }

                if let reviewQualifier = Self.reviewRequestQualifier(
                    includeTeamReviewRequests: includeTeamReviewRequests,
                    viewerLogin: viewer
                ) {
                    do {
                        let reviewResult = try Self.fetchReviewRequestedPullRequests(
                            executableURL: executableURL,
                            reviewQualifier: reviewQualifier,
                            organizationQualifier: organizationQualifier,
                            viewerLogin: viewer,
                            includeTeamReviewRequests: includeTeamReviewRequests,
                            cache: directReviewRequestCache,
                            logLabel: includeTeamReviewRequests
                                ? "Assigned to me — review requests, including teams"
                                : "Assigned to me — direct review requests",
                            onLog: onLog
                        )
                        viewer = reviewResult.viewer
                        reviewRequested = reviewResult.nodes
                        if let onUpdate {
                            await onUpdate(PRFetchUpdate(
                                snapshot: Self.makeSnapshot(
                                    viewer: viewer,
                                    authored: authored,
                                    assigned: assigned,
                                    reviewRequested: reviewRequested,
                                    merged: merged,
                                    includedSections: includedSections
                                ),
                                refreshedSections: refreshedSections.union([.assigned])
                            ))
                        }
                    } catch {
                        assignedQueriesSucceeded = false
                        onLog?(PRRefreshLogEvent(
                            level: .error,
                            message: "\(includeTeamReviewRequests ? "Assigned to me — review requests, including teams" : "Assigned to me — direct review requests"): \(error.localizedDescription)"
                        ))
                    }
                } else {
                    assignedQueriesSucceeded = false
                    onLog?(PRRefreshLogEvent(
                        level: .warning,
                        message: "Assigned to me — direct review requests skipped because the signed-in GitHub username was unavailable."
                    ))
                }

                if assignedQueriesSucceeded {
                    refreshedSections.insert(.assigned)
                } else {
                    failedRefreshLabels.append(PRSection.assigned.title)
                }
            }

            if normalizedAuthor == nil && includedSections.contains(.watched) {
                var watchedHadTransientFailure = false
                for reference in watchedURLs.prefix(50).compactMap(GitHubPullRequestReference.init(url:)) {
                    let node: PRNode
                    do {
                        node = try Self.fetchWatchedNode(
                            executableURL: executableURL,
                            reference: reference,
                            logLabel: "Watched — \(reference.owner)/\(reference.repository)#\(reference.number)",
                            onLog: onLog
                        )
                    } catch where Self.isTransientGatewayError(error.localizedDescription) {
                        watchedHadTransientFailure = true
                        continue
                    } catch {
                        continue
                    }
                    watched.append(node)
                    if let onUpdate {
                        await onUpdate(PRFetchUpdate(
                            snapshot: Self.makeSnapshot(
                                viewer: viewer,
                                watched: watched,
                                authored: authored,
                                assigned: assigned,
                                reviewRequested: reviewRequested,
                                merged: merged,
                                includedSections: includedSections
                            ),
                            refreshedSections: refreshedSections.union([.watched])
                        ))
                    }
                }
                if watchedHadTransientFailure {
                    failedRefreshLabels.append(PRSection.watched.title)
                } else {
                    refreshedSections.insert(.watched)
                }
            }

            if normalizedAuthor == nil {
                for section in customSections.prefix(20) {
                    let trimmedQuery = section.query.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedQuery.isEmpty else { continue }
                    let result: (viewer: String, nodes: [PRNode], hasNextPage: Bool, endCursor: String?)
                    do {
                        result = try Self.fetchSearch(
                            executableURL: executableURL,
                            query: Self.customSearchQuery(trimmedQuery),
                            count: 50,
                            logLabel: "Custom — \(section.name)",
                            onLog: onLog
                        )
                    } catch where Self.isTransientGatewayError(error.localizedDescription) {
                        failedRefreshLabels.append(section.name)
                        continue
                    }
                    viewer = result.viewer
                    refreshedCustomSectionIDs.insert(section.id)
                    customSectionResults.append(CustomPRSectionResult(
                        sectionID: section.id,
                        pullRequests: Self.makeCustomPullRequests(result.nodes, viewer: result.viewer)
                    ))
                    if let onUpdate {
                        await onUpdate(PRFetchUpdate(
                            snapshot: Self.makeSnapshot(
                                viewer: viewer,
                                watched: watched,
                                authored: authored,
                                assigned: assigned,
                                reviewRequested: reviewRequested,
                                merged: merged,
                                customSectionResults: customSectionResults,
                                includedSections: includedSections
                            ),
                            refreshedSections: refreshedSections,
                            refreshedCustomSectionIDs: [section.id]
                        ))
                    }
                }
            }

            if includedSections.contains(.drafts) {
                do {
                    let result = try Self.fetchSearch(
                        executableURL: executableURL,
                        query: "is:pr is:open \(authorQualifier) \(Self.authoredSearchQualifier(for: .drafts)) archived:false\(organizationQualifier) sort:updated-desc",
                        count: 50,
                        logLabel: PRSection.drafts.title,
                        onLog: onLog
                    )
                    viewer = result.viewer
                    authored.append(contentsOf: result.nodes)
                    refreshedSections.insert(.drafts)
                    if let onUpdate {
                        await onUpdate(PRFetchUpdate(
                            snapshot: Self.makeSnapshot(
                                viewer: viewer,
                                watched: watched,
                                authored: authored,
                                assigned: assigned,
                                reviewRequested: reviewRequested,
                                merged: merged,
                                customSectionResults: customSectionResults,
                                includedSections: includedSections
                            ),
                            refreshedSections: refreshedSections
                        ))
                    }
                } catch where Self.isTransientGatewayError(error.localizedDescription) {
                    failedRefreshLabels.append(PRSection.drafts.title)
                }
            }

            if includedSections.contains(.merged) {
                do {
                    let result = try Self.fetchSearch(
                        executableURL: executableURL,
                        query: "is:pr is:merged \(authorQualifier) archived:false\(organizationQualifier) sort:updated-desc",
                        count: 25,
                        logLabel: PRSection.merged.title,
                        onLog: onLog
                    )
                    viewer = result.viewer
                    merged = result.nodes
                    refreshedSections.insert(.merged)
                    if let onUpdate {
                        await onUpdate(PRFetchUpdate(
                            snapshot: Self.makeSnapshot(
                                viewer: viewer,
                                watched: watched,
                                authored: authored,
                                assigned: assigned,
                                reviewRequested: reviewRequested,
                                merged: merged,
                                customSectionResults: customSectionResults,
                                includedSections: includedSections
                            ),
                            refreshedSections: refreshedSections
                        ))
                    }
                } catch where Self.isTransientGatewayError(error.localizedDescription) {
                    failedRefreshLabels.append(PRSection.merged.title)
                }
            }

            let snapshot = Self.makeSnapshot(
                viewer: viewer,
                watched: watched,
                authored: authored,
                assigned: assigned,
                reviewRequested: reviewRequested,
                merged: merged,
                customSectionResults: customSectionResults,
                includedSections: includedSections,
                refreshedSectionsMetadata: refreshedSections,
                refreshedCustomSectionIDsMetadata: refreshedCustomSectionIDs,
                refreshWarning: Self.partialRefreshWarning(failedRefreshLabels)
            )
            Self.logRefreshCompletion(snapshot, onLog: onLog)
            return snapshot
        }.value
    }

    static let priorityAuthoredSectionOrder: [PRSection] = [
        .failingCI, .readyToMerge, .waitingForCI, .waitingForReview,
    ]

    static func authoredSearchQualifier(for section: PRSection) -> String {
        switch section {
        case .drafts:
            return "is:draft"
        case .readyToMerge:
            return "draft:false review:approved"
        case .waitingForCI:
            return "draft:false status:pending"
        case .failingCI, .waitingForReview:
            return "draft:false"
        case .watched, .merged, .assigned, .custom:
            return ""
        }
    }

    static func reviewRequestQualifier(
        includeTeamReviewRequests: Bool,
        viewerLogin: String
    ) -> String? {
        if let login = normalizedGitHubLogin(viewerLogin) {
            return "review-requested:\(login)"
        }
        return includeTeamReviewRequests ? "review-requested:@me" : nil
    }

    static func reviewRequestRecencyQualifier(
        now: Date = Date(),
        lookbackDays: Int = 14
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cutoff = calendar.date(byAdding: .day, value: -lookbackDays, to: now) ?? now
        let components = calendar.dateComponents([.year, .month, .day], from: cutoff)
        return String(
            format: "updated:>=%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    public func fetchUserProfile(login: String) async throws -> GitHubUserProfile {
        guard let normalizedLogin = Self.normalizedGitHubLogin(login) else {
            throw GitHubClientError.invalidResponse("Enter a valid GitHub username")
        }
        let executableURL = self.executableURL
        return try await Task.detached(priority: .userInitiated) {
            let arguments = [
                "api", "graphql",
                "-f", "query=\(Self.userProfileGraphQLQuery)",
                "-f", "login=\(normalizedLogin)"
            ]
            let data = try Self.runWithGatewayRetry(executableURL: executableURL, arguments: arguments)
            return try Self.decodeUserProfile(data)
        }.value
    }

    public func fetchWatchedPullRequest(url: URL) async throws -> PullRequest {
        guard let reference = GitHubPullRequestReference(url: url) else {
            throw GitHubClientError.invalidResponse("Enter a GitHub pull request URL such as https://github.com/owner/repository/pull/123")
        }
        let executableURL = self.executableURL
        return try await Task.detached(priority: .userInitiated) {
            let node = try Self.fetchWatchedNode(executableURL: executableURL, reference: reference)
            return Self.makePullRequest(node, viewer: "", section: .watched, assignment: nil)
        }.value
    }

    public func fetchPullRequestDetails(url: URL) async throws -> PullRequestDetails {
        guard let reference = GitHubPullRequestReference(url: url) else {
            throw GitHubClientError.invalidResponse("Enter a valid GitHub pull request URL")
        }
        let executableURL = self.executableURL
        return try await Task.detached(priority: .userInitiated) {
            var arguments = ["api", "graphql"]
            if reference.host.lowercased() != "github.com" {
                arguments += ["--hostname", reference.host]
            }
            arguments += [
                "-f", "query=\(Self.pullRequestDetailsGraphQLQuery)",
                "-f", "owner=\(reference.owner)",
                "-f", "repository=\(reference.repository)",
                "-F", "number=\(reference.number)",
            ]
            let data = try Self.runWithGatewayRetry(
                executableURL: executableURL,
                arguments: arguments
            )
            return try Self.decodePullRequestDetails(data)
        }.value
    }

    public func customSearchMatchCount(query: String) async throws -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitHubClientError.invalidResponse("Enter a GitHub search query")
        }
        let executableURL = self.executableURL
        let resolvedQuery = Self.customSearchQuery(trimmed)
        return try await Task.detached(priority: .userInitiated) {
            let data = try Self.runWithGatewayRetry(
                executableURL: executableURL,
                arguments: Self.customSearchCountArguments(query: resolvedQuery)
            )
            return try Self.decodeCustomSearchCount(data)
        }.value
    }

    static func organizationQualifier(_ organization: String?) -> String {
        guard let organization, !organization.isEmpty else { return "" }
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard organization.unicodeScalars.allSatisfy(allowedCharacters.contains) else { return "" }
        return " org:\(organization)"
    }

    public static func customSearchQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let alreadySpecifiesPullRequests = trimmed
            .split(whereSeparator: \.isWhitespace)
            .contains { $0.lowercased() == "is:pr" }
        return alreadySpecifiesPullRequests ? trimmed : "is:pr \(trimmed)"
    }

    public static func customSearchURL(query: String) -> URL? {
        var components = URLComponents(string: "https://github.com/pulls")
        components?.queryItems = [
            URLQueryItem(name: "q", value: customSearchQuery(query))
        ]
        return components?.url
    }

    static func normalizedGitHubLogin(_ login: String) -> String? {
        var normalized = login.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("@") { normalized.removeFirst() }
        guard !normalized.isEmpty, normalized.count <= 39 else { return nil }
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard normalized.unicodeScalars.allSatisfy(allowedCharacters.contains),
              !normalized.hasPrefix("-"),
              !normalized.hasSuffix("-") else { return nil }
        return normalized
    }

    public func fetchOrganizations() async throws -> [String] {
        let executableURL = self.executableURL
        return try await Task.detached(priority: .userInitiated) {
            let data = try Self.runWithGatewayRetry(
                executableURL: executableURL,
                arguments: ["api", "graphql", "-f", "query=\(Self.organizationsGraphQLQuery)"]
            )
            return try Self.decodeOrganizations(data)
        }.value
    }

    public func fetchRateLimitStatus() async throws -> GitHubRateLimitStatus {
        let executableURL = self.executableURL
        return try await Task.detached(priority: .utility) {
            let data = try Self.runWithGatewayRetry(
                executableURL: executableURL,
                arguments: ["api", "--method", "GET", "rate_limit"]
            )
            return try Self.decodeRateLimitStatus(data)
        }.value
    }

    public func close(_ pullRequest: PullRequest) async throws {
        try await runAction(["pr", "close", pullRequest.url.absoluteString])
    }

    public func markDraft(_ pullRequest: PullRequest) async throws {
        try await runAction(["pr", "ready", pullRequest.url.absoluteString, "--undo"])
    }

    public func markReady(_ pullRequest: PullRequest) async throws {
        try await runAction(["pr", "ready", pullRequest.url.absoluteString])
    }

    public func merge(_ pullRequest: PullRequest) async throws {
        try await runAction(try Self.mergeArguments(for: pullRequest, auto: false))
    }

    public func enableAutoMerge(_ pullRequest: PullRequest) async throws {
        try await runAction(try Self.mergeArguments(for: pullRequest, auto: true))
    }

    static func mergeArguments(
        for pullRequest: PullRequest,
        auto: Bool
    ) throws -> [String] {
        guard let method = pullRequest.preferredMergeMethod else {
            throw GitHubClientError.commandFailed(
                "This repository does not allow any merge method supported by prWatcher."
            )
        }
        var arguments = ["pr", "merge", pullRequest.url.absoluteString]
        if auto {
            arguments.append("--auto")
        }
        arguments.append(method.ghFlag)
        return arguments
    }

    public func disableAutoMerge(_ pullRequest: PullRequest) async throws {
        try await runAction(["pr", "merge", pullRequest.url.absoluteString, "--disable-auto"])
    }

    private func runAction(_ arguments: [String]) async throws {
        let executableURL = self.executableURL
        _ = try await Task.detached(priority: .userInitiated) {
            try Self.run(executableURL: executableURL, arguments: arguments)
        }.value
    }

    static let graphQLQuery = #"""
    query PRWatcher($searchQuery: String!, $count: Int!, $after: String) {
      viewer { login }
      results: search(query: $searchQuery, type: ISSUE, first: $count, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { ...PullRequestFields }
      }
    }

    fragment PullRequestFields on PullRequest {
      id
      number
      title
      url
      isDraft
      createdAt
      mergedAt
      updatedAt
      reviewDecision
      mergeable
      mergeStateStatus
      state
      viewerCanClose
      viewerCanUpdate
      viewerCanEnableAutoMerge
      autoMergeRequest { mergeMethod enabledBy { login } }
      author { login }
      repository {
        nameWithOwner
        viewerPermission
        mergeCommitAllowed
        squashMergeAllowed
        rebaseMergeAllowed
      }
      assignees(first: 20) { nodes { login } }
      reviewRequests(first: 20) {
        nodes {
          requestedReviewer {
            ... on User { login }
            ... on Team { name slug organization { login } }
          }
        }
      }
      commits(last: 1) {
        nodes { commit { statusCheckRollup { state } } }
      }
    }
    """#

    static let pullRequestNodesGraphQLQuery = #"""
    query PRWatcherNodes($ids: [ID!]!) {
      viewer { login }
      nodes(ids: $ids) {
        ... on PullRequest {
          id
          number
          title
          url
          isDraft
          createdAt
          mergedAt
          updatedAt
          reviewDecision
          mergeable
          mergeStateStatus
          state
          viewerCanClose
          viewerCanUpdate
          viewerCanEnableAutoMerge
          autoMergeRequest { mergeMethod enabledBy { login } }
          author { login }
          repository {
            nameWithOwner
            viewerPermission
            mergeCommitAllowed
            squashMergeAllowed
            rebaseMergeAllowed
          }
          assignees(first: 20) { nodes { login } }
          reviewRequests(first: 20) {
            nodes {
              requestedReviewer {
                ... on User { login }
                ... on Team { name slug organization { login } }
              }
            }
          }
          commits(last: 1) {
            nodes { commit { statusCheckRollup { state } } }
          }
        }
      }
    }
    """#

    static let directReviewCandidatesGraphQLQuery = #"""
    query PRWatcherDirectReviewCandidates($ids: [ID!]!) {
      viewer { login }
      nodes(ids: $ids) {
        ... on PullRequest {
          id
          state
          author { login }
          reviewRequests(first: 20) {
            nodes {
              requestedReviewer {
                ... on User { login }
                ... on Team { name slug organization { login } }
              }
            }
          }
        }
      }
    }
    """#

    static let watchedGraphQLQuery = #"""
    query PRWatcherWatched($owner: String!, $repository: String!, $number: Int!) {
      repository(owner: $owner, name: $repository) {
        pullRequest(number: $number) {
          id
          number
          title
          url
          isDraft
          createdAt
          mergedAt
          updatedAt
          reviewDecision
          mergeable
          mergeStateStatus
          state
          viewerCanClose
          viewerCanUpdate
          viewerCanEnableAutoMerge
          autoMergeRequest { mergeMethod enabledBy { login } }
          author { login }
          repository {
            nameWithOwner
            viewerPermission
            mergeCommitAllowed
            squashMergeAllowed
            rebaseMergeAllowed
          }
          assignees(first: 20) { nodes { login } }
          reviewRequests(first: 20) {
            nodes {
              requestedReviewer {
                ... on User { login }
                ... on Team { name slug organization { login } }
              }
            }
          }
          commits(last: 1) {
            nodes { commit { statusCheckRollup { state } } }
          }
        }
      }
    }
    """#

    static let userProfileGraphQLQuery = #"""
    query PRWatcherUserProfile($login: String!) {
      user(login: $login) {
        login
        name
      }
    }
    """#

    static let pullRequestDetailsGraphQLQuery = #"""
    query PRWatcherDetails($owner: String!, $repository: String!, $number: Int!) {
      repository(owner: $owner, name: $repository) {
        pullRequest(number: $number) {
          isDraft
          reviewDecision
          mergeable
          mergeStateStatus
          state
          reviewRequests(first: 50) {
            nodes {
              requestedReviewer {
                ... on User { login }
                ... on Team { name slug organization { login } }
              }
            }
          }
          latestReviews(first: 50) {
            nodes { state author { login } }
          }
          reviewThreads(first: 100) {
            totalCount
            nodes { isResolved }
          }
          commits(last: 1) {
            nodes {
              commit {
                statusCheckRollup {
                  state
                  contexts(first: 100) {
                    nodes {
                      __typename
                      ... on CheckRun {
                        name
                        status
                        conclusion
                        detailsUrl
                        isRequired(pullRequestNumber: $number)
                      }
                      ... on StatusContext {
                        context
                        state
                        targetUrl
                        isRequired(pullRequestNumber: $number)
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    """#

    static let organizationsGraphQLQuery = #"""
    query PRWatcherOrganizations {
      viewer {
        organizations(first: 100) {
          nodes { login }
        }
      }
    }
    """#

    static let customSearchCountGraphQLQuery = #"""
    query PRWatcherCustomSearchCount($searchQuery: String!) {
      results: search(query: $searchQuery, type: ISSUE, first: 1) {
        issueCount
      }
    }
    """#

    static func graphQLArguments(query: String, count: Int, after: String? = nil) -> [String] {
        var arguments = [
            "api", "graphql",
            "-f", "query=\(graphQLQuery)",
            "-f", "searchQuery=\(query)",
            "-F", "count=\(count)"
        ]
        if let after {
            arguments += ["-f", "after=\(after)"]
        }
        return arguments
    }

    static func customSearchCountArguments(query: String) -> [String] {
        [
            "api", "graphql",
            "-f", "query=\(customSearchCountGraphQLQuery)",
            "-f", "searchQuery=\(query)"
        ]
    }

    private static func fetchSearch(
        executableURL: URL,
        query: String,
        count: Int,
        after: String? = nil,
        logLabel: String? = nil,
        onLog: (@Sendable (PRRefreshLogEvent) -> Void)? = nil
    ) throws -> (viewer: String, nodes: [PRNode], hasNextPage: Bool, endCursor: String?) {
        if let logLabel {
            onLog?(PRRefreshLogEvent(level: .info, message: "Refreshing \(logLabel)…"))
        }
        do {
            let data = try runWithGatewayRetry(
                executableURL: executableURL,
                arguments: graphQLArguments(query: query, count: count, after: after),
                onRetry: { attempt, maximumAttempts in
                    guard let logLabel else { return }
                    onLog?(PRRefreshLogEvent(
                        level: .warning,
                        message: "\(logLabel): gateway error on attempt \(attempt) of \(maximumAttempts); retrying."
                    ))
                }
            )
            let result = try decodeSearch(data)
            if let logLabel {
                onLog?(PRRefreshLogEvent(
                    level: .success,
                    message: "\(logLabel): received \(result.nodes.count) pull request\(result.nodes.count == 1 ? "" : "s")."
                ))
            }
            return result
        } catch {
            if let logLabel {
                let detail = isTransientGatewayError(error.localizedDescription)
                    ? "GitHub gateway error after 3 attempts."
                    : error.localizedDescription
                onLog?(PRRefreshLogEvent(level: .error, message: "\(logLabel): \(detail)"))
            }
            throw error
        }
    }

    private static func fetchReviewRequestedPullRequests(
        executableURL: URL,
        reviewQualifier: String,
        organizationQualifier: String,
        viewerLogin: String,
        includeTeamReviewRequests: Bool,
        cache: DirectReviewRequestCache,
        logLabel: String,
        onLog: (@Sendable (PRRefreshLogEvent) -> Void)?
    ) throws -> (viewer: String, nodes: [PRNode], hasNextPage: Bool, endCursor: String?) {
        let baseQuery = "is:pr is:open \(reviewQualifier) -author:@me archived:false\(organizationQualifier)"

        if includeTeamReviewRequests {
            onLog?(PRRefreshLogEvent(
                level: .info,
                message: "Refreshing \(logLabel) with lightweight REST candidate discovery…"
            ))
            let result = try fetchPullRequestSearchCandidateIDs(
                executableURL: executableURL,
                query: "\(baseQuery) \(reviewRequestRecencyQualifier()) sort:updated-desc",
                maximumCount: 50,
                pageSize: 50,
                logLabel: logLabel,
                onLog: onLog
            )
            let hydrated = try fetchPullRequestNodes(
                executableURL: executableURL,
                ids: result.ids,
                logLabel: logLabel,
                onLog: onLog
            )
            onLog?(PRRefreshLogEvent(
                level: .success,
                message: "\(logLabel): \(result.totalCount) recent candidate\(result.totalCount == 1 ? "" : "s"); hydrated \(hydrated.nodes.count)."
            ))
            return (
                hydrated.viewer.isEmpty ? viewerLogin : hydrated.viewer,
                hydrated.nodes,
                result.nextPage != nil,
                nil
            )
        }

        let now = Date()
        let cacheKey = "\(viewerLogin.lowercased())|\(organizationQualifier.lowercased())"
        let cached = cache.entry(for: cacheKey)
        let reconciliationPage = cached?.reconciliationNextPage ?? 1
        let needsFullReconciliation = cached?.reconciliationNextPage != nil || cached.map {
            now.timeIntervalSince($0.lastFullReconciliationAt) >= 60 * 60
        } ?? true

        var retainedDirectIDs: [String] = []
        if let cached, !cached.pullRequestIDs.isEmpty {
            let existingCandidates = try fetchDirectReviewCandidateNodes(
                executableURL: executableURL,
                ids: cached.pullRequestIDs,
                logLabel: "\(logLabel) — cached direct requests",
                onLog: onLog
            )
            retainedDirectIDs = directReviewRequestIDs(
                from: existingCandidates.nodes,
                viewerLogin: viewerLogin
            )
        }

        let scanQualifier: String
        if needsFullReconciliation {
            scanQualifier = reviewRequestRecencyQualifier(now: now)
        } else {
            let overlapDate = (cached?.lastScanAt ?? now).addingTimeInterval(-5 * 60)
            scanQualifier = "updated:>=\(ISO8601DateFormatter().string(from: overlapDate))"
        }

        let scanKind = needsFullReconciliation
            ? "reconciliation batch \(reconciliationPage)"
            : "incremental scan"
        onLog?(PRRefreshLogEvent(
            level: .info,
            message: "Refreshing \(logLabel) with a \(scanKind)…"
        ))

        let searchResult: (
            ids: [String],
            totalCount: Int,
            incomplete: Bool,
            nextPage: Int?
        )
        do {
            searchResult = try fetchPullRequestSearchCandidateIDs(
                executableURL: executableURL,
                query: "\(baseQuery) \(scanQualifier) sort:updated-desc",
                maximumCount: needsFullReconciliation ? 100 : 200,
                pageSize: 100,
                startingPage: needsFullReconciliation ? reconciliationPage : 1,
                maximumPages: needsFullReconciliation ? 1 : 2,
                logLabel: logLabel,
                onLog: onLog
            )
        } catch {
            guard cached != nil else { throw error }
            onLog?(PRRefreshLogEvent(
                level: .warning,
                message: "\(logLabel): candidate discovery failed; using \(retainedDirectIDs.count) validated cached direct request\(retainedDirectIDs.count == 1 ? "" : "s")."
            ))
            let hydrated = try fetchPullRequestNodes(
                executableURL: executableURL,
                ids: Array(retainedDirectIDs.prefix(50)),
                logLabel: logLabel,
                onLog: onLog
            )
            return (hydrated.viewer.isEmpty ? viewerLogin : hydrated.viewer, hydrated.nodes, false, nil)
        }

        let scannedCandidates = try fetchDirectReviewCandidateNodes(
            executableURL: executableURL,
            ids: searchResult.ids,
            logLabel: "\(logLabel) — candidate classification",
            onLog: onLog
        )
        let scannedDirectIDs = directReviewRequestIDs(
            from: scannedCandidates.nodes,
            viewerLogin: viewerLogin
        )

        var combinedIDs = scannedDirectIDs + retainedDirectIDs
        var seen = Set<String>()
        combinedIDs = combinedIDs.filter { seen.insert($0).inserted }
        let scanWasCapped = searchResult.incomplete || searchResult.nextPage != nil
        let reconciliationContinues = needsFullReconciliation && searchResult.nextPage != nil
        let forceFullReconciliationNextTime = !needsFullReconciliation && scanWasCapped

        cache.set(
            DirectReviewRequestCache.Entry(
                pullRequestIDs: combinedIDs,
                lastScanAt: now,
                lastFullReconciliationAt: forceFullReconciliationNextTime || reconciliationContinues
                    ? .distantPast
                    : needsFullReconciliation
                    ? now
                    : (cached?.lastFullReconciliationAt ?? now),
                reconciliationNextPage: reconciliationContinues
                    ? searchResult.nextPage
                    : forceFullReconciliationNextTime
                    ? 1
                    : nil
            ),
            for: cacheKey
        )

        let classifiedCount = scannedCandidates.nodes.count
        let nonDirectCount = max(classifiedCount - scannedDirectIDs.count, 0)
        let incompleteSuffix: String
        if reconciliationContinues {
            incompleteSuffix = " Remaining candidates will be reconciled during upcoming refreshes."
        } else if forceFullReconciliationNextTime {
            incompleteSuffix = " Candidate results were capped; reconciliation will resume at the next refresh."
        } else if searchResult.incomplete {
            incompleteSuffix = " GitHub marked the search results incomplete; reconciliation will run again in one hour."
        } else {
            incompleteSuffix = ""
        }
        let candidateSuffix = searchResult.totalCount == 1 ? "" : "s"
        onLog?(PRRefreshLogEvent(
            level: .success,
            message: "\(logLabel): \(searchResult.totalCount) candidate\(candidateSuffix), \(scannedDirectIDs.count) direct, \(nonDirectCount) team-only in this \(scanKind).\(incompleteSuffix)"
        ))

        let hydrated = try fetchPullRequestNodes(
            executableURL: executableURL,
            ids: Array(combinedIDs.prefix(50)),
            logLabel: logLabel,
            onLog: onLog
        )
        return (
            hydrated.viewer.isEmpty ? viewerLogin : hydrated.viewer,
            hydrated.nodes,
            combinedIDs.count > 50,
            nil
        )
    }

    private static func fetchPullRequestSearchCandidateIDs(
        executableURL: URL,
        query: String,
        maximumCount: Int,
        pageSize: Int,
        startingPage: Int = 1,
        maximumPages: Int? = nil,
        logLabel: String,
        onLog: (@Sendable (PRRefreshLogEvent) -> Void)?
    ) throws -> (ids: [String], totalCount: Int, incomplete: Bool, nextPage: Int?) {
        var ids: [String] = []
        var seen = Set<String>()
        var page = max(startingPage, 1)
        var processedPages = 0
        var totalCount = 0
        var incomplete = false
        var nextPage: Int?
        let boundedPageSize = min(max(pageSize, 1), 100)

        while ids.count < maximumCount {
            let currentPage = page
            let arguments = [
                "api", "--method", "GET", "search/issues",
                "-f", "q=\(query)",
                "-F", "per_page=\(boundedPageSize)",
                "-F", "page=\(currentPage)"
            ]
            let data = try runWithGatewayRetry(
                executableURL: executableURL,
                arguments: arguments,
                onRetry: { attempt, maximumAttempts in
                    onLog?(PRRefreshLogEvent(
                        level: .warning,
                        message: "\(logLabel) — candidates page \(currentPage): gateway error on attempt \(attempt) of \(maximumAttempts); retrying."
                    ))
                }
            )
            let response = try decodePullRequestSearchCandidates(data)
            totalCount = response.totalCount
            incomplete = incomplete || response.incompleteResults
            processedPages += 1
            for item in response.items where ids.count < maximumCount {
                if seen.insert(item.nodeID).inserted {
                    ids.append(item.nodeID)
                }
            }
            onLog?(PRRefreshLogEvent(
                level: .info,
                message: "\(logLabel) — candidates page \(currentPage): received \(response.items.count)."
            ))
            let hasAnotherPage = !response.items.isEmpty
                && response.items.count == boundedPageSize
                && currentPage * boundedPageSize < totalCount
                && currentPage < 10
            nextPage = hasAnotherPage ? currentPage + 1 : nil
            guard hasAnotherPage,
                  ids.count < maximumCount,
                  maximumPages.map({ processedPages < $0 }) ?? true else { break }
            page += 1
        }
        return (ids, totalCount, incomplete, nextPage)
    }

    private static func fetchDirectReviewCandidateNodes(
        executableURL: URL,
        ids: [String],
        logLabel: String,
        onLog: (@Sendable (PRRefreshLogEvent) -> Void)?
    ) throws -> (viewer: String, nodes: [DirectReviewCandidateNode]) {
        guard !ids.isEmpty else { return ("", []) }
        var viewer = ""
        var nodes: [DirectReviewCandidateNode] = []
        let batches = ids.chunked(into: 50)
        let batchData = try fetchNodeBatchData(
            executableURL: executableURL,
            batches: batches,
            query: directReviewCandidatesGraphQLQuery,
            logLabel: logLabel,
            phase: "classification",
            onLog: onLog
        )
        for (index, data) in batchData.enumerated() {
            let result = try decodeDirectReviewCandidates(data)
            if !result.viewer.isEmpty { viewer = result.viewer }
            nodes.append(contentsOf: result.nodes)
            onLog?(PRRefreshLogEvent(
                level: .info,
                message: "\(logLabel) — batch \(index + 1): classified \(result.nodes.count)."
            ))
        }
        return (viewer, nodes)
    }

    private static func fetchPullRequestNodes(
        executableURL: URL,
        ids: [String],
        logLabel: String,
        onLog: (@Sendable (PRRefreshLogEvent) -> Void)?
    ) throws -> (viewer: String, nodes: [PRNode]) {
        guard !ids.isEmpty else { return ("", []) }
        var viewer = ""
        var nodes: [PRNode] = []
        let batches = ids.chunked(into: 50)
        let batchData = try fetchNodeBatchData(
            executableURL: executableURL,
            batches: batches,
            query: pullRequestNodesGraphQLQuery,
            logLabel: logLabel,
            phase: "hydration",
            onLog: onLog
        )
        for data in batchData {
            let result = try decodePullRequestNodes(data)
            if !result.viewer.isEmpty { viewer = result.viewer }
            nodes.append(contentsOf: result.nodes)
        }
        return (viewer, nodes)
    }

    static func fetchNodeBatchData(
        executableURL: URL,
        batches: [[String]],
        query: String,
        logLabel: String,
        phase: String,
        maximumConcurrentRequests: Int = 3,
        onLog: (@Sendable (PRRefreshLogEvent) -> Void)?
    ) throws -> [Data] {
        guard !batches.isEmpty else { return [] }
        let results = ConcurrentBatchResults(count: batches.count)
        let queue = OperationQueue()
        queue.name = "com.linquist.prwatcher.github.\(phase)"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = min(max(maximumConcurrentRequests, 1), batches.count)

        for (index, batch) in batches.enumerated() {
            queue.addOperation {
                guard !results.hasError else { return }
                do {
                    let data = try runWithGatewayRetry(
                        executableURL: executableURL,
                        arguments: nodeGraphQLArguments(query: query, ids: batch),
                        onRetry: { attempt, maximumAttempts in
                            onLog?(PRRefreshLogEvent(
                                level: .warning,
                                message: "\(logLabel) — \(phase) batch \(index + 1): gateway error on attempt \(attempt) of \(maximumAttempts); retrying."
                            ))
                        }
                    )
                    results.record(data, at: index)
                    onLog?(PRRefreshLogEvent(
                        level: .info,
                        message: "\(logLabel) — \(phase) batch \(index + 1) of \(batches.count): received \(batch.count)."
                    ))
                } catch {
                    results.record(error)
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return try results.resolved()
    }

    static func nodeGraphQLArguments(query: String, ids: [String]) -> [String] {
        var arguments = ["api", "graphql", "-f", "query=\(query)"]
        for id in ids {
            arguments += ["-F", "ids[]=\(id)"]
        }
        return arguments
    }

    static func directReviewRequestIDs(
        from nodes: [DirectReviewCandidateNode],
        viewerLogin: String
    ) -> [String] {
        nodes.compactMap { node in
            guard node.state == "OPEN",
                  node.author?.login.caseInsensitiveCompare(viewerLogin) != .orderedSame else {
                return nil
            }
            let isDirect = node.reviewRequests.nodes
                .compactMap { $0?.requestedReviewer?.login }
                .contains { $0.caseInsensitiveCompare(viewerLogin) == .orderedSame }
            return isDirect ? node.id : nil
        }
    }

    private static func fetchWatchedNode(
        executableURL: URL,
        reference: GitHubPullRequestReference,
        logLabel: String? = nil,
        onLog: (@Sendable (PRRefreshLogEvent) -> Void)? = nil
    ) throws -> PRNode {
        if let logLabel {
            onLog?(PRRefreshLogEvent(level: .info, message: "Refreshing \(logLabel)…"))
        }
        var arguments = ["api", "graphql"]
        if reference.host.lowercased() != "github.com" {
            arguments += ["--hostname", reference.host]
        }
        arguments += [
            "-f", "query=\(watchedGraphQLQuery)",
            "-f", "owner=\(reference.owner)",
            "-f", "repository=\(reference.repository)",
            "-F", "number=\(reference.number)"
        ]
        do {
            let data = try runWithGatewayRetry(
                executableURL: executableURL,
                arguments: arguments,
                onRetry: { attempt, maximumAttempts in
                    guard let logLabel else { return }
                    onLog?(PRRefreshLogEvent(
                        level: .warning,
                        message: "\(logLabel): gateway error on attempt \(attempt) of \(maximumAttempts); retrying."
                    ))
                }
            )
            let node = try decodeWatchedPullRequest(data)
            if let logLabel {
                onLog?(PRRefreshLogEvent(level: .success, message: "\(logLabel): received current status."))
            }
            return node
        } catch {
            if let logLabel {
                let detail = isTransientGatewayError(error.localizedDescription)
                    ? "GitHub gateway error after 3 attempts."
                    : error.localizedDescription
                onLog?(PRRefreshLogEvent(level: .error, message: "\(logLabel): \(detail)"))
            }
            throw error
        }
    }

    static func runWithGatewayRetry(
        executableURL: URL,
        arguments: [String],
        onRetry: (@Sendable (_ failedAttempt: Int, _ maximumAttempts: Int) -> Void)? = nil
    ) throws -> Data {
        let maximumAttempts = 3
        for attempt in 1...maximumAttempts {
            do {
                return try run(executableURL: executableURL, arguments: arguments)
            } catch GitHubClientError.commandFailed(let message) {
                guard isTransientGatewayError(message) else { throw GitHubClientError.commandFailed(message) }
                guard attempt < maximumAttempts else {
                    throw GitHubClientError.commandFailed(
                        "GitHub’s API is temporarily unavailable (HTTP 502/503/504). prWatcher will try again at the next refresh."
                    )
                }
                onRetry?(attempt, maximumAttempts)
                Thread.sleep(forTimeInterval: Double(attempt))
            }
        }
        throw GitHubClientError.commandFailed("GitHub’s API is temporarily unavailable.")
    }

    static func isTransientGatewayError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("http 502")
            || normalized.contains("http 503")
            || normalized.contains("http 504")
            || normalized.contains("bad gateway")
            || normalized.contains("service unavailable")
            || normalized.contains("gateway timeout")
    }

    static func partialRefreshWarning(_ labels: [String]) -> String? {
        let uniqueLabels = Array(Set(labels)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        guard !uniqueLabels.isEmpty else { return nil }
        return "Couldn’t refresh \(uniqueLabels.joined(separator: ", ")). Showing the previous results for those sections."
    }

    private static func logRefreshCompletion(
        _ snapshot: PRSnapshot,
        onLog: (@Sendable (PRRefreshLogEvent) -> Void)?
    ) {
        if let warning = snapshot.refreshWarning {
            onLog?(PRRefreshLogEvent(level: .warning, message: warning))
        }
        onLog?(PRRefreshLogEvent(
            level: snapshot.refreshWarning == nil ? .success : .info,
            message: "Refresh completed with \(snapshot.pullRequests.count) pull request\(snapshot.pullRequests.count == 1 ? "" : "s")."
        ))
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 30
    ) throws -> Data {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let commonPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/local/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [environment["PATH"], commonPaths].compactMap { $0 }.joined(separator: ":")
        process.environment = environment

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        let outputCollector = ProcessPipeCollector()
        let errorCollector = ProcessPipeCollector()
        let readerGroup = DispatchGroup()
        let processFinished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in processFinished.signal() }

        try process.run()

        readerGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputCollector.append(standardOutput.fileHandleForReading.readDataToEndOfFile())
            readerGroup.leave()
        }
        readerGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errorCollector.append(standardError.fileHandleForReading.readDataToEndOfFile())
            readerGroup.leave()
        }

        let didTimeOut = processFinished.wait(timeout: .now() + max(timeout, 0.1)) == .timedOut
        if didTimeOut {
            if process.isRunning {
                process.terminate()
            }
            if processFinished.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = processFinished.wait(timeout: .now() + 2)
            }
        }
        readerGroup.wait()

        if didTimeOut {
            throw GitHubClientError.commandFailed(
                "GitHub request timed out after \(Int(max(timeout, 0.1).rounded())) seconds. prWatcher will try again at the next refresh."
            )
        }

        let output = outputCollector.data()
        let errorData = errorCollector.data()

        guard process.terminationStatus == 0 else {
            let error = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubClientError.commandFailed(error?.isEmpty == false ? error! : "gh exited with code \(process.terminationStatus)")
        }
        return output
    }

    static func decodeSnapshot(_ data: Data) throws -> PRSnapshot {
        let response: GraphQLResponse
        do {
            response = try JSONDecoder().decode(GraphQLResponse.self, from: data)
        } catch {
            throw GitHubClientError.invalidResponse(error.localizedDescription)
        }

        if let message = response.errors?.map(\.message).joined(separator: "\n"), !message.isEmpty {
            throw GitHubClientError.commandFailed(message)
        }
        guard let result = response.data else {
            throw GitHubClientError.invalidResponse("missing data")
        }

        return makeSnapshot(
            viewer: result.viewer.login,
            authored: result.authored.nodes.compactMap { $0 },
            assigned: result.assigned.nodes.compactMap { $0 },
            reviewRequested: result.reviewRequested.nodes.compactMap { $0 },
            merged: result.merged.nodes.compactMap { $0 }
        )
    }

    static func decodeSearch(
        _ data: Data
    ) throws -> (viewer: String, nodes: [PRNode], hasNextPage: Bool, endCursor: String?) {
        let response: SearchGraphQLResponse
        do {
            response = try JSONDecoder().decode(SearchGraphQLResponse.self, from: data)
        } catch {
            throw GitHubClientError.invalidResponse(error.localizedDescription)
        }

        if let message = response.errors?.map(\.message).joined(separator: "\n"), !message.isEmpty {
            throw GitHubClientError.commandFailed(message)
        }
        guard let result = response.data else {
            throw GitHubClientError.invalidResponse("missing data")
        }
        return (
            result.viewer.login,
            result.results.nodes.compactMap { $0 },
            result.results.pageInfo?.hasNextPage ?? false,
            result.results.pageInfo?.endCursor
        )
    }

    static func decodePullRequestNodes(
        _ data: Data
    ) throws -> (viewer: String, nodes: [PRNode]) {
        let response: NodesGraphQLResponse
        do {
            response = try JSONDecoder().decode(NodesGraphQLResponse.self, from: data)
        } catch {
            throw GitHubClientError.invalidResponse(error.localizedDescription)
        }
        if let message = response.errors?.map(\.message).joined(separator: "\n"), !message.isEmpty {
            throw GitHubClientError.commandFailed(message)
        }
        guard let result = response.data else {
            throw GitHubClientError.invalidResponse("missing pull request node data")
        }
        return (result.viewer.login, result.nodes.compactMap { $0 })
    }

    static func decodeDirectReviewCandidates(
        _ data: Data
    ) throws -> (viewer: String, nodes: [DirectReviewCandidateNode]) {
        let response: DirectReviewCandidatesGraphQLResponse
        do {
            response = try JSONDecoder().decode(
                DirectReviewCandidatesGraphQLResponse.self,
                from: data
            )
        } catch {
            throw GitHubClientError.invalidResponse(error.localizedDescription)
        }
        if let message = response.errors?.map(\.message).joined(separator: "\n"), !message.isEmpty {
            throw GitHubClientError.commandFailed(message)
        }
        guard let result = response.data else {
            throw GitHubClientError.invalidResponse("missing direct review candidate data")
        }
        return (result.viewer.login, result.nodes.compactMap { $0 })
    }

    static func decodePullRequestSearchCandidates(
        _ data: Data
    ) throws -> PullRequestSearchRESTResponse {
        do {
            return try JSONDecoder().decode(PullRequestSearchRESTResponse.self, from: data)
        } catch {
            throw GitHubClientError.invalidResponse(error.localizedDescription)
        }
    }

    static func decodeRateLimitStatus(_ data: Data) throws -> GitHubRateLimitStatus {
        let response: RateLimitRESTResponse
        do {
            response = try JSONDecoder().decode(RateLimitRESTResponse.self, from: data)
        } catch {
            throw GitHubClientError.invalidResponse(error.localizedDescription)
        }
        let graphql = response.resources.graphql
        let search = response.resources.search
        return GitHubRateLimitStatus(
            limit: graphql.limit,
            used: graphql.used,
            remaining: graphql.remaining,
            resetAt: Date(timeIntervalSince1970: graphql.reset),
            searchLimit: search.limit,
            searchUsed: search.used,
            searchRemaining: search.remaining,
            searchResetAt: Date(timeIntervalSince1970: search.reset)
        )
    }

    static func decodeCustomSearchCount(_ data: Data) throws -> Int {
        let response: SearchCountGraphQLResponse
        do {
            response = try JSONDecoder().decode(SearchCountGraphQLResponse.self, from: data)
        } catch {
            throw GitHubClientError.invalidResponse(error.localizedDescription)
        }

        if let message = response.errors?.map(\.message).joined(separator: "\n"), !message.isEmpty {
            throw GitHubClientError.commandFailed(message)
        }
        guard let result = response.data else {
            throw GitHubClientError.invalidResponse("missing search count data")
        }
        return result.results.issueCount
    }

    static func decodeOrganizations(_ data: Data) throws -> [String] {
        let response: OrganizationsGraphQLResponse
        do {
            response = try JSONDecoder().decode(OrganizationsGraphQLResponse.self, from: data)
        } catch {
            throw GitHubClientError.invalidResponse(error.localizedDescription)
        }

        if let message = response.errors?.map(\.message).joined(separator: "\n"), !message.isEmpty {
            throw GitHubClientError.commandFailed(message)
        }
        guard let result = response.data else {
            throw GitHubClientError.invalidResponse("missing organization data")
        }
        return result.viewer.organizations.nodes
            .compactMap { $0?.login }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func decodeWatchedPullRequest(_ data: Data) throws -> PRNode {
        let response: WatchedGraphQLResponse
        do {
            response = try JSONDecoder().decode(WatchedGraphQLResponse.self, from: data)
        } catch {
            throw GitHubClientError.invalidResponse(error.localizedDescription)
        }

        if let message = response.errors?.map(\.message).joined(separator: "\n"), !message.isEmpty {
            throw GitHubClientError.commandFailed(message)
        }
        guard let pullRequest = response.data?.repository?.pullRequest else {
            throw GitHubClientError.invalidResponse("Pull request not found or your gh account cannot access it")
        }
        return pullRequest
    }

    static func decodePullRequestDetails(_ data: Data) throws -> PullRequestDetails {
        let response: PullRequestDetailsGraphQLResponse
        do {
            response = try JSONDecoder().decode(PullRequestDetailsGraphQLResponse.self, from: data)
        } catch {
            throw GitHubClientError.invalidResponse(error.localizedDescription)
        }

        if let message = response.errors?.map(\.message).joined(separator: "\n"), !message.isEmpty {
            throw GitHubClientError.commandFailed(message)
        }
        guard let node = response.data?.repository?.pullRequest else {
            throw GitHubClientError.invalidResponse(
                "Pull request details were not found or your gh account cannot access them"
            )
        }

        let requestedReviewers = node.reviewRequests.nodes.compactMap { request -> String? in
            guard let reviewer = request?.requestedReviewer else { return nil }
            if let login = reviewer.login { return "@\(login)" }
            if let slug = reviewer.slug, let organization = reviewer.organization?.login {
                return "@\(organization)/\(slug)"
            }
            return reviewer.name ?? reviewer.slug
        }
        .uniqued()
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let reviews = (node.latestReviews?.nodes ?? []).compactMap { review -> PullRequestReview? in
            guard let review, let login = review.author?.login else { return nil }
            return PullRequestReview(reviewer: login, state: review.state)
        }
        .sorted { $0.reviewer.localizedCaseInsensitiveCompare($1.reviewer) == .orderedAscending }

        let contexts = node.commits.nodes.compactMap { $0 }
            .last?.commit.statusCheckRollup?.contexts?.nodes ?? []
        let checks = contexts.enumerated().compactMap { index, context -> PullRequestCheck? in
            guard let context else { return nil }
            let name = context.name ?? context.context ?? "Unnamed check"
            let status: String
            if context.typeName == "CheckRun" {
                status = context.status == "COMPLETED"
                    ? (context.conclusion ?? context.status ?? "COMPLETED")
                    : (context.status ?? context.conclusion ?? "UNKNOWN")
            } else {
                status = context.state ?? "UNKNOWN"
            }
            return PullRequestCheck(
                id: "\(context.typeName)|\(name)|\(index)",
                name: name,
                status: status,
                isRequired: context.isRequired ?? false,
                detailsURL: context.detailsURL ?? context.targetURL
            )
        }
        .sorted { lhs, rhs in
            if lhs.isRequired != rhs.isRequired { return lhs.isRequired }
            if lhs.isFailing != rhs.isFailing { return lhs.isFailing }
            if lhs.isPending != rhs.isPending { return lhs.isPending }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let reviewThreads = node.reviewThreads?.nodes.compactMap { $0 } ?? []
        let unresolvedThreadCount = reviewThreads.filter { !$0.isResolved }.count
        let totalThreadCount = node.reviewThreads?.totalCount ?? reviewThreads.count
        let rollupState = node.commits.nodes.compactMap { $0 }
            .last?.commit.statusCheckRollup?.state
        let blockerReasons = blockerReasons(
            for: node,
            rollupState: rollupState,
            requestedReviewers: requestedReviewers,
            reviews: reviews,
            checks: checks,
            unresolvedReviewThreadCount: unresolvedThreadCount
        )

        return PullRequestDetails(
            requestedReviewers: requestedReviewers,
            reviews: reviews,
            checks: checks,
            unresolvedReviewThreadCount: unresolvedThreadCount,
            totalReviewThreadCount: totalThreadCount,
            blockerReasons: blockerReasons
        )
    }

    private static func blockerReasons(
        for node: PullRequestDetailsNode,
        rollupState: String?,
        requestedReviewers: [String],
        reviews: [PullRequestReview],
        checks: [PullRequestCheck],
        unresolvedReviewThreadCount: Int
    ) -> [String] {
        var reasons: [String] = []
        if node.state == "CLOSED" { reasons.append("The pull request is closed") }
        if node.isDraft { reasons.append("The pull request is still a draft") }
        if node.mergeable == "CONFLICTING" || node.mergeStateStatus == "DIRTY" {
            reasons.append("Merge conflicts must be resolved")
        }
        if node.mergeStateStatus == "BEHIND" {
            reasons.append("The head branch must be updated with the base branch")
        }

        let requiredFailing = checks.filter { $0.isRequired && $0.isFailing }
        let requiredPending = checks.filter { $0.isRequired && $0.isPending }
        if !requiredFailing.isEmpty {
            reasons.append("Required checks failing: \(requiredFailing.map(\.name).joined(separator: ", "))")
        }
        if !requiredPending.isEmpty {
            reasons.append("Required checks pending: \(requiredPending.map(\.name).joined(separator: ", "))")
        }
        if requiredFailing.isEmpty && requiredPending.isEmpty {
            switch PRClassifier.blockingCIState(
                rollupState: rollupState,
                mergeStateStatus: node.mergeStateStatus
            ) {
            case "FAILURE", "ERROR": reasons.append("One or more required checks are failing")
            case "PENDING", "EXPECTED": reasons.append("Waiting for one or more required checks")
            default: break
            }
        }

        switch node.reviewDecision {
        case "CHANGES_REQUESTED":
            let reviewers = reviews.filter { $0.state == "CHANGES_REQUESTED" }.map { "@\($0.reviewer)" }
            reasons.append(
                reviewers.isEmpty
                    ? "Changes were requested"
                    : "Changes requested by \(reviewers.joined(separator: ", "))"
            )
        case "REVIEW_REQUIRED":
            reasons.append(
                requestedReviewers.isEmpty
                    ? "Waiting for required approval"
                    : "Waiting for review from \(requestedReviewers.joined(separator: ", "))"
            )
        default:
            break
        }

        if unresolvedReviewThreadCount > 0 && node.mergeStateStatus == "BLOCKED" {
            let noun = unresolvedReviewThreadCount == 1 ? "conversation" : "conversations"
            reasons.append("\(unresolvedReviewThreadCount) unresolved review \(noun)")
        }
        if reasons.isEmpty && node.mergeStateStatus == "BLOCKED" {
            reasons.append("A repository rule is currently blocking the merge")
        }
        return reasons.uniqued()
    }

    static func decodeUserProfile(_ data: Data) throws -> GitHubUserProfile {
        let response: UserProfileGraphQLResponse
        do {
            response = try JSONDecoder().decode(UserProfileGraphQLResponse.self, from: data)
        } catch {
            throw GitHubClientError.invalidResponse(error.localizedDescription)
        }

        if let message = response.errors?.map(\.message).joined(separator: "\n"), !message.isEmpty {
            throw GitHubClientError.commandFailed(message)
        }
        guard let user = response.data?.user else {
            throw GitHubClientError.invalidResponse("GitHub user not found")
        }
        return GitHubUserProfile(login: user.login, name: user.name)
    }

    private static func makeSnapshot(
        viewer: String,
        watched: [PRNode] = [],
        authored: [PRNode],
        assigned: [PRNode],
        reviewRequested: [PRNode],
        merged: [PRNode],
        customSectionResults: [CustomPRSectionResult] = [],
        includedSections: Set<PRSection> = Set(PRSection.allCases.filter { $0 != .custom }),
        refreshedSectionsMetadata: Set<PRSection>? = nil,
        refreshedCustomSectionIDsMetadata: Set<UUID>? = nil,
        refreshWarning: String? = nil
    ) -> PRSnapshot {
        var pullRequests: [PullRequest] = []
        var seen = Set<String>()

        for node in watched where includedSections.contains(.watched) {
            guard seen.insert(node.id).inserted else { continue }
            pullRequests.append(makePullRequest(node, viewer: viewer, section: .watched, assignment: nil))
        }

        for node in merged where includedSections.contains(.merged) {
            guard seen.insert(node.id).inserted else { continue }
            pullRequests.append(makePullRequest(node, viewer: viewer, section: .merged, assignment: nil))
        }

        let assignedNodes = assigned + reviewRequested
        for node in assignedNodes where includedSections.contains(.assigned) && node.author?.login != viewer {
            guard seen.insert(node.id).inserted else { continue }
            pullRequests.append(makePullRequest(
                node,
                viewer: viewer,
                section: .assigned,
                assignment: assignment(for: node, viewer: viewer)
            ))
        }

        for node in authored {
            guard seen.insert(node.id).inserted else { continue }
            let state = node.commits.nodes.compactMap { $0 }.last?.commit.statusCheckRollup?.state
            let section = PRClassifier.section(
                isDraft: node.isDraft,
                ciState: state,
                reviewDecision: node.reviewDecision,
                mergeable: node.mergeable,
                mergeStateStatus: node.mergeStateStatus
            )
            guard includedSections.contains(section) else { continue }
            pullRequests.append(makePullRequest(node, viewer: viewer, section: section, assignment: nil))
        }

        return PRSnapshot(
            viewerLogin: viewer,
            pullRequests: pullRequests,
            customSectionResults: customSectionResults,
            refreshedSections: refreshedSectionsMetadata
                ?? Set(PRSection.allCases.filter { $0 != .custom }),
            refreshedCustomSectionIDs: refreshedCustomSectionIDsMetadata,
            refreshWarning: refreshWarning
        )
    }

    private static func makeCustomPullRequests(_ nodes: [PRNode], viewer: String) -> [PullRequest] {
        var seen = Set<String>()
        return nodes.compactMap { node in
            guard seen.insert(node.id).inserted else { return nil }
            return makePullRequest(node, viewer: viewer, section: .custom, assignment: nil)
        }
    }

    private static func assignment(for node: PRNode, viewer: String) -> AssignmentKind {
        let directlyAssigned = node.assignees.nodes.compactMap { $0?.login }.contains(viewer)
        let reviewers = node.reviewRequests.nodes.compactMap { $0?.requestedReviewer }
        let directlyRequested = reviewers.contains { $0.login == viewer }
        if directlyAssigned || directlyRequested { return .direct }

        let teams = reviewers.compactMap { reviewer -> String? in
            guard let slug = reviewer.slug else { return nil }
            if let organization = reviewer.organization?.login {
                return "@\(organization)/\(slug)"
            }
            return reviewer.name ?? slug
        }
        return teams.isEmpty ? .direct : .teams(Array(Set(teams)).sorted())
    }

    private static func makePullRequest(
        _ node: PRNode,
        viewer: String,
        section: PRSection,
        assignment: AssignmentKind?
    ) -> PullRequest {
        let ciState = node.commits.nodes.compactMap { $0 }.last?.commit.statusCheckRollup?.state
        let preferredMergeMethod: PullRequestMergeMethod?
        if node.repository.mergeCommitAllowed != false {
            preferredMergeMethod = .merge
        } else if node.repository.squashMergeAllowed == true {
            preferredMergeMethod = .squash
        } else if node.repository.rebaseMergeAllowed == true {
            preferredMergeMethod = .rebase
        } else {
            preferredMergeMethod = nil
        }
        return PullRequest(
            id: node.id,
            number: node.number,
            title: node.title,
            url: node.url,
            repository: node.repository.nameWithOwner,
            author: node.author?.login ?? "unknown",
            isDraft: node.isDraft,
            createdAt: parseDate(node.createdAt),
            mergedAt: parseDate(node.mergedAt),
            updatedAt: parseDate(node.updatedAt) ?? Date(),
            reviewDecision: node.reviewDecision,
            ciState: ciState,
            mergeable: node.mergeable,
            mergeStateStatus: node.mergeStateStatus,
            state: node.state,
            viewerCanClose: node.viewerCanClose ?? false,
            viewerCanUpdate: node.viewerCanUpdate ?? false,
            viewerCanMerge: node.viewerCanEnableAutoMerge == true
                || Self.permissionAllowsMerging(node.repository.viewerPermission),
            viewerCanEnableAutoMerge: node.viewerCanEnableAutoMerge ?? false,
            autoMergeEnabled: node.autoMergeRequest != nil,
            autoMergeAttribution: node.autoMergeRequest?.enabledBy.map {
                .githubUser($0.login)
            },
            preferredMergeMethod: preferredMergeMethod,
            assignment: assignment,
            section: section
        )
    }

    static func permissionAllowsMerging(_ permission: String?) -> Bool {
        switch permission {
        case "WRITE", "MAINTAIN", "ADMIN":
            return true
        default:
            return false
        }
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension Array {
    func uniqued() -> [Element] where Element: Hashable {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }

    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
