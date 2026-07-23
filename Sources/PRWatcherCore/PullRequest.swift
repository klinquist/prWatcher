import Foundation

public enum PRSection: String, CaseIterable, Codable, Sendable, Identifiable {
    case watched
    case merged
    case assigned
    case readyToMerge
    case waitingForReview
    case waitingForCI
    case failingCI
    case drafts
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .watched: "Watched"
        case .merged: "Merged"
        case .assigned: "Assigned to me"
        case .readyToMerge: "Ready to merge"
        case .waitingForReview: "Waiting for review"
        case .waitingForCI: "Waiting for CI"
        case .failingCI: "Failing CI"
        case .drafts: "Drafts"
        case .custom: "Custom"
        }
    }

    public var symbolName: String {
        switch self {
        case .watched: "eye.fill"
        case .merged: "arrow.triangle.merge"
        case .assigned: "person.crop.circle.badge.checkmark"
        case .readyToMerge: "checkmark.seal.fill"
        case .waitingForReview: "person.2"
        case .waitingForCI: "clock.arrow.circlepath"
        case .failingCI: "xmark.octagon.fill"
        case .drafts: "pencil.and.outline"
        case .custom: "line.3.horizontal.decrease.circle.fill"
        }
    }
}

public enum AssignmentKind: Hashable, Codable, Sendable {
    case direct
    case teams([String])

    public var label: String {
        switch self {
        case .direct:
            return "Directly assigned"
        case .teams(let teams):
            return "Via \(teams.joined(separator: ", "))"
        }
    }
}

public enum PullRequestMergeMethod: String, Hashable, Codable, Sendable {
    case merge
    case squash
    case rebase

    public var ghFlag: String {
        switch self {
        case .merge: "--merge"
        case .squash: "--squash"
        case .rebase: "--rebase"
        }
    }
}

