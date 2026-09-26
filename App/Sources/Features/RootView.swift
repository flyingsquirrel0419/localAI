import SwiftUI
import LocalAICore

/// App root after onboarding: Agent (default) | Code | Models.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// Selected tab. Agent is the default; persisted across relaunch so the
    /// user lands where they were. Default value forces Agent on first run.
    @AppStorage("com.localai.workspace.selectedTab") private var selectedTab: Tab = .agent

    enum Tab: Hashable {
        case agent, code, models
    }

    var body: some View {
        RootContentView(
            environment: environment,
            selectedTab: $selectedTab
        )
    }
}

/// Inner view that owns the WorkspaceSelection StateObject. Splitting it out
/// lets us construct StateObject with a non-optional store from the
/// environment (RootView's own init can't read @EnvironmentObject).
private struct RootContentView: View {
    let environment: AppEnvironment
    @Binding var selectedTab: RootView.Tab
    @StateObject private var selection: WorkspaceSelection

    init(environment: AppEnvironment, selectedTab: Binding<RootView.Tab>) {
        self.environment = environment
        _selectedTab = selectedTab
        _selection = StateObject(wrappedValue: WorkspaceSelection(store: environment.workspaceStore))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            AgentTabView(selection: selection)
                .tabItem { Label("Agent", systemImage: "sparkles") }
                .tag(RootView.Tab.agent)
            CodeBrowserTabView(environment: environment, selection: selection)
                .tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag(RootView.Tab.code)
            ModelsView(service: environment.modelService)
                .tabItem { Label("Models", systemImage: "cube") }
                .tag(RootView.Tab.models)
        }
        .tint(DesignSystem.Colors.accent)
        .task {
            await selection.refresh()
        }
        .onChange(of: environment.agentRunner.showDiffRequest) { _, requested in
            if requested {
                selectedTab = .code
                environment.agentRunner.showDiffRequest = false
            }
        }
    }
}

/// Shared workspace-selection state for Agent/Code tabs.
@MainActor
final class WorkspaceSelection: ObservableObject {
    @Published var current: WorkspaceMetadata?
    @Published var all: [WorkspaceMetadata] = []
    @Published var isPickerPresented = false
    @Published var error: UserFacingError?

    private let store: WorkspaceStore

    init(store: WorkspaceStore) {
        self.store = store
    }

    func refresh() async {
        do {
            all = try await store.list()
            if current == nil { current = all.first }
        } catch {
            self.error = UserFacingErrorMapper.map(error)
        }
    }

    func create(name: String) async {
        do {
            let meta = try await store.create(name: name)
            await refresh()
            current = meta
            isPickerPresented = false
        } catch {
            self.error = UserFacingErrorMapper.map(error)
        }
    }

    /// Create a workspace and clone `url` into its repository directory.
    /// `onProgress` receives 0...1 progress during the fetch phase.
    func createByCloning(
        name: String,
        url: URL,
        gitService: Libgit2GitService,
        credentialProvider: GitCredentialProvider
    ) async throws {
        let meta = try await store.create(name: name, repositoryURL: url)
        let directory = try await store.repositoryURL(for: meta.id)
        let credentials = try await credentialProvider.credentials(for: url)
        do {
            try await gitService.clone(url: url, to: directory, branch: nil, credentials: credentials)
        } catch {
            // Roll back the workspace so a failed clone doesn't leave a stub.
            try? await store.delete(id: meta.id, confirm: true)
            throw error
        }
        await refresh()
        current = meta
        isPickerPresented = false
    }

    func open(_ meta: WorkspaceMetadata) async {
        do {
            current = try await store.open(id: meta.id)
            await refresh()
            isPickerPresented = false
        } catch {
            self.error = UserFacingErrorMapper.map(error)
        }
    }

    func delete(_ meta: WorkspaceMetadata) async {
        do {
            try await store.delete(id: meta.id, confirm: true)
            if current?.id == meta.id { current = nil }
            await refresh()
        } catch {
            self.error = UserFacingErrorMapper.map(error)
        }
    }
}

