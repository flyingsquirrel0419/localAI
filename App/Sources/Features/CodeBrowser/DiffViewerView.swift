import SwiftUI
import LocalAICore

/// Renders what's changed in the workspace. In a git repo, the source of
/// truth is `git diff` (HEAD vs worktree); otherwise we fall back to the
/// per-session ChangeTracker snapshots.
struct DiffViewerView: View {
    @ObservedObject var service: CodeService

    @State private var mode: Source = .loading
    @State private var changedFiles: [ChangeTracker.ChangedFile] = []
    @State private var gitUnified: String = ""
    @State private var gitFiles: [GitFileStatus] = []
    @State private var selectedIndex: Int = 0
    @State private var hunks: [DiffHunk] = []
    @State private var showRevertConfirm = false
    @State private var showCommitSheet = false
    @State private var isPushing = false

    enum Source: Equatable { case loading, git, snapshot, empty }

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .loading:
                ProgressView().frame(maxHeight: .infinity)
            case .empty:
                ContentUnavailableView(
                    "No changes",
                    systemImage: "checkmark.circle",
                    description: Text("Edits you save in the editor show up here until you commit them.")
                )
                .frame(maxHeight: .infinity)
            case .git, .snapshot:
                topBar
                fileList
                Divider()
                hunkList
                if service.isGitRepository {
                    commitBar
                }
            }
        }
        .background(DesignSystem.Colors.background)
        .task { await reload() }
        .sheet(isPresented: $showCommitSheet) {
            CommitSheet(service: service) {
                Task { await reload() }
            }
        }
        .alert("Revert file?", isPresented: $showRevertConfirm) {
            Button("Revert", role: .destructive) {
                guard let path = selectedPath else { return }
                Task {
                    do {
                        try await service.revert(path: path)
                        await reload()
                    } catch {
                        service.error = UserFacingErrorMapper.map(error)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(service.isGitRepository
                 ? "Restores the file to its contents in HEAD."
                 : "Restores the file to its contents when first edited in this session.")
        }
    }

    private var selectedPath: String? {
        switch mode {
        case .git:
            return gitFiles.indices.contains(selectedIndex) ? gitFiles[selectedIndex].path : nil
        case .snapshot:
            return changedFiles.indices.contains(selectedIndex) ? changedFiles[selectedIndex].relativePath : nil
        default: return nil
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                if selectedIndex > 0 { select(selectedIndex - 1) }
            } label: { Label("Previous", systemImage: "chevron.left") }
                .disabled(selectedIndex <= 0)

            Spacer()

            if let selectedPath {
                Text(selectedPath)
                    .font(DesignSystem.Typography.code(13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                let count = (mode == .git) ? gitFiles.count : changedFiles.count
                if selectedIndex < count - 1 { select(selectedIndex + 1) }
            } label: { Label("Next", systemImage: "chevron.right") }
                .disabled(selectedIndex >= ((mode == .git) ? gitFiles.count : changedFiles.count) - 1)

            Button(role: .destructive) { showRevertConfirm = true } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(selectedPath == nil)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(DesignSystem.Colors.cardBackground)
    }

    private var fileList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                if mode == .git {
                    ForEach(Array(gitFiles.enumerated()), id: \.offset) { index, file in
                        fileChip(label: file.path, badge: badge(for: file.kind), index: index)
                    }
                } else {
                    ForEach(Array(changedFiles.enumerated()), id: \.element.id) { index, file in
                        fileChip(label: file.relativePath, badge: nil, index: index)
                    }
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.xs)
        }
        .background(DesignSystem.Colors.cardBackground.opacity(0.5))
    }

    private func fileChip(label: String, badge: String?, index: Int) -> some View {
        Button { select(index) } label: {
            HStack(spacing: 4) {
                if let badge {
                    Text(badge)
                        .font(DesignSystem.Typography.code(10, weight: .bold))
                        .foregroundStyle(badgeColor(for: badge))
                }
                Text(label)
                    .font(DesignSystem.Typography.code(11))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(index == selectedIndex
                        ? DesignSystem.Colors.accent.opacity(0.2)
                        : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .tint(.primary)
    }

    private func badge(for kind: GitFileKind) -> String {
        switch kind {
        case .modified:   return "M"
        case .added:      return "A"
        case .deleted:    return "D"
        case .renamed:    return "R"
        case .untracked:  return "U"
        case .conflicted: return "!"
        }
    }

    private func badgeColor(for badge: String) -> Color {
        switch badge {
        case "M": return .orange
        case "A": return .green
        case "D": return .red
        case "R": return .blue
        case "U": return .secondary
        default:  return .pink
        }
    }

    private var hunkList: some View {
        ScrollView {
            if mode == .git && hunks.isEmpty && !gitUnified.isEmpty {
                // Fallback: render raw unified diff (parser didn't match).
                Text(gitUnified)
                    .font(DesignSystem.Typography.code(11))
                    .textSelection(.enabled)
                    .padding(DesignSystem.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    ForEach(Array(hunks.enumerated()), id: \.offset) { _, hunk in
                        HunkView(hunk: hunk)
                    }
                }
                .padding(DesignSystem.Spacing.md)
            }
        }
    }

    private var commitBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Button {
                showCommitSheet = true
            } label: {
                Label("Commit", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if service.aheadCount > 0 {
                Button {
                    Task { await push() }
                } label: {
                    if isPushing {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Push ↑\(service.aheadCount)", systemImage: "arrow.up.to.line")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isPushing)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.cardBackground)
    }

    private func push() async {
        isPushing = true
        defer { isPushing = false }
        do {
            try await service.pushToOrigin()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            service.error = UserFacingErrorMapper.map(error)
        }
    }

    private func reload() async {
        await service.refreshGitState()
        if service.isGitRepository {
            gitFiles = await service.gitStatusEntries()
            gitUnified = await service.gitDiff() ?? ""
            if gitFiles.isEmpty {
                mode = .empty
                hunks = []
                return
            }
            mode = .git
            if !gitFiles.indices.contains(selectedIndex) { selectedIndex = 0 }
            computeHunksForSelection()
        } else {
            changedFiles = await service.changedFiles()
            if changedFiles.isEmpty {
                mode = .empty
                hunks = []
                return
            }
            mode = .snapshot
            if !changedFiles.indices.contains(selectedIndex) { selectedIndex = 0 }
            computeHunksForSelection()
        }
    }

    private func select(_ index: Int) {
        selectedIndex = index
        computeHunksForSelection()
    }

    private func computeHunksForSelection() {
        switch mode {
        case .git:
            guard gitFiles.indices.contains(selectedIndex) else { hunks = []; return }
            let path = gitFiles[selectedIndex].path
            // Parse the repo-wide unified diff once and pull out this file's hunks.
            if let files = try? UnifiedDiff.parse(gitUnified),
               let file = files.first(where: { $0.newPath == path || $0.oldPath == path }) {
                hunks = file.hunks
            } else {
                hunks = []
            }
        case .snapshot:
            guard changedFiles.indices.contains(selectedIndex) else { hunks = []; return }
            let file = changedFiles[selectedIndex]
            hunks = LineDiff.diff(old: file.original, new: file.current, context: 3)
        default:
            hunks = []
        }
    }
}

// MARK: - Commit sheet

private struct CommitSheet: View {
    @ObservedObject var service: CodeService
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let onDone: () -> Void

    @State private var message: String = ""
    @State private var isCommitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Message") {
                    TextEditor(text: $message)
                        .frame(minHeight: 100)
                }
            }
            .navigationTitle("Commit changes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await commit() }
                    } label: {
                        if isCommitting { ProgressView() } else { Text("Commit") }
                    }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCommitting)
                }
            }
        }
    }

    private func commit() async {
        isCommitting = true
        defer { isCommitting = false }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Author: prefer the GitHub /user profile; fall back to a placeholder.
        var author = GitAuthor(name: "LocalAI User", email: "localai@localhost")
        if let token = try? environment.credentialStore.get(.githubToken), !token.isEmpty {
            if let resolved = await GitHubAuthService().commitAuthor(token: token) {
                author = resolved
            }
        }

        do {
            _ = try await service.commitAll(message: text, author: author)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            onDone()
        } catch {
            service.error = UserFacingErrorMapper.map(error)
        }
    }
}

// MARK: - Hunk / line rendering

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
