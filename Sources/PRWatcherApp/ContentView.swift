import AppKit
#if canImport(PRWatcherCore)
import PRWatcherCore
#endif
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: PullRequestStore
    @Environment(\.openSettings) private var openSettings
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    @AppStorage("collapsedPRSections") private var collapsedSectionStorage = PRSection.merged.rawValue
    @AppStorage("collapsedCustomPRSections") private var collapsedCustomSectionStorage = ""
    @State private var isPresentingWatchSheet = false
    @State private var isPresentingRefreshLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !hasVisiblePullRequests && !store.isRefreshing {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.visibleSectionPreferences) { preference in
                            dashboardSection(preference)
                        }
                    }
                    .padding(10)
                }
            }

            if !store.isOffline, let error = store.errorMessage {
                errorBanner(error)
            }

            refreshStatus
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem {
                Button {
                    isPresentingWatchSheet = true
                } label: {
                    Image(systemName: "eye")
                }
                .accessibilityLabel("Watch a pull request")
                .help("Watch a pull request")
            }
            ToolbarItem {
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh pull requests")
                .disabled(store.isRefreshing || store.isOffline)
            }
        }
        .onAppear { updateWindowLevel() }
        .onChange(of: alwaysOnTop) { _, _ in updateWindowLevel() }
        .sheet(isPresented: $isPresentingWatchSheet) {
            WatchPullRequestView(store: store)
        }
        .sheet(isPresented: $isPresentingRefreshLog) {
            RefreshLogView(store: store)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.gradient)
                Image(systemName: "arrow.triangle.pull")
                    .foregroundStyle(.white)
                    .font(.system(size: 18, weight: .semibold))
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Pull Requests")
                    .font(.headline)
                Group {
                    if store.selectedUserLogin != nil {
                        Text("\(store.pullRequests.count) authored PRs")
                    } else if let login = store.viewerLogin {
                        Text("@\(login) · \(displayedPullRequestCount) tracked")
                    } else {
                        Text("GitHub")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !store.monitoredUsers.isEmpty {
                Picker("Person", selection: selectedUserBinding) {
                    Text(mePickerTitle).tag("")
                    ForEach(store.monitoredUsers) { profile in
                        Text(profile.displayName).tag(profile.login)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 190)
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            if store.isOffline {
                Label("Offline", systemImage: "wifi.slash")
            } else {
                Label("No pull requests", systemImage: "arrow.triangle.pull")
            }
        } description: {
            if store.isOffline {
                Text("Cached pull requests will remain visible. Refreshing resumes automatically when the network reconnects.")
            } else if store.errorMessage == nil {
                Text("No matching GitHub pull requests were found.")
            } else {
                Text("Check the message below, then refresh.")
            }
        } actions: {
            Button("Refresh") { Task { await store.refresh() } }
                .disabled(store.isOffline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedUserBinding: Binding<String> {
        Binding(
            get: { store.selectedUserLogin ?? "" },
            set: { store.selectUser(login: $0.isEmpty ? nil : $0) }
        )
    }

    private var mePickerTitle: String {
        if let login = store.viewerLogin { return "Me (@\(login))" }
        return "Me"
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
            Spacer()
            Button {
                store.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }

    @ViewBuilder
    private var refreshStatus: some View {
        if store.isOffline || store.isRefreshing || store.isPollingSleeping
            || store.lastUpdated != nil || !store.refreshLogEntries.isEmpty {
            Button {
                isPresentingRefreshLog = true
            } label: {
                HStack {
                    Spacer()
                    if store.isOffline {
                        Label("Offline — refresh paused", systemImage: "wifi.slash")
                    } else if store.isRefreshing {
                        Text("Refreshing…")
                    } else if store.isPollingSleeping,
                              let wakeDate = store.nextAutomaticRefreshDate {
                        Label(
                            "Polling asleep until \(wakeDate.formatted(date: .omitted, time: .shortened))",
                            systemImage: "moon.zzz"
                        )
                    } else if let lastUpdated = store.lastUpdated {
                        TimelineView(.periodic(from: lastUpdated, by: 60)) { context in
                            Text("Last updated \(minuteRoundedAge(since: lastUpdated, relativeTo: context.date))")
                        }
                    } else {
                        Text("Refresh details")
                    }
                }
                .contentShape(Rectangle())
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .help("Show refresh log")
        }
    }

    private func binding(for section: PRSection) -> Binding<Bool> {
        Binding(
            get: { collapsedSections.contains(section) },
            set: { collapsed in
                var sections = collapsedSections
                if collapsed {
                    sections.insert(section)
                } else {
                    sections.remove(section)
                }
                collapsedSectionStorage = sections.map(\.rawValue).sorted().joined(separator: ",")
            }
        )
    }

    private var collapsedSections: Set<PRSection> {
        Set(collapsedSectionStorage.split(separator: ",").compactMap { PRSection(rawValue: String($0)) })
    }

    private var displayedPullRequestCount: Int {
        Set(visiblePullRequests.map(\.id)).count
    }

    private var hasVisiblePullRequests: Bool {
        !visiblePullRequests.isEmpty
    }

    private var visiblePullRequests: [PullRequest] {
        store.visibleSectionPreferences.flatMap { preference -> [PullRequest] in
            if let section = preference.builtInSection {
                return store.pullRequests(in: section)
            }
            guard store.selectedUserLogin == nil,
                  let customSection = store.customSection(for: preference) else { return [] }
            return store.pullRequests(in: customSection)
        }
    }

    @ViewBuilder
    private func dashboardSection(_ preference: DashboardSectionPreference) -> some View {
        if let section = preference.builtInSection {
            let pullRequests = store.pullRequests(in: section)
            if !pullRequests.isEmpty {
                PRSectionView(
                    title: section.title,
                    symbolName: section.symbolName,
                    tint: section.tint,
                    unreadCount: store.unreadCount(in: section),
                    pullRequests: pullRequests,
                    isCollapsed: binding(for: section),
                    store: store,
                    customSectionID: nil
                )
            }
        } else if store.selectedUserLogin == nil,
                  let section = store.customSection(for: preference) {
            let pullRequests = store.pullRequests(in: section)
            if !pullRequests.isEmpty {
                PRSectionView(
                    title: section.name,
                    symbolName: PRSection.custom.symbolName,
                    tint: Color(prHex: section.colorHex),
                    unreadCount: store.unreadCount(in: section),
                    pullRequests: pullRequests,
                    isCollapsed: binding(for: section),
                    store: store,
                    customSectionID: section.id
                )
            }
        }
    }

    private func binding(for section: CustomPRSection) -> Binding<Bool> {
        Binding(
            get: { collapsedCustomSections.contains(section.id) },
            set: { collapsed in
                var sections = collapsedCustomSections
                if collapsed {
                    sections.insert(section.id)
                } else {
                    sections.remove(section.id)
                }
                collapsedCustomSectionStorage = sections
                    .map(\.uuidString)
                    .sorted()
                    .joined(separator: ",")
            }
        )
    }

    private var collapsedCustomSections: Set<UUID> {
        Set(collapsedCustomSectionStorage.split(separator: ",").compactMap {
            UUID(uuidString: String($0))
        })
    }

    private func updateWindowLevel() {
        DispatchQueue.main.async {
            NSApplication.shared.keyWindow?.level = alwaysOnTop ? .floating : .normal
        }
    }
}

private struct RefreshLogView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PullRequestStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Refresh Log")
                        .font(.title3.weight(.semibold))
                    Text("Live details from this launch. The newest entry is at the bottom.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") { store.copyRefreshLog() }
                    .disabled(store.refreshLogEntries.isEmpty)
                Button("Clear") { store.clearRefreshLog() }
                    .disabled(store.refreshLogEntries.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if store.refreshLogEntries.isEmpty {
                ContentUnavailableView(
                    "No refresh activity yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Press Refresh to populate this log.")
                )
            } else {
                ScrollViewReader { proxy in
                    List(store.refreshLogEntries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Image(systemName: symbolName(for: entry.level))
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 16)
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .leading)
                            Text(entry.message)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                        .id(entry.id)
                    }
                    .onAppear { scrollToBottom(using: proxy) }
                    .onChange(of: store.refreshLogEntries.count) { _, _ in
                        scrollToBottom(using: proxy)
                    }
                }
            }
        }
        .frame(width: 700, height: 520)
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        guard let id = store.refreshLogEntries.last?.id else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    private func symbolName(for level: PRRefreshLogLevel) -> String {
        switch level {
        case .info: "circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(for level: PRRefreshLogLevel) -> Color {
        switch level {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct PRSectionView: View {
    let title: String
    let symbolName: String
    let tint: Color
    let unreadCount: Int
    let pullRequests: [PullRequest]
    @Binding var isCollapsed: Bool
    @ObservedObject var store: PullRequestStore
    let customSectionID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isCollapsed.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Image(systemName: symbolName)
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if isCollapsed && unreadCount > 0 {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("\(unreadCount) new pull requests")
                    }
                    Spacer()
                    Text("\(pullRequests.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                VStack(spacing: 1) {
                    ForEach(pullRequests) { pullRequest in
                        PullRequestRow(
                            pullRequest: pullRequest,
                            store: store,
                            customSectionID: customSectionID,
                            tint: tint
                        )
                    }
                }
                .padding(.bottom, 5)
            }
        }
        .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.5), lineWidth: 0.5)
        }
    }
}

