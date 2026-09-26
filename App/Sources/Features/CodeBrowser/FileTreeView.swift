import SwiftUI
import LocalAICore

/// File tree for the current workspace repository.
/// Lazy: a directory's children are loaded only when expanded.
struct FileTreeView: View {
    @ObservedObject var service: CodeService
    let onSelectFile: (String) -> Void

    @State private var rootChildren: [FileNode] = []
    @State private var expanded: Set<String> = []
    @State private var childrenByPath: [String: [FileNode]] = [:]
    @State private var modifiedPaths: Set<String> = []
    @State private var searchQuery: String = ""
    @State private var searchResults: [FileSearchResult] = []
    @State private var isSearching = false

    @State private var pendingDelete: FileNode?
    @State private var showNewFile = false
    @State private var showNewFolder = false
    @State private var newName: String = ""
    @State private var renameTarget: FileNode?
    @State private var moveTarget: FileNode?
    @State private var moveDestination: String = ""

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if isSearching {
                searchResultsList
            } else {
                treeList
            }
        }
        .task { await refresh() }
        .alert("New file", isPresented: $showNewFile) {
            TextField("path/file.swift", text: $newName)
            Button("Create") { createFile() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("path/folder", text: $newName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("New name", text: $newName)
            Button("Rename") { performRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Move", isPresented: Binding(
            get: { moveTarget != nil },
            set: { if !$0 { moveTarget = nil } }
        )) {
            TextField("New path", text: $moveDestination)
            Button("Move") { performMove() }
            Button("Cancel", role: .cancel) { moveTarget = nil }
        }
        .alert("Delete \(pendingDelete?.name ?? "")?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let node = pendingDelete {
                    do {
                        try service.delete(node.relativePath, recursive: node.isDirectory)
                        Task { await refresh() }
                    } catch {
                        service.error = UserFacingErrorMapper.map(error)
                    }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.isDirectory == true
                 ? "Deletes the folder and everything inside."
                 : "Deletes the file.")
        }
    }

    private var searchField: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search files", text: $searchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(DesignSystem.Typography.code())
                .onSubmit { performSearch() }
                .onChange(of: searchQuery) { _, new in
                    if new.isEmpty {
                        isSearching = false
                        searchResults = []
                    }
                }
            Menu {
                Button { showNewFile = true } label: { Label("New file", systemImage: "doc.badge.plus") }
                Button { showNewFolder = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
                Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(DesignSystem.Colors.accent)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.cardBackground)
    }

    private var searchResultsList: some View {
        List {
            ForEach(searchResults) { result in
                Button {
                    onSelectFile(result.relativePath)
                } label: {
                    Label(result.relativePath, systemImage: "doc")
                        .font(DesignSystem.Typography.code())
                        .foregroundStyle(.primary)
                }
            }
            if searchResults.isEmpty && !searchQuery.isEmpty {
                Text("No matches").foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
    }

    private var treeList: some View {
        List {
            ForEach(rootChildren) { node in
                FileNodeRow(
                    node: node,
                    depth: 0,
                    service: service,
                    expanded: $expanded,
                    childrenByPath: $childrenByPath,
                    modifiedPaths: modifiedPaths,
                    onSelectFile: onSelectFile,
                    onRename: { renameTarget = $0; newName = $0.name },
                    onMove: {
                        moveTarget = $0
                        moveDestination = $0.relativePath
                    },
                    onDelete: { pendingDelete = $0 }
                )
            }
        }
        .listStyle(.plain)
    }

    private func refresh() async {
        do {
            rootChildren = try service.listDirectory(".")
            if let root = service.workspaceRoot {
                modifiedPaths = await service.gitStatusProvider.modifiedPaths(workspace: root)
            }
            let changed = await service.changedFiles()
            modifiedPaths.formUnion(changed.map(\.relativePath))
        } catch {
            service.error = UserFacingErrorMapper.map(error)
        }
    }

    private func performSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let search = service.makeSearch() else { return }
        isSearching = true
        Task {
            do {
                searchResults = try await search.searchFiles(query: q, limit: 200)
            } catch {
                service.error = UserFacingErrorMapper.map(error)
            }
        }
    }

    private func createFile() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try service.createFile(name)
            Task { await refresh() }
        } catch {
            service.error = UserFacingErrorMapper.map(error)
        }
        newName = ""
    }

    private func createFolder() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try service.createDirectory(name)
            Task { await refresh() }
        } catch {
            service.error = UserFacingErrorMapper.map(error)
        }
        newName = ""
    }

    private func performRename() {
        guard let target = renameTarget else { return }
        let parent = (target.relativePath as NSString).deletingLastPathComponent
        let newPath = parent.isEmpty || parent == "."
            ? newName
            : (parent as NSString).appendingPathComponent(newName)
        do {
            try service.move(from: target.relativePath, to: newPath)
            Task { await refresh() }
        } catch {
            service.error = UserFacingErrorMapper.map(error)
        }
        renameTarget = nil
        newName = ""
    }

    private func performMove() {
        guard let target = moveTarget else { return }
        let dest = moveDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else { return }
        do {
            try service.move(from: target.relativePath, to: dest)
            Task { await refresh() }
        } catch {
            service.error = UserFacingErrorMapper.map(error)
        }
        moveTarget = nil
        moveDestination = ""
    }
}

