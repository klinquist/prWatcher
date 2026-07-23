import AppKit
import Combine
import Foundation
import Network
#if canImport(PRWatcherCore)
import PRWatcherCore
#endif
import UserNotifications

struct DashboardSectionPreference: Identifiable, Hashable, Codable {
    let id: String
    var isVisible: Bool

    var builtInSection: PRSection? {
        guard id.hasPrefix("builtin:") else { return nil }
        return PRSection(rawValue: String(id.dropFirst("builtin:".count)))
    }

    var customSectionID: UUID? {
        guard id.hasPrefix("custom:") else { return nil }
        return UUID(uuidString: String(id.dropFirst("custom:".count)))
    }

    static func builtIn(_ section: PRSection, isVisible: Bool = true) -> Self {
        Self(id: "builtin:\(section.rawValue)", isVisible: isVisible)
    }

    static func custom(_ id: UUID, isVisible: Bool = true) -> Self {
        Self(id: "custom:\(id.uuidString.lowercased())", isVisible: isVisible)
    }
}

private struct MergeWhenReadyRegistration: Codable, Hashable {
    let pullRequestID: String
    let url: URL
    var wasReady: Bool
}

private struct MergeWhenReadyOutcome {
    var mergedPullRequests: [PullRequest] = []
    var errors: [String] = []

    var errorMessage: String? {
        errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
}

@MainActor
final class PullRequestStore: ObservableObject {
    @Published private(set) var pullRequests: [PullRequest] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isOffline = false
    @Published private(set) var viewerLogin: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var availableOrganizations: [String] = []
    @Published private(set) var isLoadingOrganizations = false
    @Published private(set) var watchedURLs: [URL] = []
    @Published private(set) var monitoredUsers: [GitHubUserProfile] = []
    @Published private(set) var customSections: [CustomPRSection] = []
    @Published private(set) var customSectionPullRequests: [UUID: [PullRequest]] = [:]
    @Published private(set) var sectionPreferences: [DashboardSectionPreference] = []
    @Published private(set) var refreshLogEntries: [PRRefreshLogEvent] = []
    @Published private var mergeWhenReadyRegistrations: [String: MergeWhenReadyRegistration] = [:]
    @Published private(set) var selectedUserLogin: String?
    @Published private var unreadPullRequestIDs: [String: Set<String>] = [:]
    @Published var errorMessage: String?
    @Published var organizationErrorMessage: String?

    private var client: GitHubClient?
    private var timer: Timer?
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "com.prwatcher.network-monitor")
    private var hasReceivedNetworkStatus = false
    private var previousStates: [String: String] = [:]
    private var hasLoadedOnce = false
    private var pullRequestCache: [String: [PullRequest]] = [:]
    private var fetchDateCache: [String: Date] = [:]
    private var activeFetchKeys = Set<String>()
    private let meCacheKey = "__me__"
    private var cacheGeneration = 0
    private var knownPullRequestIDs: [String: Set<String>] = [:]
    private var mergeWhenReadyInFlight = Set<String>()