public struct PullRequest: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let number: Int
    public let title: String
    public let url: URL
    public let repository: String
    public let author: String
    public let isDraft: Bool
    public let createdAt: Date?
    public let mergedAt: Date?
    public let updatedAt: Date
    public let reviewDecision: String?
    public let ciState: String?
    public let mergeable: String?
    public let mergeStateStatus: String?
    public let state: String?
    public let viewerCanClose: Bool
    public let viewerCanUpdate: Bool
    public let viewerCanMerge: Bool
    public let viewerCanEnableAutoMerge: Bool
    public let autoMergeEnabled: Bool
    public let preferredMergeMethod: PullRequestMergeMethod?
    public let assignment: AssignmentKind?
    public let section: PRSection

    public init(
        id: String,
        number: Int,
        title: String,
        url: URL,
        repository: String,
        author: String,
        isDraft: Bool,
        createdAt: Date? = nil,
        mergedAt: Date?,
        updatedAt: Date,
        reviewDecision: String?,
        ciState: String?,
        mergeable: String?,
        mergeStateStatus: String? = nil,
        state: String? = nil,
        viewerCanClose: Bool = false,
        viewerCanUpdate: Bool = false,
        viewerCanMerge: Bool = false,
        viewerCanEnableAutoMerge: Bool = false,
        autoMergeEnabled: Bool = false,
        preferredMergeMethod: PullRequestMergeMethod? = .merge,
        assignment: AssignmentKind?,
        section: PRSection
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.url = url
        self.repository = repository
        self.author = author
        self.isDraft = isDraft
        self.createdAt = createdAt
        self.mergedAt = mergedAt
        self.updatedAt = updatedAt
        self.reviewDecision = reviewDecision
        self.ciState = ciState
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.state = state
        self.viewerCanClose = viewerCanClose
        self.viewerCanUpdate = viewerCanUpdate
        self.viewerCanMerge = viewerCanMerge
        self.viewerCanEnableAutoMerge = viewerCanEnableAutoMerge
        self.autoMergeEnabled = autoMergeEnabled
        self.preferredMergeMethod = preferredMergeMethod
        self.assignment = assignment
        self.section = section
    }

    private enum CodingKeys: String, CodingKey {
        case id, number, title, url, repository, author, isDraft, createdAt, mergedAt
        case updatedAt, reviewDecision, ciState, mergeable, mergeStateStatus, state
        case viewerCanClose, viewerCanUpdate, viewerCanMerge, viewerCanEnableAutoMerge
        case autoMergeEnabled, preferredMergeMethod, assignment, section
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(URL.self, forKey: .url)
        repository = try container.decode(String.self, forKey: .repository)
        author = try container.decode(String.self, forKey: .author)
        isDraft = try container.decode(Bool.self, forKey: .isDraft)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        mergedAt = try container.decodeIfPresent(Date.self, forKey: .mergedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        reviewDecision = try container.decodeIfPresent(String.self, forKey: .reviewDecision)
        ciState = try container.decodeIfPresent(String.self, forKey: .ciState)
        mergeable = try container.decodeIfPresent(String.self, forKey: .mergeable)
        mergeStateStatus = try container.decodeIfPresent(String.self, forKey: .mergeStateStatus)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        viewerCanClose = try container.decodeIfPresent(Bool.self, forKey: .viewerCanClose) ?? false
        viewerCanUpdate = try container.decodeIfPresent(Bool.self, forKey: .viewerCanUpdate) ?? false
        viewerCanMerge = try container.decodeIfPresent(Bool.self, forKey: .viewerCanMerge) ?? false
        viewerCanEnableAutoMerge = try container.decodeIfPresent(
            Bool.self,
            forKey: .viewerCanEnableAutoMerge
        ) ?? false
        autoMergeEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoMergeEnabled) ?? false
        preferredMergeMethod = try container.decodeIfPresent(
            PullRequestMergeMethod.self,
            forKey: .preferredMergeMethod
        ) ?? .merge
        assignment = try container.decodeIfPresent(AssignmentKind.self, forKey: .assignment)
        section = try container.decode(PRSection.self, forKey: .section)
    }

    public var stateDetail: String {
        if state == "MERGED" || mergedAt != nil { return "Merged" }
        if state == "CLOSED" { return "Closed" }
        if let assignment { return assignment.label }
        if mergeable == "CONFLICTING" { return "Merge conflict" }
        switch PRClassifier.blockingCIState(
            rollupState: ciState,
            mergeStateStatus: mergeStateStatus
        ) {
        case "FAILURE", "ERROR": return "Checks failing"
        case "PENDING", "EXPECTED": return "Checks running"
        default: break
        }
        switch reviewDecision {
        case "APPROVED": return "Approved"
        case "CHANGES_REQUESTED": return "Changes requested"
        case "REVIEW_REQUIRED": return "Review required"
        default: return isDraft ? "Draft" : "Open"
        }
    }

    public var statusFingerprint: String {
        [
            section.rawValue,
            String(isDraft),
            state ?? "",
            reviewDecision ?? "",
            ciState ?? "",
            mergeable ?? "",
            mergeStateStatus ?? ""
        ]
            .joined(separator: "|")
    }

    public func isWatchedStatusChange(from previousFingerprint: String?) -> Bool {
        section == .watched
            && previousFingerprint != nil
            && previousFingerprint != statusFingerprint
    }

    public func hasNotifiableStatusChange(from previousFingerprint: String?) -> Bool {
        guard let previousFingerprint,
              previousFingerprint != statusFingerprint else { return false }
        let previousSectionRawValue = previousFingerprint
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)
        let previousSection = previousSectionRawValue.flatMap(PRSection.init(rawValue:))

        if section == .watched || section == .custom
            || previousSection == .watched || previousSection == .custom {
            return true
        }
        return previousSection != section
    }

    public var isReadyToMerge: Bool {
        state != "CLOSED"
            && state != "MERGED"
            && mergedAt == nil
            && PRClassifier.section(
                isDraft: isDraft,
                ciState: ciState,
                reviewDecision: reviewDecision,
                mergeable: mergeable,
                mergeStateStatus: mergeStateStatus
            ) == .readyToMerge
    }

    public func becameReadyToMerge(wasReady: Bool) -> Bool {
        !wasReady && isReadyToMerge
    }

    public var mergeWhenReadyBlockerDescription: String? {
        guard !isReadyToMerge else { return nil }
        if state == "MERGED" || mergedAt != nil { return "already merged" }
        if state == "CLOSED" { return "pull request is closed" }
        if isDraft { return "still a draft" }
        if mergeable == "CONFLICTING" { return "merge conflicts must be resolved" }

        switch PRClassifier.blockingCIState(
            rollupState: ciState,
            mergeStateStatus: mergeStateStatus
        ) {
        case "FAILURE", "ERROR":
            return "required CI is failing"
        case "PENDING", "EXPECTED":
            return "waiting for required CI"
        default:
            break
        }

        switch reviewDecision {
        case "CHANGES_REQUESTED":
            return "changes were requested"
        case "APPROVED":
            return "GitHub does not currently report the pull request as merge-ready"
        default:
            return "waiting for approval"
        }
    }

    public var asWatched: PullRequest {
        PullRequest(
            id: id,
            number: number,
            title: title,
            url: url,
            repository: repository,
            author: author,
            isDraft: isDraft,
            createdAt: createdAt,
            mergedAt: mergedAt,
            updatedAt: updatedAt,
            reviewDecision: reviewDecision,
            ciState: ciState,
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            state: state,
            viewerCanClose: viewerCanClose,
            viewerCanUpdate: viewerCanUpdate,
            viewerCanMerge: viewerCanMerge,
            viewerCanEnableAutoMerge: viewerCanEnableAutoMerge,
            autoMergeEnabled: autoMergeEnabled,
            preferredMergeMethod: preferredMergeMethod,
            assignment: nil,
            section: .watched
        )
    }

    public func asMerged(at date: Date = Date()) -> PullRequest {
        PullRequest(
            id: id,
            number: number,
            title: title,
            url: url,
            repository: repository,
            author: author,
            isDraft: false,
            createdAt: createdAt,
            mergedAt: date,
            updatedAt: date,
            reviewDecision: reviewDecision,
            ciState: ciState,
            mergeable: mergeable,
            mergeStateStatus: "CLEAN",
            state: "MERGED",
            viewerCanClose: false,
            viewerCanUpdate: false,
            viewerCanMerge: false,
            viewerCanEnableAutoMerge: false,
            autoMergeEnabled: false,
            preferredMergeMethod: preferredMergeMethod,
            assignment: nil,
            section: .merged
        )
    }
}