// MARK: - FileNodeRow

struct FileNodeRow: View {
    let node: FileNode
    let depth: Int
    @ObservedObject var service: CodeService
    @Binding var expanded: Set<String>
    @Binding var childrenByPath: [String: [FileNode]]
    let modifiedPaths: Set<String>
    let onSelectFile: (String) -> Void
    let onRename: (FileNode) -> Void
    let onMove: (FileNode) -> Void
    let onDelete: (FileNode) -> Void

    private var isExpanded: Bool { expanded.contains(node.relativePath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if node.isDirectory, isExpanded, let children = childrenByPath[node.relativePath] {
                ForEach(children) { child in
                    FileNodeRow(
                        node: child,
                        depth: depth + 1,
                        service: service,
                        expanded: $expanded,
                        childrenByPath: $childrenByPath,
                        modifiedPaths: modifiedPaths,
                        onSelectFile: onSelectFile,
                        onRename: onRename,
                        onMove: onMove,
                        onDelete: onDelete
                    )
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: node.isDirectory ? (isExpanded ? "folder.fill" : "folder") : iconName(for: node.name))
                .foregroundStyle(node.isDirectory ? DesignSystem.Colors.accent : .secondary)
                .frame(width: 18)
            Text(node.name)
                .font(DesignSystem.Typography.code())
                .foregroundStyle(.primary)
            if modifiedPaths.contains(node.relativePath) {
                Text("M")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DesignSystem.Colors.warning)
            }
            Spacer()
            if node.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDirectory {
                toggle()
            } else {
                onSelectFile(node.relativePath)
            }
        }
        .contextMenu {
            Button { onRename(node) } label: { Label("Rename", systemImage: "pencil") }
            Button { onMove(node) } label: { Label("Move", systemImage: "arrow.right.doc.on.clipboard") }
            Button(role: .destructive) { onDelete(node) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func toggle() {
        if expanded.contains(node.relativePath) {
            expanded.remove(node.relativePath)
        } else {
            expanded.insert(node.relativePath)
            if childrenByPath[node.relativePath] == nil {
                Task {
                    do {
                        let children = try service.listDirectory(node.relativePath)
                        await MainActor.run { childrenByPath[node.relativePath] = children }
                    } catch {
                        await MainActor.run { service.error = UserFacingErrorMapper.map(error) }
                    }
                }
            }
        }
    }

    private func iconName(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "ts", "tsx", "js", "jsx": return "chevron.left.forwardslash.chevron.right"
        case "json": return "curlybraces"
        case "md": return "doc.text"
        case "html": return "globe"
        case "css": return "paintbrush"
        default: return "doc"
        }
    }
}