    init() {
        watchedURLs = (UserDefaults.standard.stringArray(forKey: "watchedPullRequestURLs") ?? [])
            .compactMap(URL.init(string:))
        if let data = UserDefaults.standard.data(forKey: "cachedWatchedPullRequests"),
           let cached = try? JSONDecoder().decode([PullRequest].self, from: data) {
            let watchedCanonicalURLs = Set(watchedURLs.compactMap {
                GitHubPullRequestReference(url: $0)?.canonicalURL
            })
            let currentCached = cached.filter {
                $0.section == .watched
                    && GitHubPullRequestReference(url: $0.url)
                        .map { watchedCanonicalURLs.contains($0.canonicalURL) } == true
            }
            pullRequestCache[meCacheKey] = currentCached
            pullRequests = currentCached
        }
        if let data = UserDefaults.standard.data(forKey: "monitoredGitHubUsers"),
           let users = try? JSONDecoder().decode([GitHubUserProfile].self, from: data) {
            monitoredUsers = users
        }
        if let data = UserDefaults.standard.data(forKey: "customPRSections"),
           let sections = try? JSONDecoder().decode([CustomPRSection].self, from: data) {
            customSections = sections
        }
        if let data = UserDefaults.standard.data(forKey: "dashboardSectionPreferences"),
           let preferences = try? JSONDecoder().decode([DashboardSectionPreference].self, from: data) {
            sectionPreferences = preferences
        }
        if let data = UserDefaults.standard.data(forKey: "mergeWhenReadyRegistrations"),
           let registrations = try? JSONDecoder().decode(
               [String: MergeWhenReadyRegistration].self,
               from: data
           ) {
            mergeWhenReadyRegistrations = registrations
        }
        reconcileSectionPreferences()
        if let data = UserDefaults.standard.data(forKey: "knownPullRequestIDs"),
           let known = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            knownPullRequestIDs = known
        }
        if let data = UserDefaults.standard.data(forKey: "unreadPullRequestIDs"),
           let unread = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            unreadPullRequestIDs = unread
        }
        do {
            client = try GitHubClient()
        } catch {
            errorMessage = error.localizedDescription
        }
        configurePolling()
        startNetworkMonitoring()
    }

    deinit {
        timer?.invalidate()
        networkMonitor.cancel()
    }

    func pullRequests(in section: PRSection) -> [PullRequest] {
        pullRequests
            .filter { $0.section == section }
            .sorted { lhs, rhs in
                (lhs.mergedAt ?? lhs.updatedAt) > (rhs.mergedAt ?? rhs.updatedAt)
            }
    }

    func pullRequests(in customSection: CustomPRSection) -> [PullRequest] {
        (customSectionPullRequests[customSection.id] ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var visibleSectionPreferences: [DashboardSectionPreference] {
        sectionPreferences.filter(\.isVisible)
    }

    func customSection(for preference: DashboardSectionPreference) -> CustomPRSection? {
        guard let id = preference.customSectionID else { return nil }
        return customSections.first { $0.id == id }
    }

    func sectionName(for preference: DashboardSectionPreference) -> String {
        if let section = preference.builtInSection { return section.title }
        return customSection(for: preference)?.name ?? "Custom section"
    }

    func setSectionVisibility(_ preference: DashboardSectionPreference, isVisible: Bool) {
        guard let index = sectionPreferences.firstIndex(where: { $0.id == preference.id }),
              sectionPreferences[index].isVisible != isVisible else { return }
        sectionPreferences[index].isVisible = isVisible
        saveSectionPreferences()
        sectionPreferencesDidChange()
    }

    func moveSection(_ preference: DashboardSectionPreference, by offset: Int) {
        guard let index = sectionPreferences.firstIndex(where: { $0.id == preference.id }) else { return }
        let destination = index + offset
        guard sectionPreferences.indices.contains(destination) else { return }
        sectionPreferences.swapAt(index, destination)
        saveSectionPreferences()
    }

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.networkStatusDidChange(isOnline: path.status == .satisfied)
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    private func networkStatusDidChange(isOnline: Bool) {
        let isInitialStatus = !hasReceivedNetworkStatus
        let wasOffline = isOffline
        hasReceivedNetworkStatus = true
        isOffline = !isOnline

        guard isInitialStatus || wasOffline != isOffline else { return }

        if isOffline {
            cacheGeneration += 1
            errorMessage = nil
            organizationErrorMessage = nil
            appendRefreshLog(PRRefreshLogEvent(
                level: .warning,
                message: "Network unavailable. Refresh polling is paused."
            ))
            return
        }

        appendRefreshLog(PRRefreshLogEvent(
            level: .info,
            message: isInitialStatus
                ? "Network available. Starting refresh."
                : "Network restored. Refresh polling resumed."
        ))
        Task {
            await refreshOrganizations()
            await refreshUserWhenAvailable(login: nil)
            if let selectedUserLogin {
                await refreshUserWhenAvailable(login: selectedUserLogin)
            }
        }
    }

    func configurePolling() {
        timer?.invalidate()
        let minutes = max(UserDefaults.standard.double(forKey: "pollIntervalMinutes"), 1)
        let effectiveMinutes = UserDefaults.standard.object(forKey: "pollIntervalMinutes") == nil ? 3 : minutes
        timer = Timer.scheduledTimer(withTimeInterval: effectiveMinutes * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshUser(login: nil)
            }
        }
    }

    func refresh() async {
        guard !isOffline else { return }
        await refreshUser(login: selectedUserLogin)
    }

    private func refreshUser(login requestedUserLogin: String?) async {
        guard !isOffline, let client else { return }
        let key = cacheKey(for: requestedUserLogin)
        let requestedGeneration = cacheGeneration
        guard activeFetchKeys.insert(key).inserted else { return }
        updateRefreshingState()
        defer {
            activeFetchKeys.remove(key)
            updateRefreshingState()
        }

        do {
            let selectedOrganization = UserDefaults.standard.string(forKey: "selectedOrganization")
                .flatMap { $0.isEmpty ? nil : $0 }
            let readTrackingKey = trackingKey(for: requestedUserLogin, organization: selectedOrganization)
            let snapshot = try await client.fetchPullRequests(
                organization: selectedOrganization,
                watchedURLs: requestedUserLogin == nil ? watchedURLs : [],
                authorLogin: requestedUserLogin,
                customSections: requestedUserLogin == nil ? enabledCustomSections : [],
                includedSections: enabledBuiltInSections,
                includeTeamReviewRequests: UserDefaults.standard.string(forKey: "assignmentScope")
                    != "directOnly",
                onLog: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.appendRefreshLog(event)
                    }
                },
                onUpdate: { [weak self] update in
                    await self?.applyPartialUpdate(
                        update,
                        cacheKey: key,
                        readTrackingKey: readTrackingKey,
                        generation: requestedGeneration
                    )
                }
            )
            guard requestedGeneration == cacheGeneration else { return }
            let refreshedPullRequests = filterAssignmentScope(snapshot.pullRequests)
            let refreshedIDs = Set(refreshedPullRequests.map(\.id))
            let retainedPullRequests = (pullRequestCache[key] ?? []).filter {
                !snapshot.refreshedSections.contains($0.section)
                    && !refreshedIDs.contains($0.id)
            }
            let fetchedVisiblePullRequests = reconcileWatchedPullRequests(
                refreshedPullRequests + retainedPullRequests,
                cacheKey: key
            )
            let customPullRequests = snapshot.customSectionResults.flatMap(\.pullRequests)
            let mergeWhenReadyOutcome = await processMergeWhenReady(
                candidates: uniquePullRequests(fetchedVisiblePullRequests + customPullRequests),
                client: client
            )
            let visiblePullRequests = applyingConfirmedMerges(
                mergeWhenReadyOutcome.mergedPullRequests,
                to: fetchedVisiblePullRequests,
                displayedAuthorLogin: requestedUserLogin ?? snapshot.viewerLogin,
                includesWatchedSection: requestedUserLogin == nil
            )
            let mergedIDs = Set(mergeWhenReadyOutcome.mergedPullRequests.map(\.id))
            let completedCustomSectionResults = snapshot.customSectionResults.map { result in
                CustomPRSectionResult(
                    sectionID: result.sectionID,
                    pullRequests: result.pullRequests.filter { !mergedIDs.contains($0.id) }
                )
            }
            if requestedUserLogin != nil, !mergeWhenReadyOutcome.mergedPullRequests.isEmpty {
                pullRequestCache[meCacheKey] = applyingConfirmedMerges(
                    mergeWhenReadyOutcome.mergedPullRequests,
                    to: pullRequestCache[meCacheKey] ?? [],
                    displayedAuthorLogin: snapshot.viewerLogin,
                    includesWatchedSection: true
                )
                saveCachedWatchedPullRequests()
            }
            if requestedUserLogin == nil {
                recordWatchedStatusChangesAsUnread(
                    visiblePullRequests,
                    trackingKey: readTrackingKey
                )
            }
            recordCompletedSnapshot(visiblePullRequests, trackingKey: readTrackingKey)
            if requestedUserLogin == nil {
                recordCompletedCustomSnapshots(
                    completedCustomSectionResults,
                    refreshedSectionIDs: snapshot.refreshedCustomSectionIDs,
                    trackingKey: readTrackingKey
                )
                for sectionID in snapshot.refreshedCustomSectionIDs {
                    customSectionPullRequests.removeValue(forKey: sectionID)
                }
                for result in completedCustomSectionResults {
                    customSectionPullRequests[result.sectionID] = result.pullRequests
                }
                let enabledCustomIDs = Set(enabledCustomSections.map(\.id))
                let trackedPullRequests = uniquePullRequests(
                    visiblePullRequests
                        + customSectionPullRequests
                            .filter { enabledCustomIDs.contains($0.key) }
                            .values
                            .flatMap { $0 }
                )
                if hasLoadedOnce {
                    await notifyAboutChanges(
                        in: trackedPullRequests,
                        excluding: mergedIDs
                    )
                }
                previousStates = Dictionary(uniqueKeysWithValues: trackedPullRequests.map {
                    ($0.id, $0.statusFingerprint)
                })
                hasLoadedOnce = true
            }
            pullRequestCache[key] = visiblePullRequests
            if key == meCacheKey {
                saveCachedWatchedPullRequests()
            }
            fetchDateCache[key] = snapshot.fetchedAt
            if !snapshot.viewerLogin.isEmpty {
                viewerLogin = snapshot.viewerLogin
            }
            if cacheKey(for: selectedUserLogin) == key {
                pullRequests = visiblePullRequests
                lastUpdated = snapshot.fetchedAt
                let combinedError = [mergeWhenReadyOutcome.errorMessage, snapshot.refreshWarning]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                errorMessage = combinedError.isEmpty ? nil : combinedError
            }
        } catch {
            guard requestedGeneration == cacheGeneration, !isOffline else { return }
            appendRefreshLog(PRRefreshLogEvent(
                level: .error,
                message: "Refresh stopped: \(error.localizedDescription)"
            ))
            if cacheKey(for: selectedUserLogin) == key {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyPartialUpdate(
        _ update: PRFetchUpdate,
        cacheKey key: String,
        readTrackingKey: String,
        generation: Int
    ) {
        guard generation == cacheGeneration else { return }
        let existing = pullRequestCache[key] ?? []
        let existingIDs = Set(existing.map(\.id))
        let refreshed = filterAssignmentScope(update.snapshot.pullRequests.filter {
            update.refreshedSections.contains($0.section)
        })
        let newlyArrived = refreshed.filter { !existingIDs.contains($0.id) }
        let combined = reconcileWatchedPullRequests(
            existing + newlyArrived,
            cacheKey: key
        )
        recordNewItems(newlyArrived, trackingKey: readTrackingKey)
        pullRequestCache[key] = combined
        if key == meCacheKey {
            saveCachedWatchedPullRequests()
            for result in update.snapshot.customSectionResults
                where update.refreshedCustomSectionIDs.contains(result.sectionID) {
                let customKey = customTrackingKey(
                    sectionID: result.sectionID,
                    baseTrackingKey: readTrackingKey
                )
                recordNewItems(result.pullRequests, trackingKey: customKey)
                let existingCustom = customSectionPullRequests[result.sectionID] ?? []
                let existingCustomIDs = Set(existingCustom.map(\.id))
                let newlyArrivedCustom = result.pullRequests.filter {
                    !existingCustomIDs.contains($0.id)
                }
                customSectionPullRequests[result.sectionID] = existingCustom + newlyArrivedCustom
            }
        }
        if !update.snapshot.viewerLogin.isEmpty {
            viewerLogin = update.snapshot.viewerLogin
        }

        if cacheKey(for: selectedUserLogin) == key {
            pullRequests = combined
            errorMessage = nil
        }
    }

    func selectUser(login: String?) {
        guard selectedUserLogin != login else { return }
        selectedUserLogin = login
        errorMessage = nil
        let key = cacheKey(for: login)
        pullRequests = pullRequestCache[key] ?? []
        lastUpdated = fetchDateCache[key]
        updateRefreshingState()

        if login != nil || pullRequestCache[key] == nil {
            Task { await refreshUser(login: login) }
        }
    }

    func organizationFilterDidChange() {
        cacheGeneration += 1
        let cachedWatched = cachedWatchedPullRequests
        pullRequestCache.removeAll()
        if !cachedWatched.isEmpty {
            pullRequestCache[meCacheKey] = cachedWatched
        }
        fetchDateCache.removeAll()
        pullRequests = selectedUserLogin == nil ? cachedWatched : []
        lastUpdated = nil
        Task {
            await refreshUserWhenAvailable(login: selectedUserLogin)
            if selectedUserLogin != nil {
                await refreshUserWhenAvailable(login: nil)
            }
        }
    }

    func assignmentScopeDidChange() {
        invalidateMeCache()
        Task { await refreshUserWhenAvailable(login: nil) }
    }

    func addMonitoredUser(_ rawLogin: String) async -> String? {
        guard let client else { return "GitHub CLI is not available." }
        do {
            let profile = try await client.fetchUserProfile(login: rawLogin)
            if profile.login.caseInsensitiveCompare(viewerLogin ?? "") == .orderedSame {
                return "That is your own GitHub account; it is already available as Me."
            }
            guard !monitoredUsers.contains(where: {
                $0.login.caseInsensitiveCompare(profile.login) == .orderedSame
            }) else {
                return "@\(profile.login) is already in your team list."
            }
            monitoredUsers.append(profile)
            monitoredUsers.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            saveMonitoredUsers()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeMonitoredUser(_ profile: GitHubUserProfile) {
        monitoredUsers.removeAll { $0.id == profile.id }
        saveMonitoredUsers()
        if selectedUserLogin?.caseInsensitiveCompare(profile.login) == .orderedSame {
            selectUser(login: nil)
        }
    }

    func saveCustomSection(_ section: CustomPRSection) -> String? {
        let name = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = section.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Enter a section name." }
        guard !query.isEmpty else { return "Enter a GitHub search query." }

        let normalized = CustomPRSection(
            id: section.id,
            name: name,
            query: query,
            colorHex: section.colorHex
        )
        if let index = customSections.firstIndex(where: { $0.id == section.id }) {
            if customSections[index].query != query {
                clearCustomReadTracking(sectionID: section.id)
            }
            customSections[index] = normalized
        } else {
            customSections.append(normalized)
        }
        reconcileSectionPreferences()
        saveCustomSections()
        cacheGeneration += 1
        Task { await refreshUserWhenAvailable(login: nil) }
        return nil
    }

    func customSectionMatchCount(query: String) async throws -> Int {
        guard let client else { throw GitHubClientError.ghNotFound }
        return try await client.customSearchMatchCount(query: query)
    }

    func openCustomSectionSearch(query: String) {
        guard let url = GitHubClient.customSearchURL(query: query) else { return }
        NSWorkspace.shared.open(url)
    }

    func removeCustomSection(_ section: CustomPRSection) {
        customSections.removeAll { $0.id == section.id }
        customSectionPullRequests.removeValue(forKey: section.id)
        clearCustomReadTracking(sectionID: section.id)
        reconcileSectionPreferences()
        saveCustomSections()
        cacheGeneration += 1
        Task { await refreshUserWhenAvailable(login: nil) }
    }

    func refreshOrganizations() async {
        guard !isOffline, !isLoadingOrganizations, let client else { return }
        isLoadingOrganizations = true
        defer { isLoadingOrganizations = false }

        do {
            availableOrganizations = try await client.fetchOrganizations()
            organizationErrorMessage = nil
        } catch {
            if !isOffline {
                organizationErrorMessage = error.localizedDescription
            }
        }
    }

    func addWatch(_ rawURL: String) async -> String? {
        guard !isOffline else { return "You’re offline. Try again when the network is available." }
        guard let reference = GitHubPullRequestReference(string: rawURL) else {
            return "Enter a GitHub pull request URL such as https://github.com/owner/repository/pull/123."
        }
        guard let client else { return "GitHub CLI is not available." }
        let canonicalURL = reference.canonicalURL
        guard !watchedURLs.contains(canonicalURL) else { return "That pull request is already being watched." }

        do {
            let watchedPullRequest = try await client.fetchWatchedPullRequest(url: canonicalURL)
            addToWatchList(watchedPullRequest, canonicalURL: canonicalURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func isWatching(_ pullRequest: PullRequest) -> Bool {
        guard let reference = GitHubPullRequestReference(url: pullRequest.url) else { return false }
        return watchedURLs.contains {
            GitHubPullRequestReference(url: $0)?.canonicalURL == reference.canonicalURL
        }
    }

    func watch(_ pullRequest: PullRequest) {
        guard let reference = GitHubPullRequestReference(url: pullRequest.url),
              !isWatching(pullRequest) else { return }
        addToWatchList(pullRequest, canonicalURL: reference.canonicalURL)

        guard !isOffline, let client else { return }
        Task {
            do {
                let refreshed = try await client.fetchWatchedPullRequest(url: reference.canonicalURL)
                guard isWatching(refreshed) else { return }
                cacheWatchedPullRequest(refreshed)
            } catch {
                guard !isOffline else { return }
                appendRefreshLog(PRRefreshLogEvent(
                    level: .warning,
                    message: "Watched — \(reference.owner)/\(reference.repository)#\(reference.number): \(error.localizedDescription)"
                ))
            }
        }
    }

    func stopWatching(_ pullRequest: PullRequest) {
        guard let reference = GitHubPullRequestReference(url: pullRequest.url) else { return }
        let previousCount = watchedURLs.count
        watchedURLs.removeAll { GitHubPullRequestReference(url: $0)?.canonicalURL == reference.canonicalURL }
        guard watchedURLs.count != previousCount else { return }
        saveWatchedURLs()
        removeWatchedPullRequestFromCache(canonicalURL: reference.canonicalURL)
        previousStates.removeValue(forKey: pullRequest.id)
    }

    func close(_ pullRequest: PullRequest) {
        guard pullRequest.viewerCanClose else { return }
        cancelMergeWhenReady(pullRequest)
        performAction(on: pullRequest) { client, pullRequest in
            try await client.close(pullRequest)
        }
    }

    func markDraft(_ pullRequest: PullRequest) {
        guard pullRequest.viewerCanUpdate else { return }
        performAction(on: pullRequest) { client, pullRequest in
            try await client.markDraft(pullRequest)
        }
    }

    func markReady(_ pullRequest: PullRequest) {
        guard pullRequest.viewerCanUpdate else { return }
        performAction(on: pullRequest) { client, pullRequest in
            try await client.markReady(pullRequest)
        }
    }

    func merge(_ pullRequest: PullRequest) {
        guard pullRequest.viewerCanMerge else { return }
        cancelMergeWhenReady(pullRequest)
        performAction(on: pullRequest) { client, pullRequest in
            try await client.merge(pullRequest)
        }
    }

    func isMergeWhenReadyEnabled(_ pullRequest: PullRequest) -> Bool {
        mergeWhenReadyRegistrations[pullRequest.id] != nil
    }

    func enableMergeWhenReady(_ pullRequest: PullRequest) {
        guard pullRequest.viewerCanMerge,
              !pullRequest.isReadyToMerge,
              pullRequest.state != "CLOSED",
              pullRequest.state != "MERGED",
              pullRequest.mergedAt == nil else { return }
        mergeWhenReadyRegistrations[pullRequest.id] = MergeWhenReadyRegistration(
            pullRequestID: pullRequest.id,
            url: pullRequest.url,
            wasReady: false
        )
        saveMergeWhenReadyRegistrations()
    }

    func cancelMergeWhenReady(_ pullRequest: PullRequest) {
        guard mergeWhenReadyRegistrations.removeValue(forKey: pullRequest.id) != nil else { return }
        saveMergeWhenReadyRegistrations()
    }

    func copyLink(_ pullRequest: PullRequest) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pullRequest.url.absoluteString, forType: .string)
    }

    func open(_ pullRequest: PullRequest) {
        NSWorkspace.shared.open(pullRequest.url)
    }

    func clearRefreshLog() {
        refreshLogEntries.removeAll()
    }

    func copyRefreshLog() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = refreshLogEntries.map {
            "[\(formatter.string(from: $0.date))] [\($0.level.rawValue.uppercased())] \($0.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func isUnread(_ pullRequest: PullRequest, customSectionID: UUID? = nil) -> Bool {
        unreadPullRequestIDs[readTrackingKey(customSectionID: customSectionID), default: []]
            .contains(pullRequest.id)
    }

    func unreadCount(in section: PRSection) -> Int {
        let unread = unreadPullRequestIDs[currentTrackingKey, default: []]
        return pullRequests.filter { $0.section == section && unread.contains($0.id) }.count
    }

    func unreadCount(in customSection: CustomPRSection) -> Int {
        let unread = unreadPullRequestIDs[
            readTrackingKey(customSectionID: customSection.id),
            default: []
        ]
        return pullRequests(in: customSection).filter { unread.contains($0.id) }.count
    }

    func markRead(_ pullRequest: PullRequest, customSectionID: UUID? = nil) {
        let trackingKey = readTrackingKey(customSectionID: customSectionID)
        var unread = unreadPullRequestIDs[trackingKey, default: []]
        guard unread.remove(pullRequest.id) != nil else { return }
        unreadPullRequestIDs[trackingKey] = unread
        saveReadTrackingState()
    }

    private func performAction(
        on pullRequest: PullRequest,
        action: @escaping (GitHubClient, PullRequest) async throws -> Void
    ) {
        guard !isOffline, let client else {
            errorMessage = "You’re offline. This action will be available when the network reconnects."
            return
        }
        Task {
            do {
                try await action(client, pullRequest)
                await refreshUserWhenAvailable(login: selectedUserLogin)
            } catch {
                if !isOffline {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func notifyAboutChanges(
        in newPullRequests: [PullRequest],
        excluding excludedPullRequestIDs: Set<String> = []
    ) async {
        guard AppRuntime.supportsUserNotifications else { return }
        for pullRequest in newPullRequests {
            guard !excludedPullRequestIDs.contains(pullRequest.id) else { continue }
            guard pullRequest.hasNotifiableStatusChange(
                from: previousStates[pullRequest.id]
            ) else { continue }

            let content = UNMutableNotificationContent()
            content.title = "PR status changed"
            content.subtitle = "\(pullRequest.repository)#\(pullRequest.number)"
            content.body = "\(pullRequest.title) \(notificationStatusPhrase(for: pullRequest))"
            content.sound = .default
            content.userInfo = ["url": pullRequest.url.absoluteString]
            let request = UNNotificationRequest(
                identifier: "pr-\(pullRequest.id)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func notificationStatusPhrase(for pullRequest: PullRequest) -> String {
        switch pullRequest.section {
        case .watched, .custom:
            return "is now \(pullRequest.stateDetail.lowercased())."
        case .merged:
            return "was merged."
        case .assigned:
            return "is now assigned to you."
        case .readyToMerge:
            return "is now ready to merge."
        case .waitingForReview:
            return "is now waiting for review."
        case .waitingForCI:
            return "is now waiting for CI."
        case .failingCI:
            return "now has failing CI."
        case .drafts:
            return "is now a draft."
        }
    }

    private func processMergeWhenReady(
        candidates: [PullRequest],
        client: GitHubClient
    ) async -> MergeWhenReadyOutcome {
        guard !mergeWhenReadyRegistrations.isEmpty else { return MergeWhenReadyOutcome() }
        var candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var outcome = MergeWhenReadyOutcome()

        for originalRegistration in Array(mergeWhenReadyRegistrations.values) {
            var pullRequest = candidatesByID[originalRegistration.pullRequestID]
            if pullRequest == nil {
                pullRequest = try? await client.fetchWatchedPullRequest(url: originalRegistration.url)
                if let pullRequest {
                    candidatesByID[pullRequest.id] = pullRequest
                }
            }
            guard let pullRequest else { continue }

            if pullRequest.state == "CLOSED" || pullRequest.state == "MERGED" || pullRequest.mergedAt != nil {
                mergeWhenReadyRegistrations.removeValue(forKey: originalRegistration.pullRequestID)
                continue
            }

            guard pullRequest.viewerCanMerge else {
                mergeWhenReadyRegistrations.removeValue(forKey: originalRegistration.pullRequestID)
                continue
            }

            guard var currentRegistration = mergeWhenReadyRegistrations[originalRegistration.pullRequestID] else {
                continue
            }
            let shouldMerge = pullRequest.becameReadyToMerge(wasReady: currentRegistration.wasReady)
            currentRegistration.wasReady = pullRequest.isReadyToMerge
            mergeWhenReadyRegistrations[originalRegistration.pullRequestID] = currentRegistration
            guard shouldMerge,
                  mergeWhenReadyInFlight.insert(originalRegistration.pullRequestID).inserted else { continue }

            do {
                try await client.merge(pullRequest)
                mergeWhenReadyRegistrations.removeValue(forKey: originalRegistration.pullRequestID)
                outcome.mergedPullRequests.append(pullRequest.asMerged())
                await notifyAutoMerge(of: pullRequest)
            } catch {
                if var currentRegistration = mergeWhenReadyRegistrations[originalRegistration.pullRequestID] {
                    currentRegistration.wasReady = false
                    mergeWhenReadyRegistrations[originalRegistration.pullRequestID] = currentRegistration
                }
                outcome.errors.append("Could not auto-merge \(pullRequest.repository)#\(pullRequest.number): \(error.localizedDescription)")
            }
            mergeWhenReadyInFlight.remove(originalRegistration.pullRequestID)
        }

        saveMergeWhenReadyRegistrations()
        return outcome
    }

    private func notifyAutoMerge(of pullRequest: PullRequest) async {
        guard AppRuntime.supportsUserNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "Pull request auto-merged"
        content.subtitle = "\(pullRequest.repository)#\(pullRequest.number)"
        content.body = pullRequest.title
        content.sound = .default
        content.userInfo = ["url": pullRequest.url.absoluteString]
        let request = UNNotificationRequest(
            identifier: "auto-merge-\(pullRequest.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func saveWatchedURLs() {
        UserDefaults.standard.set(watchedURLs.map(\.absoluteString), forKey: "watchedPullRequestURLs")
    }

    private var cachedWatchedPullRequests: [PullRequest] {
        let watchedCanonicalURLs = Set(watchedURLs.compactMap {
            GitHubPullRequestReference(url: $0)?.canonicalURL
        })
        return (pullRequestCache[meCacheKey] ?? []).filter {
            $0.section == .watched
                && GitHubPullRequestReference(url: $0.url)
                    .map { watchedCanonicalURLs.contains($0.canonicalURL) } == true
        }
    }

    private func saveCachedWatchedPullRequests() {
        guard let data = try? JSONEncoder().encode(cachedWatchedPullRequests) else { return }
        UserDefaults.standard.set(data, forKey: "cachedWatchedPullRequests")
    }

    private func addToWatchList(_ pullRequest: PullRequest, canonicalURL: URL) {
        let selectedOrganization = UserDefaults.standard.string(forKey: "selectedOrganization")
            .flatMap { $0.isEmpty ? nil : $0 }
        markKnown(
            pullRequest.id,
            trackingKey: trackingKey(for: nil, organization: selectedOrganization)
        )
        watchedURLs.append(canonicalURL)
        saveWatchedURLs()
        cacheWatchedPullRequest(pullRequest)
    }

    private func cacheWatchedPullRequest(_ pullRequest: PullRequest) {
        let watchedPullRequest = pullRequest.asWatched
        var cached = pullRequestCache[meCacheKey] ?? []
        cached.removeAll { $0.id == watchedPullRequest.id }
        cached.append(watchedPullRequest)
        pullRequestCache[meCacheKey] = cached
        saveCachedWatchedPullRequests()
        previousStates[watchedPullRequest.id] = watchedPullRequest.statusFingerprint
        if selectedUserLogin == nil {
            pullRequests = cached
        }
    }

    private func removeWatchedPullRequestFromCache(canonicalURL: URL) {
        var cached = pullRequestCache[meCacheKey] ?? []
        cached.removeAll {
            $0.section == .watched
                && GitHubPullRequestReference(url: $0.url)?.canonicalURL == canonicalURL
        }
        pullRequestCache[meCacheKey] = cached
        saveCachedWatchedPullRequests()
        if selectedUserLogin == nil {
            pullRequests = cached
        }
    }

    private func appendRefreshLog(_ event: PRRefreshLogEvent) {
        refreshLogEntries.append(event)
        if refreshLogEntries.count > 500 {
            refreshLogEntries.removeFirst(refreshLogEntries.count - 500)
        }
    }

    private func saveMonitoredUsers() {
        guard let data = try? JSONEncoder().encode(monitoredUsers) else { return }
        UserDefaults.standard.set(data, forKey: "monitoredGitHubUsers")
    }

    private func saveCustomSections() {
        guard let data = try? JSONEncoder().encode(customSections) else { return }
        UserDefaults.standard.set(data, forKey: "customPRSections")
    }

    private func saveSectionPreferences() {
        guard let data = try? JSONEncoder().encode(sectionPreferences) else { return }
        UserDefaults.standard.set(data, forKey: "dashboardSectionPreferences")
    }

    private func saveMergeWhenReadyRegistrations() {
        guard let data = try? JSONEncoder().encode(mergeWhenReadyRegistrations) else { return }
        UserDefaults.standard.set(data, forKey: "mergeWhenReadyRegistrations")
    }

    private func reconcileSectionPreferences() {
        let builtInOrder: [PRSection] = [
            .watched,
            .assigned,
            .failingCI,
            .readyToMerge,
            .waitingForCI,
            .waitingForReview,
            .drafts,
            .merged
        ]
        let builtInPreferences = builtInOrder.map { DashboardSectionPreference.builtIn($0) }
        let customPreferences = customSections.map { DashboardSectionPreference.custom($0.id) }
        let defaultPreferences = [builtInPreferences[0]]
            + customPreferences
            + Array(builtInPreferences.dropFirst())

        guard !sectionPreferences.isEmpty else {
            sectionPreferences = defaultPreferences
            saveSectionPreferences()
            return
        }

        let validIDs = Set(defaultPreferences.map(\.id))
        var seen = Set<String>()
        sectionPreferences = sectionPreferences.filter {
            validIDs.contains($0.id) && seen.insert($0.id).inserted
        }

        for preference in builtInPreferences where !seen.contains(preference.id) {
            sectionPreferences.append(preference)
            seen.insert(preference.id)
        }

        for preference in customPreferences where !seen.contains(preference.id) {
            let lastCustomIndex = sectionPreferences.lastIndex { $0.customSectionID != nil }
            let watchedIndex = sectionPreferences.firstIndex {
                $0.builtInSection == .watched
            }
            let insertionIndex = (lastCustomIndex ?? watchedIndex).map { $0 + 1 } ?? 0
            sectionPreferences.insert(preference, at: insertionIndex)
            seen.insert(preference.id)
        }
        saveSectionPreferences()
    }

    private var enabledBuiltInSections: Set<PRSection> {
        Set(visibleSectionPreferences.compactMap(\.builtInSection))
    }

    private var enabledCustomSections: [CustomPRSection] {
        let enabledIDs = Set(visibleSectionPreferences.compactMap(\.customSectionID))
        return customSections.filter { enabledIDs.contains($0.id) }
    }

    private func sectionPreferencesDidChange() {
        cacheGeneration += 1
        Task {
            await refreshUserWhenAvailable(login: selectedUserLogin)
            if selectedUserLogin != nil {
                await refreshUserWhenAvailable(login: nil)
            }
        }
    }

    private func cacheKey(for login: String?) -> String {
        login?.lowercased() ?? meCacheKey
    }

    private func updateRefreshingState() {
        isRefreshing = activeFetchKeys.contains(cacheKey(for: selectedUserLogin))
    }

    private func invalidateMeCache() {
        let cachedWatched = cachedWatchedPullRequests
        pullRequestCache[meCacheKey] = cachedWatched
        fetchDateCache.removeValue(forKey: meCacheKey)
        if selectedUserLogin == nil {
            pullRequests = cachedWatched
            lastUpdated = nil
        }
    }

    private func refreshUserWhenAvailable(login: String?) async {
        let key = cacheKey(for: login)
        while activeFetchKeys.contains(key) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await refreshUser(login: login)
    }

    private func filterAssignmentScope(_ pullRequests: [PullRequest]) -> [PullRequest] {
        let scope = UserDefaults.standard.string(forKey: "assignmentScope") ?? "directAndTeam"
        guard scope == "directOnly" else { return pullRequests }
        return pullRequests.filter { pullRequest in
            guard pullRequest.section == .assigned else { return true }
            if case .teams = pullRequest.assignment { return false }
            return true
        }
    }

    private func uniquePullRequests(_ pullRequests: [PullRequest]) -> [PullRequest] {
        var seen = Set<String>()
        return pullRequests.filter { seen.insert($0.id).inserted }
    }

    private func applyingConfirmedMerges(
        _ mergedPullRequests: [PullRequest],
        to pullRequests: [PullRequest],
        displayedAuthorLogin: String,
        includesWatchedSection: Bool
    ) -> [PullRequest] {
        guard !mergedPullRequests.isEmpty else { return pullRequests }
        let mergedIDs = Set(mergedPullRequests.map(\.id))
        var updated = pullRequests.filter { !mergedIDs.contains($0.id) }

        for pullRequest in mergedPullRequests {
            if includesWatchedSection && isWatching(pullRequest) {
                updated.append(pullRequest.asWatched)
            } else if enabledBuiltInSections.contains(.merged),
                      pullRequest.author.caseInsensitiveCompare(displayedAuthorLogin) == .orderedSame {
                updated.append(pullRequest)
            }
        }
        return uniquePullRequests(updated)
    }

    private func reconcileWatchedPullRequests(
        _ pullRequests: [PullRequest],
        cacheKey key: String
    ) -> [PullRequest] {
        guard key == meCacheKey else { return uniquePullRequests(pullRequests) }

        let watchedCanonicalURLs = Set(watchedURLs.compactMap {
            GitHubPullRequestReference(url: $0)?.canonicalURL
        })
        let refreshedWatched = pullRequests.filter {
            $0.section == .watched
                && GitHubPullRequestReference(url: $0.url)
                    .map { watchedCanonicalURLs.contains($0.canonicalURL) } == true
        }
        let refreshedWatchedIDs = Set(refreshedWatched.map(\.id))
        let locallyWatched = (pullRequestCache[meCacheKey] ?? []).filter {
            $0.section == .watched
                && !refreshedWatchedIDs.contains($0.id)
                && GitHubPullRequestReference(url: $0.url)
                    .map { watchedCanonicalURLs.contains($0.canonicalURL) } == true
        }
        let watched = refreshedWatched + locallyWatched
        let watchedIDs = Set(watched.map(\.id))
        let remaining = pullRequests.filter {
            $0.section != .watched && !watchedIDs.contains($0.id)
        }
        return uniquePullRequests(watched + remaining)
    }

    private var currentTrackingKey: String {
        let organization = UserDefaults.standard.string(forKey: "selectedOrganization")
            .flatMap { $0.isEmpty ? nil : $0 }
        return trackingKey(for: selectedUserLogin, organization: organization)
    }

    private func trackingKey(for login: String?, organization: String?) -> String {
        "\(cacheKey(for: login))|org:\(organization?.lowercased() ?? "*")"
    }

    private func readTrackingKey(customSectionID: UUID?) -> String {
        guard let customSectionID else { return currentTrackingKey }
        return customTrackingKey(sectionID: customSectionID, baseTrackingKey: currentTrackingKey)
    }

    private func customTrackingKey(sectionID: UUID, baseTrackingKey: String) -> String {
        "\(baseTrackingKey)|custom:\(sectionID.uuidString.lowercased())"
    }

    private func recordNewItems(_ pullRequests: [PullRequest], trackingKey: String) {
        guard let known = knownPullRequestIDs[trackingKey] else { return }
        let newIDs = Set(pullRequests.map(\.id)).subtracting(known)
        guard !newIDs.isEmpty else { return }
        var unread = unreadPullRequestIDs[trackingKey, default: []]
        unread.formUnion(newIDs)
        unreadPullRequestIDs[trackingKey] = unread
        saveReadTrackingState()
    }

    private func recordWatchedStatusChangesAsUnread(
        _ pullRequests: [PullRequest],
        trackingKey: String
    ) {
        let changedIDs = Set(pullRequests.compactMap { pullRequest in
            pullRequest.isWatchedStatusChange(from: previousStates[pullRequest.id])
                ? pullRequest.id
                : nil
        })
        guard !changedIDs.isEmpty else { return }
        unreadPullRequestIDs[trackingKey, default: []].formUnion(changedIDs)
        saveReadTrackingState()
    }

    private func recordCompletedSnapshot(_ pullRequests: [PullRequest], trackingKey: String) {
        let currentIDs = Set(pullRequests.map(\.id))
        if knownPullRequestIDs[trackingKey] == nil {
            knownPullRequestIDs[trackingKey] = currentIDs
        } else {
            recordNewItems(pullRequests, trackingKey: trackingKey)
            knownPullRequestIDs[trackingKey, default: []].formUnion(currentIDs)
        }

        var unread = unreadPullRequestIDs[trackingKey, default: []]
        unread.formIntersection(currentIDs)
        unreadPullRequestIDs[trackingKey] = unread
        saveReadTrackingState()
    }

    private func recordCompletedCustomSnapshots(
        _ results: [CustomPRSectionResult],
        refreshedSectionIDs: Set<UUID>,
        trackingKey: String
    ) {
        let resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.sectionID, $0.pullRequests) })
        for section in enabledCustomSections where refreshedSectionIDs.contains(section.id) {
            recordCompletedSnapshot(
                resultsByID[section.id] ?? [],
                trackingKey: customTrackingKey(
                    sectionID: section.id,
                    baseTrackingKey: trackingKey
                )
            )
        }
    }

    private func clearCustomReadTracking(sectionID: UUID) {
        let suffix = "|custom:\(sectionID.uuidString.lowercased())"
        knownPullRequestIDs = knownPullRequestIDs.filter { !$0.key.hasSuffix(suffix) }
        unreadPullRequestIDs = unreadPullRequestIDs.filter { !$0.key.hasSuffix(suffix) }
        saveReadTrackingState()
    }

    private func markKnown(_ pullRequestID: String, trackingKey: String) {
        knownPullRequestIDs[trackingKey, default: []].insert(pullRequestID)
        saveReadTrackingState()
    }

    private func saveReadTrackingState() {
        if let knownData = try? JSONEncoder().encode(knownPullRequestIDs) {
            UserDefaults.standard.set(knownData, forKey: "knownPullRequestIDs")
        }
        if let unreadData = try? JSONEncoder().encode(unreadPullRequestIDs) {
            UserDefaults.standard.set(unreadData, forKey: "unreadPullRequestIDs")
        }
    }
}