public struct PullRequestCheck: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let isRequired: Bool
    public let detailsURL: URL?

    public init(
        id: String,
        name: String,
        status: String,
        isRequired: Bool,
        detailsURL: URL?
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.isRequired = isRequired
        self.detailsURL = detailsURL
    }

    public var isSuccessful: Bool {
        ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(status)
    }

    public var isFailing: Bool {
        [
            "ACTION_REQUIRED", "CANCELLED", "ERROR", "FAILURE", "STALE",
            "STARTUP_FAILURE", "TIMED_OUT",
        ].contains(status)
    }

    public var isPending: Bool {
        !isSuccessful && !isFailing
    }
}

public struct PullRequestReview: Identifiable, Hashable, Sendable {
    public var id: String { "\(reviewer.lowercased())|\(state)" }
    public let reviewer: String
    public let state: String

    public init(reviewer: String, state: String) {
        self.reviewer = reviewer
        self.state = state
    }
}

public struct PullRequestDetails: Hashable, Sendable {
    public let requestedReviewers: [String]
    public let reviews: [PullRequestReview]
    public let checks: [PullRequestCheck]
    public let unresolvedReviewThreadCount: Int
    public let totalReviewThreadCount: Int
    public let blockerReasons: [String]

    public init(
        requestedReviewers: [String],
        reviews: [PullRequestReview],
        checks: [PullRequestCheck],
        unresolvedReviewThreadCount: Int,
        totalReviewThreadCount: Int,
        blockerReasons: [String]
    ) {
        self.requestedReviewers = requestedReviewers
        self.reviews = reviews
        self.checks = checks
        self.unresolvedReviewThreadCount = unresolvedReviewThreadCount
        self.totalReviewThreadCount = totalReviewThreadCount
        self.blockerReasons = blockerReasons
    }
}

public struct GitHubUserProfile: Identifiable, Hashable, Codable, Sendable {
    public var id: String { login.lowercased() }
    public let login: String
    public let name: String?

    public init(login: String, name: String?) {
        self.login = login
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public var displayName: String {
        if let name { return "\(name) (@\(login))" }
        return "@\(login)"
    }
}

public struct GitHubPullRequestReference: Hashable, Sendable {
    public let url: URL
    public let host: String
    public let owner: String
    public let repository: String
    public let number: Int

    public var canonicalURL: URL {
        URL(string: "https://\(host)/\(owner)/\(repository)/pull/\(number)")!
    }

    public init?(url: URL) {
        guard let host = url.host, !host.isEmpty else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 4,
              components[2] == "pull",
              let number = Int(components[3]),
              number > 0 else { return nil }

        self.url = url
        self.host = host
        self.owner = components[0]
        self.repository = components[1]
        self.number = number
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }
}

public struct CustomPRSection: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var query: String
    public var colorHex: String

    public init(
        id: UUID = UUID(),
        name: String,
        query: String,
        colorHex: String = "8B5CF6"
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.colorHex = colorHex
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, query, colorHex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        query = try container.decode(String.self, forKey: .query)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "8B5CF6"
    }
}

