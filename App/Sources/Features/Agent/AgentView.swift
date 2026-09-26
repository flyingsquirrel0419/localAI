import SwiftUI
import LocalAICore

/// Agent tab — the main screen. Streams from `AgentRunner` (which wraps the
/// core `AgentLoop` + `ToolExecutor`), shows the workspace header, handles
/// confirmation dialogs, and surfaces the resume banner.
struct AgentChatView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var modelService: ModelService
    @ObservedObject var runner: AgentRunner
    @ObservedObject var selection: WorkspaceSelection

    @State private var input: String = ""
    @State private var errorForAlert: UserFacingError?

    var body: some View {
        VStack(spacing: 0) {
            AgentHeaderView(
                selection: selection,
                modelService: modelService,
                runner: runner
            )

            if let resumable = runner.resumableTaskID {
                ResumeBanner(
                    onResume: { Task { await runner.resumeInterruptedTask() } },
                    onDismiss: { Task { await dismissResumable(resumable) } }
                )
            }

            if runner.rows.isEmpty {
                emptyState
            } else {
                timeline
            }

            if runner.changedFilesCount > 0 {
                ChangedFilesBar(
                    fileCount: runner.changedFilesCount,
                    added: runner.changedFilesAdded,
                    removed: runner.changedFilesRemoved,
                    onViewChanges: { runner.requestShowDiff() }
                )
            }

            inputBar
        }
        .background(DesignSystem.Colors.background)
        .alert(item: $errorForAlert) { uf in
            Alert(
                title: Text(uf.title),
                message: Text(uf.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert("Confirm action", isPresented: Binding(
            get: { runner.pendingConfirmation != nil },
            set: { if !$0 { runner.resolveConfirmation(false) } }
        )) {
            Button("Allow") { runner.resolveConfirmation(true) }
            Button("Deny", role: .cancel) { runner.resolveConfirmation(false) }
        } message: {
            Text(runner.pendingConfirmation ?? "")
        }
        .onChange(of: runner.error) { _, newValue in
            if let err = newValue {
                errorForAlert = err
                runner.error = nil
            }
        }
        .onChange(of: selection.current?.id) { _, newID in
            runner.attach(workspaceID: newID)
        }
        .task {
            runner.attach(workspaceID: selection.current?.id)
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Spacer()
            if modelService.activeModelID == nil {
                ContentUnavailableView(
                    "No active model",
                    systemImage: "cube",
                    description: Text("Open the Models tab, download a model, then tap \"Use model\" to start chatting.")
                )
            } else if selection.current == nil {
                ContentUnavailableView(
                    "No workspace",
                    systemImage: "folder",
                    description: Text("Pick a workspace above, or paste a GitHub URL below and ask the agent to clone it.")
                )
            } else {
                ContentUnavailableView(
                    "Ask the agent",
                    systemImage: "sparkles",
                    description: Text("e.g. \"Fix the failing test in src/sum.js\" or \"clone https://github.com/owner/repo and run the tests\"")
                )
            }
            Spacer()
        }
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    ForEach(runner.rows) { row in
                        TimelineRowView(row: row)
                            .id(row.id)
                    }
                }
                .padding(DesignSystem.Spacing.md)
            }
            .onChange(of: runner.rows.count) { _, _ in
                if let last = runner.rows.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            TextField("Ask the agent", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .disabled(runner.isRunning)
            if runner.isRunning {
                Button {
                    runner.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                }
                .tint(DesignSystem.Colors.destructive)
                .accessibilityLabel("Stop")
            } else {
                Button {
                    let text = input
                    input = ""
                    Task { await runner.send(text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .tint(DesignSystem.Colors.accent)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.cardBackground)
    }

    private func dismissResumable(_ taskID: UUID) async {
        // Best-effort: delete the checkpoint so it stops surfacing.
        try? await environment.agentTaskStore.delete(taskId: taskID)
        await runner.refreshResumable()
    }
}

// MARK: - Header

private struct AgentHeaderView: View {
    @ObservedObject var selection: WorkspaceSelection
    @ObservedObject var modelService: ModelService
    @ObservedObject var runner: AgentRunner

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            WorkspaceHeader(selection: selection)
            HStack(spacing: DesignSystem.Spacing.sm) {
                Text(modelService.activeModelID ?? "no model")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Circle()
                    .fill(runner.isRunning ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 8, height: 8)
                Spacer()
                if runner.canPushToGitHub {
                    Button {
                        Task { await runner.pushToGitHub() }
                    } label: {
                        Label("Push to GitHub", systemImage: "arrow.up.to.line")
                            .font(DesignSystem.Typography.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.accent)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
        }
    }
}

// MARK: - Timeline rows

private struct TimelineRowView: View {
    let row: AgentTimelineRow

    var body: some View {
        switch row {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 32)
                Text(text)
                    .font(DesignSystem.Typography.body)
                    .padding(DesignSystem.Spacing.sm)
                    .background(DesignSystem.Colors.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.card))
                    .textSelection(.enabled)
            }
        case .assistant(_, let text):
            // Streamed assistant text — no giant bubble, just body text.
            Text(text.isEmpty ? "…" : text)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let run):
            ToolRowView(run: run)
        }
    }
}

private struct ToolRowView: View {
    let run: AgentToolRun
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Button {
                if !run.rawOutput.isEmpty { isExpanded.toggle() }
            } label: {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    statusIcon
                    Text(run.title)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.primary)
                    Spacer()
                    if !run.rawOutput.isEmpty {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(DesignSystem.Colors.secondaryText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, !run.rawOutput.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(run.rawOutput)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(DesignSystem.Colors.secondaryText)
                        .textSelection(.enabled)
                        .padding(DesignSystem.Spacing.sm)
                }
                .background(DesignSystem.Colors.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.card))
            }
        }
        .padding(.vertical, 2)
    }

    private var statusIcon: some View {
        Group {
            switch run.status {
            case .running:
                ProgressView().controlSize(.mini)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - Resume banner

private struct ResumeBanner: View {
    let onResume: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "arrow.clockwise")
            Text("Resume interrupted task?")
                .font(DesignSystem.Typography.caption)
            Spacer()
            Button("Resume", action: onResume)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(role: .cancel, action: onDismiss) {
                Image(systemName: "xmark")
            }
            .controlSize(.small)
        }
        .padding(DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.cardBackground)
        .padding(.horizontal, DesignSystem.Spacing.md)
    }
}

// MARK: - Changed files bar

private struct ChangedFilesBar: View {
    let fileCount: Int
    let added: Int
    let removed: Int
    let onViewChanges: () -> Void

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("Changed \(fileCount) file\(fileCount == 1 ? "" : "s")")
                .font(DesignSystem.Typography.caption)
            if added > 0 {
                Text("+\(added)").foregroundStyle(.green).font(DesignSystem.Typography.caption)
            }
            if removed > 0 {
                Text("-\(removed)").foregroundStyle(.red).font(DesignSystem.Typography.caption)
            }
            Spacer()
            Button("View Changes", action: onViewChanges)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.cardBackground)
    }
}
