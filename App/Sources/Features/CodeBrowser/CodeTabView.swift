import SwiftUI
import LocalAICore

/// Code tab: top bar pattern `‹ src      router.ts      ⋯` with file tree,
/// editor, and diff viewer. Tree is on the left when there's horizontal room
/// (iPad / landscape), pushed as a sheet on iPhone portrait.
struct CodeBrowserTabView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var selection: WorkspaceSelection
    @StateObject private var service: CodeService

    @State private var selectedFile: String?
    @State private var mode: Mode = .files

    enum Mode: String, CaseIterable, Identifiable {
        case files = "Files"
        case diff = "Diff"
        var id: String { rawValue }
    }

    init(store: WorkspaceStore) {
        _selection = StateObject(wrappedValue: WorkspaceSelection(store: store))
        _service = StateObject(wrappedValue: CodeService(workspaceStore: store))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WorkspaceHeader(selection: selection)
                    .padding(.top, DesignSystem.Spacing.sm)
                if selection.current == nil {
                    Spacer()
                    ContentUnavailableView(
                        "No workspace",
                        systemImage: "folder.badge.questionmark",
                        description: Text("Create or select a workspace to browse files.")
                    )
                    Spacer()
                } else {
                    modePicker
                    Group {
                        switch mode {
                        case .files:
                            fileStack
                        case .diff:
                            DiffViewerView(service: service)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(DesignSystem.Colors.background)
            .navigationTitle("Code")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $selection.isPickerPresented) {
                WorkspacePickerSheet(selection: selection)
            }
            .alert(item: $service.error) { uf in
                Alert(title: Text(uf.title), message: Text(uf.message), dismissButton: .default(Text("OK")))
            }
            .task {
                await selection.refresh()
                await attachToCurrent()
            }
            .onChange(of: selection.current?.id) { _, _ in
                Task { await attachToCurrent() }
            }
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(Mode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
    }

    private var fileStack: some View {
        Group {
            if let file = selectedFile {
                // Editor view with back to tree
                VStack(spacing: 0) {
                    editorTopBar(file)
                    CodeEditorView(path: file, service: service)
                }
            } else {
                FileTreeView(service: service) { path in
                    selectedFile = path
                }
            }
        }
    }

    private func editorTopBar(_ file: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Button {
                selectedFile = nil
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .tint(DesignSystem.Colors.accent)
            .accessibilityLabel("Back to files")

            let parent = (file as NSString).deletingLastPathComponent
            let name = (file as NSString).lastPathComponent
            Text(parent.isEmpty || parent == "." ? "src" : (parent as NSString).lastPathComponent)
                .foregroundStyle(.secondary)
                .font(DesignSystem.Typography.code(13))
            Spacer()
            Text(name)
                .font(DesignSystem.Typography.code(13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Menu {
                Button {
                    mode = .diff
                } label: { Label("View diff", systemImage: "arrow.left.arrow.right") }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(DesignSystem.Colors.cardBackground)
    }

    private func attachToCurrent() async {
        if let id = selection.current?.id {
            await service.attach(workspaceID: id)
            selectedFile = nil
        } else {
            service.detach()
        }
    }
}