public struct CustomPRSectionResult: Sendable {
    public let sectionID: UUID
    public let pullRequests: [PullRequest]

    public init(sectionID: UUID, pullRequests: [PullRequest]) {
        self.sectionID = sectionID
        self.pullRequests = pullRequests
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public struct PRSnapshot: Sendable {
    public let viewerLogin: String
    public let pullRequests: [PullRequest]
    public let customSectionResults: [CustomPRSectionResult]
    public let fetchedAt: Date
    public let refreshedSections: Set<PRSection>
    public let refreshedCustomSectionIDs: Set<UUID>
    public let refreshWarning: String?

    public init(
        viewerLogin: String,
        pullRequests: [PullRequest],
        customSectionResults: [CustomPRSectionResult] = [],
        fetchedAt: Date = Date(),
        refreshedSections: Set<PRSection> = Set(PRSection.allCases.filter { $0 != .custom }),
        refreshedCustomSectionIDs: Set<UUID>? = nil,
        refreshWarning: String? = nil
    ) {
        self.viewerLogin = viewerLogin
        self.pullRequests = pullRequests
        self.customSectionResults = customSectionResults
        self.fetchedAt = fetchedAt
        self.refreshedSections = refreshedSections
        self.refreshedCustomSectionIDs = refreshedCustomSectionIDs
            ?? Set(customSectionResults.map(\.sectionID))
        self.refreshWarning = refreshWarning
    }
}

public enum PRRefreshLogLevel: String, Sendable {
    case info
    case success
    case warning
    case error
}

public struct PRRefreshLogEvent: Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let level: PRRefreshLogLevel
    public let message: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        level: PRRefreshLogLevel,
        message: String
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}

public struct PRFetchUpdate: Sendable {
    public let snapshot: PRSnapshot
    public let refreshedSections: Set<PRSection>
    public let refreshedCustomSectionIDs: Set<UUID>

    public init(
        snapshot: PRSnapshot,
        refreshedSections: Set<PRSection>,
        refreshedCustomSectionIDs: Set<UUID> = []
    ) {
        self.snapshot = snapshot
        self.refreshedSections = refreshedSections
        self.refreshedCustomSectionIDs = refreshedCustomSectionIDs
    }
}

public struct GitHubRateLimitStatus: Sendable, Equatable {
    public let limit: Int
    public let used: Int
    public let remaining: Int
    public let resetAt: Date
    public let searchLimit: Int
    public let searchUsed: Int
    public let searchRemaining: Int
    public let searchResetAt: Date
    public let checkedAt: Date

    public init(
        limit: Int,
        used: Int,
        remaining: Int,
        resetAt: Date,
        searchLimit: Int,
        searchUsed: Int,
        searchRemaining: Int,
        searchResetAt: Date,
        checkedAt: Date = Date()
    ) {
        self.limit = limit
        self.used = used
        self.remaining = remaining
        self.resetAt = resetAt
        self.searchLimit = searchLimit
        self.searchUsed = searchUsed
        self.searchRemaining = searchRemaining
        self.searchResetAt = searchResetAt
        self.checkedAt = checkedAt
    }
}

public enum PollingSleepSchedule {
    public static func isSleeping(
        at date: Date,
        enabled: Bool,
        startMinutes: Int,
        endMinutes: Int,
        calendar inputCalendar: Calendar = .current
    ) -> Bool {
        guard enabled else { return false }
        let start = normalizedMinutes(startMinutes)
        let end = normalizedMinutes(endMinutes)
        guard start != end else { return false }

        var calendar = inputCalendar
        calendar.timeZone = inputCalendar.timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let current = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if start < end {
            return current >= start && current < end
        }
        return current >= start || current < end
    }

    public static func nextWakeDate(
        after date: Date,
        enabled: Bool,
        startMinutes: Int,
        endMinutes: Int,
        calendar inputCalendar: Calendar = .current
    ) -> Date? {
        guard isSleeping(
            at: date,
            enabled: enabled,
            startMinutes: startMinutes,
            endMinutes: endMinutes,
            calendar: inputCalendar
        ) else { return nil }

        var calendar = inputCalendar
        calendar.timeZone = inputCalendar.timeZone
        let end = normalizedMinutes(endMinutes)
        let startOfToday = calendar.startOfDay(for: date)
        for dayOffset in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday),
                  let candidate = calendar.date(byAdding: .minute, value: end, to: day),
                  candidate > date else { continue }
            return candidate
        }
        return nil
    }

    private static func normalizedMinutes(_ minutes: Int) -> Int {
        min(max(minutes, 0), 1_439)
    }
}