private struct PullRequestRow: View {
    let pullRequest: PullRequest
    @ObservedObject var store: PullRequestStore
    let customSectionID: UUID?
    let tint: Color
    @State private var isConfirmingMerge = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if store.isUnread(pullRequest, customSectionID: customSectionID) {
                    store.markRead(pullRequest, customSectionID: customSectionID)
                }
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
                if isExpanded {
                    Task { await store.loadDetails(for: pullRequest) }
                }
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    Circle()
                        .fill(tint.opacity(0.18))
                        .frame(width: 28, height: 28)
                        .overlay {
                            Text(String(pullRequest.author.prefix(1)).uppercased())
                                .font(.caption.bold())
                                .foregroundStyle(tint)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(pullRequest.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                            if store.isUnread(pullRequest, customSectionID: customSectionID) {
                                Text("NEW")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                            }
                        }

                        HStack(spacing: 5) {
                            Text(pullRequest.repository)
                                .lineLimit(1)
                            Text("#\(pullRequest.number)")
                            Text("·")
                            Text(pullRequest.stateDetail)
                                .lineLimit(1)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                        if let createdAt = pullRequest.createdAt {
                            TimelineView(.periodic(from: createdAt, by: 60)) { context in
                                Text(
                                    "Opened \(minuteRoundedAge(since: createdAt, relativeTo: context.date))"
                                        + (shouldShowAuthor ? " by @\(pullRequest.author)" : "")
                                )
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        } else if shouldShowAuthor {
                            Text("By @\(pullRequest.author)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        if store.isMergeWhenReadyEnabled(pullRequest) {
                            Label(
                                store.usesPollingForMergeWhenReady(pullRequest)
                                    ? "AUTO-MERGE · POLLING"
                                    : "AUTO-MERGE ENABLED",
                                systemImage: store.usesPollingForMergeWhenReady(pullRequest)
                                    ? "arrow.triangle.2.circlepath"
                                    : "bolt.fill"
                            )
                                .font(.caption2.bold())
                                .foregroundStyle(Color.orange)
                                .help(
                                    store.usesPollingForMergeWhenReady(pullRequest)
                                        ? "GitHub native auto-merge is unavailable; prWatcher will poll and merge when ready."
                                        : "GitHub is responsible for merging this pull request when its requirements pass."
                                )
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .padding(.top, 6)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                PullRequestDetailsView(pullRequest: pullRequest, store: store)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if pullRequest.isReadyToMerge && pullRequest.viewerCanMerge {
                HStack {
                    Spacer()
                    Button {
                        isConfirmingMerge = true
                    } label: {
                        Label("Merge", systemImage: "arrow.triangle.merge")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .background(
            store.isUnread(pullRequest, customSectionID: customSectionID)
                ? Color.accentColor.opacity(0.08)
                : Color.clear
        )
        .contextMenu {
            Button("Open in Browser") { store.open(pullRequest) }
            Button("Copy GitHub Link") { store.copyLink(pullRequest) }
            if store.isUnread(pullRequest, customSectionID: customSectionID) {
                Button("Mark as Read") {
                    store.markRead(pullRequest, customSectionID: customSectionID)
                }
            }
            Divider()
            if store.isWatching(pullRequest) {
                Button("Stop Watching", role: .destructive) {
                    store.stopWatching(pullRequest)
                }
            } else {
                Button("Watch This PR") {
                    store.watch(pullRequest)
                }
            }
            if isOpen && hasManageActions {
                Divider()
                if store.isMergeWhenReadyEnabled(pullRequest) {
                    Button("Cancel Auto-Merge") {
                        store.cancelMergeWhenReady(pullRequest)
                    }
                } else if pullRequest.viewerCanMerge && !pullRequest.isReadyToMerge {
                    Button("Enable Auto-Merge") {
                        store.enableMergeWhenReady(pullRequest)
                    }
                }
                if pullRequest.viewerCanUpdate {
                    if pullRequest.isDraft {
                        Button("Mark Ready for Review") { store.markReady(pullRequest) }
                    } else {
                        Button("Convert to Draft") { store.markDraft(pullRequest) }
                    }
                }
                if pullRequest.viewerCanClose {
                    if hasNonCloseManageActions {
                        Divider()
                    }
                    Button("Close Pull Request", role: .destructive) { store.close(pullRequest) }
                }
            }
        }
        .confirmationDialog(
            "Merge \(pullRequest.repository)#\(pullRequest.number)?",
            isPresented: $isConfirmingMerge
        ) {
            Button("Merge Pull Request") { store.merge(pullRequest) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will create a merge commit on GitHub and cannot be undone from prWatcher.")
        }
    }

    private var isOpen: Bool {
        pullRequest.state != "CLOSED"
            && pullRequest.state != "MERGED"
            && pullRequest.mergedAt == nil
    }

    private var shouldShowAuthor: Bool {
        guard let viewerLogin = store.viewerLogin, !viewerLogin.isEmpty else { return true }
        return pullRequest.author.caseInsensitiveCompare(viewerLogin) != .orderedSame
    }

    private var hasManageActions: Bool {
        hasNonCloseManageActions || pullRequest.viewerCanClose
    }

    private var hasNonCloseManageActions: Bool {
        store.isMergeWhenReadyEnabled(pullRequest)
            || (pullRequest.viewerCanMerge && !pullRequest.isReadyToMerge)
            || pullRequest.viewerCanUpdate
    }
}

private struct PullRequestDetailsView: View {
    let pullRequest: PullRequest
    @ObservedObject var store: PullRequestStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            if store.detailLoadingIDs.contains(pullRequest.id) {
                Label("Loading blockers and checks…", systemImage: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = store.detailErrors[pullRequest.id] {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Try Again") {
                        Task { await store.loadDetails(for: pullRequest, force: true) }
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
            } else if let details = store.pullRequestDetails[pullRequest.id] {
                detailsContent(details)
            } else {
                Button("Load details") {
                    Task { await store.loadDetails(for: pullRequest) }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(.horizontal, 47)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func detailsContent(_ details: PullRequestDetails) -> some View {
        detailHeading("Why blocked", systemImage: "exclamationmark.lock.fill")
        if details.blockerReasons.isEmpty {
            detailLine(
                "No current blockers detected",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        } else {
            ForEach(details.blockerReasons, id: \.self) { reason in
                detailLine(reason, systemImage: "exclamationmark.circle.fill", color: .orange)
            }
        }

        if !details.requestedReviewers.isEmpty || !details.reviews.isEmpty
            || details.totalReviewThreadCount > 0 {
            detailHeading("Reviews", systemImage: "person.2.fill")
            if !details.requestedReviewers.isEmpty {
                detailLine(
                    "Requested: \(details.requestedReviewers.joined(separator: ", "))",
                    systemImage: "person.crop.circle.badge.clock",
                    color: .secondary
                )
            }
            ForEach(details.reviews) { review in
                detailLine(
                    "@\(review.reviewer): \(displayStatus(review.state))",
                    systemImage: reviewSymbol(review.state),
                    color: reviewColor(review.state)
                )
            }
            if details.totalReviewThreadCount > 0 {
                detailLine(
                    "\(details.unresolvedReviewThreadCount) of \(details.totalReviewThreadCount) review conversations unresolved",
                    systemImage: details.unresolvedReviewThreadCount == 0
                        ? "checkmark.bubble.fill"
                        : "bubble.left.and.exclamationmark.bubble.right.fill",
                    color: details.unresolvedReviewThreadCount == 0 ? .green : .orange
                )
            }
        }

        detailHeading("CI checks", systemImage: "checklist")
        if details.checks.isEmpty {
            detailLine("No checks reported", systemImage: "minus.circle", color: .secondary)
        } else {
            ForEach(details.checks) { check in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: checkSymbol(check))
                        .foregroundStyle(checkColor(check))
                        .frame(width: 14)
                    Text(check.name)
                        .lineLimit(2)
                    if check.isRequired {
                        Text("REQUIRED")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    Text(displayStatus(check.status))
                        .foregroundStyle(.secondary)
                    if let url = check.detailsURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.plain)
                        .help("Open this check on GitHub")
                    }
                }
                .font(.caption2)
            }
        }

        Button {
            Task { await store.loadDetails(for: pullRequest, force: true) }
        } label: {
            Label("Refresh details", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.link)
        .font(.caption2)
    }

    private func detailHeading(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.top, 2)
    }

    private func detailLine(_ text: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .font(.caption2)
    }

    private func displayStatus(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").lowercased().capitalized
    }

    private func checkSymbol(_ check: PullRequestCheck) -> String {
        if check.isSuccessful { return "checkmark.circle.fill" }
        if check.isFailing { return "xmark.octagon.fill" }
        return "clock.fill"
    }

    private func checkColor(_ check: PullRequestCheck) -> Color {
        if check.isSuccessful { return .green }
        if check.isFailing { return .red }
        return .orange
    }

    private func reviewSymbol(_ state: String) -> String {
        switch state {
        case "APPROVED": "checkmark.circle.fill"
        case "CHANGES_REQUESTED": "exclamationmark.circle.fill"
        default: "text.bubble.fill"
        }
    }

    private func reviewColor(_ state: String) -> Color {
        switch state {
        case "APPROVED": .green
        case "CHANGES_REQUESTED": .orange
        default: .secondary
        }
    }
}

private func minuteRoundedAge(since date: Date, relativeTo now: Date) -> String {
    let elapsedMinutes = max(0, Int(now.timeIntervalSince(date) / 60))
    guard elapsedMinutes > 0 else { return "less than a minute ago" }

    let roundedDate = now.addingTimeInterval(-Double(elapsedMinutes * 60))
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .numeric
    formatter.unitsStyle = .full
    return formatter.localizedString(for: roundedDate, relativeTo: now)
}

extension PRSection {
    var tint: Color {
        switch self {
        case .watched: .cyan
        case .merged: .purple
        case .assigned: .blue
        case .readyToMerge: .green
        case .waitingForReview: .indigo
        case .waitingForCI: .orange
        case .failingCI: .red
        case .drafts: .gray
        case .custom: .purple
        }
    }
}

private extension Color {
    init(prHex: String) {
        let normalized = prHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        guard normalized.count == 6, Scanner(string: normalized).scanHexInt64(&value) else {
            self = .purple
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

private struct WatchPullRequestView: View {
    @ObservedObject var store: PullRequestStore
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var errorMessage: String?
    @State private var isAdding = false
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Watch a Pull Request")
                    .font(.title2.weight(.semibold))
                Text("Paste a GitHub pull request URL to keep its status in the Watched section.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                TextField("https://github.com/owner/repository/pull/123", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isURLFieldFocused)
                    .onSubmit { addWatch() }
                Button("Paste") {
                    if let value = NSPasteboard.general.string(forType: .string) {
                        urlText = value
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Watch") { addWatch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
            }
        }
        .padding(22)
        .frame(width: 520)
        .overlay {
            if isAdding {
                ZStack {
                    Color.black.opacity(0.08)
                    ProgressView("Checking pull request…")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .onAppear { isURLFieldFocused = true }
    }

    private func addWatch() {
        guard !isAdding else { return }
        isAdding = true
        errorMessage = nil
        Task {
            if let error = await store.addWatch(urlText) {
                errorMessage = error
                isAdding = false
            } else {
                dismiss()
            }
        }
    }
}
