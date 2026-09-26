import SwiftUI
import LocalAICore

/// App root after onboarding: Agent | Code | Models.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        TabView {
            AgentTabView()
                .tabItem { Label("Agent", systemImage: "sparkles") }
            CodeBrowserTabView(store: environment.workspaceStore)
                .tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
            ModelsView(service: environment.modelService)
                .tabItem { Label("Models", systemImage: "cube") }
        }
        .tint(DesignSystem.Colors.accent)
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
    @ObservedObject var selection: WorkspaceSelection
    @State private var newName: String = ""

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

    var body: some View {
        AgentTabContent(store: environment.workspaceStore, modelService: environment.modelService)
    }
}

private struct AgentTabContent: View {
    let store: WorkspaceStore
    let modelService: ModelService
    @StateObject private var selection: WorkspaceSelection

    init(store: WorkspaceStore, modelService: ModelService) {
        self.store = store
        self.modelService = modelService
        _selection = StateObject(wrappedValue: WorkspaceSelection(store: store))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WorkspaceHeader(selection: selection)
                    .padding(.top, DesignSystem.Spacing.sm)
                AgentChatView(modelService: modelService)
            }
            .background(DesignSystem.Colors.background)
            .navigationTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $selection.isPickerPresented) {
                WorkspacePickerSheet(selection: selection)
            }
            .alert(item: $selection.error) { uf in
                Alert(title: Text(uf.title), message: Text(uf.message), dismissButton: .default(Text("OK")))
            }
            .task { await selection.refresh() }
        }
    }
}

#Preview {
    RootView().environmentObject(AppEnvironment())
}
