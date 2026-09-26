import SwiftUI
import LocalAICore

/// Renders the diff between ChangeTracker originals and current file contents.
/// Later phases will replace originals with `git diff` output.
struct DiffViewerView: View {
    @ObservedObject var service: CodeService

    @State private var changedFiles: [ChangeTracker.ChangedFile] = []
    @State private var selectedIndex: Int = 0
    @State private var hunks: [DiffHunk] = []
    @State private var showRevertConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            if changedFiles.isEmpty {
                ContentUnavailableView(
                    "No changes",
                    systemImage: "checkmark.circle",
                    description: Text("Edits you save in the editor show up here until you commit them.")
                )
                .frame(maxHeight: .infinity)
            } else {
                topBar
                fileList
                Divider()
                hunkList
            }
        }
        .background(DesignSystem.Colors.background)
        .task { await reload() }
        .alert("Revert file?", isPresented: $showRevertConfirm) {
            Button("Revert", role: .destructive) {
                if changedFiles.indices.contains(selectedIndex) {
                    let path = changedFiles[selectedIndex].relativePath
                    Task {
                        do {
                            try await service.revert(path: path)
                            await reload()
                        } catch {
                            service.error = UserFacingErrorMapper.map(error)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores the file to its contents when first edited in this session.")
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                if selectedIndex > 0 { select(selectedIndex - 1) }
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(selectedIndex <= 0)

            Spacer()

            if changedFiles.indices.contains(selectedIndex) {
                Text(changedFiles[selectedIndex].relativePath)
                    .font(DesignSystem.Typography.code(13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                if selectedIndex < changedFiles.count - 1 { select(selectedIndex + 1) }
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(selectedIndex >= changedFiles.count - 1)

            Button(role: .destructive) {
                showRevertConfirm = true
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(DesignSystem.Colors.cardBackground)
    }

    private var fileList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(Array(changedFiles.enumerated()), id: \.element.id) { index, file in
                    Button {
                        select(index)
                    } label: {
                        Text(file.relativePath)
                            .font(DesignSystem.Typography.code(11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(index == selectedIndex
                                        ? DesignSystem.Colors.accent.opacity(0.2)
                                        : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .tint(.primary)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.xs)
        }
        .background(DesignSystem.Colors.cardBackground.opacity(0.5))
    }

    private var hunkList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                ForEach(Array(hunks.enumerated()), id: \.offset) { _, hunk in
                    HunkView(hunk: hunk)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private func reload() async {
        changedFiles = await service.changedFiles()
        if !changedFiles.indices.contains(selectedIndex) {
            selectedIndex = 0
        }
        if changedFiles.indices.contains(selectedIndex) {
            computeHunks()
        }
    }

    private func select(_ index: Int) {
        selectedIndex = index
        computeHunks()
    }

    private func computeHunks() {
        guard changedFiles.indices.contains(selectedIndex) else { hunks = []; return }
        let file = changedFiles[selectedIndex]
        hunks = LineDiff.diff(old: file.original, new: file.current, context: 3)
    }
}

private struct HunkView: View {
    let hunk: DiffHunk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
                .font(DesignSystem.Typography.code(11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground))
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                DiffLineView(line: line)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
        )
    }
}

private struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(prefix)
                .font(DesignSystem.Typography.code(11, weight: .bold))
                .foregroundStyle(prefixColor)
                .frame(width: 18, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .font(DesignSystem.Typography.code(11))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(backgroundColor)
    }

    private var prefix: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .added: return .green
        case .removed: return .red
        case .context: return .secondary
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .added: return .primary
        case .removed: return .primary
        case .context: return .secondary
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .context: return Color.clear
        }
    }
}