struct WorkspacePickerSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var selection: WorkspaceSelection
    @State private var newName: String = ""
    @State private var cloneURL: String = ""
    @State private var cloneName: String = ""
    @State private var isCloning = false
    @State private var cloneError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("New workspace") {
                    HStack {
                        TextField("Name", text: $newName)
                        Button("Create") {
                            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            newName = ""
                            Task { await selection.create(name: name) }
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("Clone repository") {
                    TextField("https://github.com/owner/repo", text: $cloneURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Workspace name (optional)", text: $cloneName)
                    if isCloning {
                        HStack {
                            ProgressView()
                            Text("Cloning…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Clone") {
                            startClone()
                        }
                        .disabled(parsedCloneURL == nil)
                    }
                    if let cloneError {
                        Text(cloneError)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.destructive)
                    }
                }
                Section("Existing") {
                    if selection.all.isEmpty {
                        Text("No workspaces yet")
                            .foregroundStyle(DesignSystem.Colors.secondaryText)
                    } else {
                        ForEach(selection.all) { meta in
                            Button {
                                Task { await selection.open(meta) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(meta.name)
                                        Text("Opened \(meta.lastOpenedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(DesignSystem.Typography.caption)
                                            .foregroundStyle(DesignSystem.Colors.secondaryText)
                                    }
                                    Spacer()
                                    if selection.current?.id == meta.id {
                                        StatusIcon(.done)
                                    }
                                }
                            }
                            .tint(.primary)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let meta = selection.all[index]
                                Task { await selection.delete(meta) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Workspaces")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { selection.isPickerPresented = false }
                }
            }
        }
    }

    /// Accept https://github.com/owner/repo (with or without trailing `/`, `.git`).
    private var parsedCloneURL: URL? {
        let trimmed = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com",
              url.path.split(separator: "/").count >= 2 else {
            return nil
        }
        return url
    }

    private func startClone() {
        guard let url = parsedCloneURL else { return }
        // Default workspace name = "owner-repo" unless user overrode it.
        let defaultName: String = {
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return url.lastPathComponent }
            let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
            return "\(parts[0])-\(repo)"
        }()
        let name = cloneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultName
            : cloneName.trimmingCharacters(in: .whitespacesAndNewlines)

        isCloning = true
        cloneError = nil
        Task {
            do {
                try await selection.createByCloning(
                    name: name,
                    url: url,
                    gitService: environment.gitService,
                    credentialProvider: environment.gitCredentialProvider
                )
                await MainActor.run {
                    isCloning = false
                    cloneURL = ""
                    cloneName = ""
                }
            } catch {
                await MainActor.run {
                    isCloning = false
                    let uf = UserFacingErrorMapper.map(error)
                    cloneError = "\(uf.title): \(uf.message)"
                }
            }
        }
    }
}

/// Header showing the active workspace with a button to switch/create.
struct WorkspaceHeader: View {
    @ObservedObject var selection: WorkspaceSelection

    var body: some View {
        Button {
            selection.isPickerPresented = true
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "folder")
                Text(selection.current?.name ?? "Select workspace")
                    .font(DesignSystem.Typography.headline)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
            }
            .padding(DesignSystem.Spacing.md)
            .background(DesignSystem.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.card))
        }
        .tint(.primary)
        .padding(.horizontal, DesignSystem.Spacing.md)
    }
}

struct AgentTabView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var selection: WorkspaceSelection

    var body: some View {
        NavigationStack {
            AgentChatView(
                modelService: environment.modelService,
                runner: environment.agentRunner,
                selection: selection
            )
            .background(DesignSystem.Colors.background)
            .navigationTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $selection.isPickerPresented) {
                WorkspacePickerSheet(selection: selection)
            }
            .alert(item: $selection.error) { uf in
                Alert(title: Text(uf.title), message: Text(uf.message), dismissButton: .default(Text("OK")))
            }
        }
    }
}

#Preview {
    RootView().environmentObject(AppEnvironment())
}
