import Foundation

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

    public init(executableURL: URL? = nil) throws {
        if let executableURL {
            self.executableURL = executableURL
        } else if let found = Self.findExecutable() {
            self.executableURL = found
        } else {
            throw GitHubClientError.ghNotFound
        }
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

            let authoredSectionOrder: [PRSection] = [
                .failingCI, .readyToMerge, .waitingForCI, .waitingForReview, .drafts
            ]
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
                                authored: authored,
                                assigned: assigned,
                                reviewRequested: reviewRequested,
                                merged: merged,
                                includedSections: includedSections
                            ),
                            refreshedSections: refreshedSections
                        ))
                    }
                } catch where Self.isTransientGatewayError(error.localizedDescription) {
                    failedRefreshLabels.append(PRSection.merged.title)
                }
            }

            if normalizedAuthor != nil {
                let snapshot = Self.makeSnapshot(
                    viewer: viewer,
                    authored: authored,
                    assigned: assigned,
                    reviewRequested: reviewRequested,
                    merged: merged,
                    includedSections: includedSections,
                    refreshedSectionsMetadata: refreshedSections,
                    refreshWarning: Self.partialRefreshWarning(failedRefreshLabels)
                )
                Self.logRefreshCompletion(snapshot, onLog: onLog)
                return snapshot
            }

            if includedSections.contains(.assigned) {
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
                        let reviewResult = try Self.fetchSearchInSmallPages(
                            executableURL: executableURL,
                            query: "is:pr is:open \(reviewQualifier) -author:@me archived:false\(organizationQualifier) sort:updated-desc",
                            maximumCount: 50,
                            pageSize: 10,
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
                    } catch where Self.isTransientGatewayError(error.localizedDescription) {
                        assignedQueriesSucceeded = false
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

            if includedSections.contains(.watched) {
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
        if includeTeamReviewRequests {
            return "review-requested:@me"
        }
        guard let login = normalizedGitHubLogin(viewerLogin) else { return nil }
        return "review-requested:\(login)"
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
        try await runAction(["pr", "merge", pullRequest.url.absoluteString, "--merge"])
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
      state
      viewerCanClose
      viewerCanUpdate
      viewerCanEnableAutoMerge
      author { login }
      repository { nameWithOwner viewerPermission }
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
          state
          viewerCanClose
          viewerCanUpdate
          viewerCanEnableAutoMerge
          author { login }
          repository { nameWithOwner viewerPermission }
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

    private static func fetchSearchInSmallPages(
        executableURL: URL,
        query: String,
        maximumCount: Int,
        pageSize: Int,
        logLabel: String,
        onLog: (@Sendable (PRRefreshLogEvent) -> Void)? = nil
    ) throws -> (viewer: String, nodes: [PRNode], hasNextPage: Bool, endCursor: String?) {
        var viewer = ""
        var nodes: [PRNode] = []
        var seen = Set<String>()
        var cursor: String?
        var hasNextPage = true
        var pageNumber = 1

        while hasNextPage && nodes.count < maximumCount {
            let requestedCount = min(pageSize, maximumCount - nodes.count)
            let page = try fetchSearch(
                executableURL: executableURL,
                query: query,
                count: requestedCount,
                after: cursor,
                logLabel: "\(logLabel) — page \(pageNumber)",
                onLog: onLog
            )
            viewer = page.viewer
            nodes.append(contentsOf: page.nodes.filter { seen.insert($0.id).inserted })
            hasNextPage = page.hasNextPage
            guard hasNextPage, let nextCursor = page.endCursor, nextCursor != cursor else {
                hasNextPage = false
                break
            }
            cursor = nextCursor
            pageNumber += 1
        }

        return (viewer, nodes, hasNextPage, cursor)
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

    static func run(executableURL: URL, arguments: [String]) throws -> Data {
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

        try process.run()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()

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
                mergeable: node.mergeable
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
            state: node.state,
            viewerCanClose: node.viewerCanClose ?? false,
            viewerCanUpdate: node.viewerCanUpdate ?? false,
            viewerCanMerge: node.viewerCanEnableAutoMerge == true
                || Self.permissionAllowsMerging(node.repository.viewerPermission),
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
