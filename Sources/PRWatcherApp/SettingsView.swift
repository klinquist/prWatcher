import AppKit
#if canImport(PRWatcherCore)
import PRWatcherCore
#endif
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: PullRequestStore
    @AppStorage("pollIntervalMinutes") private var pollIntervalMinutes = 3.0
    @AppStorage("selectedOrganization") private var selectedOrganization = ""
    @AppStorage("assignmentScope") private var assignmentScope = "directAndTeam"
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    @State private var newGitHubLogin = ""
    @State private var teamMemberError: String?
    @State private var isAddingTeamMember = false
    @State private var editingCustomSection: CustomPRSection?
    @State private var isEditingSections = false

    var body: some View {
        Form {
            Section("Pull requests") {
                Picker("Organization", selection: $selectedOrganization) {
                    Text("All organizations").tag("")
                    ForEach(organizationChoices, id: \.self) { organization in
                        Text(organization).tag(organization)
                    }
                }

                if store.isLoadingOrganizations {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading organizations…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let error = store.organizationErrorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button("Retry") {
                            Task { await store.refreshOrganizations() }
                        }
                    }
                } else {
                    Text("The selected organization applies globally to you and every monitored teammate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Assigned to me", selection: $assignmentScope) {
                    Text("Direct assignments and reviews").tag("directOnly")
                    Text("Direct + GitHub team reviews").tag("directAndTeam")
                }

                Text(assignmentScope == "directOnly"
                     ? "Shows PRs assigned directly to you or requesting your review directly."
                     : "Also shows PRs requesting review from one of your GitHub teams.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Team members") {
                HStack {
                    TextField("GitHub username", text: $newGitHubLogin)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTeamMember() }
                    Button("Add") { addTeamMember() }
                        .disabled(newGitHubLogin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingTeamMember)
                }

                if isAddingTeamMember {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking up GitHub profile…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let teamMemberError {
                    Text(teamMemberError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                ForEach(store.monitoredUsers) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.name ?? profile.login)
                            if profile.name != nil {
                                Text("@\(profile.login)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            store.removeMonitoredUser(profile)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove @\(profile.login)")
                    }
                }

                if store.monitoredUsers.isEmpty && !isAddingTeamMember {
                    Text("Add teammates by GitHub username. Their profile name will be shown when available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sections") {
                Button {
                    isEditingSections = true
                } label: {
                    Label("Edit Sections", systemImage: "list.bullet")
                }

                Text("Choose which sections appear and set their order. Hidden sections are not requested from GitHub.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom sections") {
                ForEach(store.customSections) { section in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: PRSection.custom.symbolName)
                            .foregroundStyle(Color(prHex: section.colorHex))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.name)
                                .fontWeight(.medium)
                            Text(section.query)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            editingCustomSection = section
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Edit \(section.name)")
                        Button(role: .destructive) {
                            store.removeCustomSection(section)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete \(section.name)")
                    }
                }

                Button {
                    editingCustomSection = CustomPRSection(name: "", query: "")
                } label: {
                    Label("Add Custom Section", systemImage: "plus")
                }

                Text("Custom searches appear only under Me and refresh automatically. A pull request may also appear in a built-in section.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("GitHub polling") {
                HStack {
                    Text("Refresh every")
                    Spacer()
                    Stepper(
                        "\(Int(pollIntervalMinutes)) minutes",
                        value: $pollIntervalMinutes,
                        in: 1...30,
                        step: 1
                    )
                    .frame(width: 170)
                }
                Text("Automatic polling applies only to Me. Teammates are refreshed once when selected or when you press Refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Window") {
                Toggle("Keep window above other apps", isOn: $alwaysOnTop)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 590)
        .task {
            if store.availableOrganizations.isEmpty {
                await store.refreshOrganizations()
            }
        }
        .onChange(of: selectedOrganization) { _, _ in
            store.organizationFilterDidChange()
        }
        .onChange(of: assignmentScope) { _, _ in
            store.assignmentScopeDidChange()
        }
        .onChange(of: pollIntervalMinutes) { _, _ in
            store.configurePolling()
        }
        .sheet(item: $editingCustomSection) { section in
            CustomSectionEditor(
                section: section,
                save: { updatedSection in
                    store.saveCustomSection(updatedSection)
                },
                checkQuery: { query in
                    try await store.customSectionMatchCount(query: query)
                },
                openInGitHub: { query in
                    store.openCustomSectionSearch(query: query)
                }
            )
        }
        .sheet(isPresented: $isEditingSections) {
            EditSectionsView(store: store)
        }
    }

    private var organizationChoices: [String] {
        if selectedOrganization.isEmpty || store.availableOrganizations.contains(selectedOrganization) {
            return store.availableOrganizations
        }
        return ([selectedOrganization] + store.availableOrganizations).sorted()
    }

    private func addTeamMember() {
        guard !isAddingTeamMember else { return }
        isAddingTeamMember = true
        teamMemberError = nil
        Task {
            if let error = await store.addMonitoredUser(newGitHubLogin) {
                teamMemberError = error
            } else {
                newGitHubLogin = ""
            }
            isAddingTeamMember = false
        }
    }
}

private struct EditSectionsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PullRequestStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Edit Sections")
                        .font(.title3.weight(.semibold))
                    Text("Use the arrows to reorder sections. Hidden sections are not polled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            List {
                ForEach(Array(store.sectionPreferences.enumerated()), id: \.element.id) { index, preference in
                    HStack(spacing: 10) {
                        sectionIcon(for: preference)
                            .frame(width: 20)

                        Text(store.sectionName(for: preference))

                        Spacer()

                        Button {
                            store.moveSection(preference, by: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .help("Move up")

                        Button {
                            store.moveSection(preference, by: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == store.sectionPreferences.count - 1)
                        .help("Move down")

                        Toggle("Show", isOn: Binding(
                            get: { preference.isVisible },
                            set: { store.setSectionVisibility(preference, isVisible: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 480, height: 520)
    }

    @ViewBuilder
    private func sectionIcon(for preference: DashboardSectionPreference) -> some View {
        if let section = preference.builtInSection {
            Image(systemName: section.symbolName)
                .foregroundStyle(section.tint)
        } else if let section = store.customSection(for: preference) {
            Image(systemName: PRSection.custom.symbolName)
                .foregroundStyle(Color(prHex: section.colorHex))
        } else {
            Image(systemName: PRSection.custom.symbolName)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CustomSectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let sectionID: UUID
    let save: (CustomPRSection) -> String?
    let checkQuery: (String) async throws -> Int
    let openInGitHub: (String) -> Void
    @State private var name: String
    @State private var query: String
    @State private var color: Color
    @State private var errorMessage: String?
    @State private var isCheckingQuery = false
    @State private var queryCheckMessage: String?
    @State private var queryCheckSucceeded = false

    init(
        section: CustomPRSection,
        save: @escaping (CustomPRSection) -> String?,
        checkQuery: @escaping (String) async throws -> Int,
        openInGitHub: @escaping (String) -> Void
    ) {
        sectionID = section.id
        self.save = save
        self.checkQuery = checkQuery
        self.openInGitHub = openInGitHub
        _name = State(initialValue: section.name)
        _query = State(initialValue: section.query)
        _color = State(initialValue: Color(prHex: section.colorHex))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(name.isEmpty ? "Add Custom Section" : "Edit Custom Section")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Section name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("For example, Web Access reviews", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            ColorPicker("Section color", selection: $color, supportsOpacity: false)

            VStack(alignment: .leading, spacing: 6) {
                Text("GitHub search")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $query)
                    .font(.body.monospaced())
                    .frame(minHeight: 110)
                    .padding(5)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.separator, lineWidth: 1)
                    }
                Text("is:pr is added automatically when omitted. The global organization and selected person are not added to this query.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        validateQuery()
                    } label: {
                        Label("Check Query", systemImage: "checkmark.circle")
                    }
                    .disabled(queryIsEmpty || isCheckingQuery)

                    Button {
                        openInGitHub(query)
                    } label: {
                        Label("Open in GitHub", systemImage: "safari")
                    }
                    .disabled(queryIsEmpty)

                    if isCheckingQuery {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let queryCheckMessage {
                    Text(queryCheckMessage)
                        .font(.caption)
                        .foregroundStyle(queryCheckSucceeded ? Color.green : Color.red)
                }
            }
            .onChange(of: query) { _, _ in
                queryCheckMessage = nil
                queryCheckSucceeded = false
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let section = CustomPRSection(
                        id: sectionID,
                        name: name,
                        query: query,
                        colorHex: color.prHex
                    )
                    if let error = save(section) {
                        errorMessage = error
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || queryIsEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var queryIsEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func validateQuery() {
        guard !queryIsEmpty, !isCheckingQuery else { return }
        isCheckingQuery = true
        queryCheckMessage = nil
        Task {
            do {
                let count = try await checkQuery(query)
                queryCheckMessage = count == 1
                    ? "1 matching pull request"
                    : "\(count) matching pull requests"
                queryCheckSucceeded = true
            } catch {
                queryCheckMessage = error.localizedDescription
                queryCheckSucceeded = false
            }
            isCheckingQuery = false
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

    var prHex: String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "8B5CF6" }
        return String(
            format: "%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}
