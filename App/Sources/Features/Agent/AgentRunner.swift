import Foundation
import LocalAICore
#if canImport(UIKit)
import UIKit
#endif

/// UI-side snapshot of one tool execution for the agent timeline.
public struct AgentToolRun: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case running
        case succeeded(summary: String)
        case failed(summary: String)
    }
    public let id: String
    public let title: String
    public var status: Status
    public var rawOutput: String

    public init(id: String, title: String, status: Status, rawOutput: String = "") {
        self.id = id
        self.title = title
        self.status = status
        self.rawOutput = rawOutput
    }
}

/// One row in the agent timeline (user, assistant text, tool activity).
public enum AgentTimelineRow: Identifiable, Equatable, Sendable {
    case user(id: UUID, text: String)
    case assistant(id: UUID, text: String)
    case tool(AgentToolRun)

    public var id: String {
        switch self {
        case .user(let id, _): return "u-\(id.uuidString)"
        case .assistant(let id, _): return "a-\(id.uuidString)"
        case .tool(let run): return "t-\(run.id)"
        }
    }
}

/// Drives `AgentLoop` for one workspace at a time. Owns the timeline state
/// the SwiftUI view renders, the Stop button, confirmation dialogs, the
/// "Push to GitHub" affordance, and checkpoint/resume.
///
/// Lifecycle: one `AgentRunner` per app lifetime (sits in AppEnvironment);
/// call `attach(workspaceID:)` when the active workspace changes; `send(...)`
/// for each user request.
@MainActor
public final class AgentRunner: ObservableObject {

    // MARK: - Published UI state

    @Published public private(set) var rows: [AgentTimelineRow] = []
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var pendingConfirmation: String?
    @Published public private(set) var changedFilesCount: Int = 0
    @Published public private(set) var changedFilesAdded: Int = 0
    @Published public private(set) var changedFilesRemoved: Int = 0
    @Published public private(set) var lastCommitSHA: String?
    /// True after a local commit completes and the user did not authorize a
    /// push. The UI surfaces a "Push to GitHub" button.
    @Published public private(set) var canPushToGitHub: Bool = false
    /// Most recent interrupted task, surfaced as a "Resume task" banner.
    @Published public private(set) var resumableTaskID: UUID?
    @Published public var error: UserFacingError?

    // MARK: - Dependencies

    private let engine: MLXEngine
    private let workspaceStore: WorkspaceStore
    private let gitService: Libgit2GitService
    private let credentialProvider: GitCredentialProvider
    private let taskStore: AgentTaskStore
    private let runtimeCoordinator: NodeRuntimeCoordinator

    /// Currently-attached workspace; nil until the user picks one.
    public private(set) var workspaceID: UUID?
    /// Continuation for the in-flight needsConfirmation dialog, if any.
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    private var runTask: Task<Void, Never>?
    private var activeLoop: AgentLoop?
    #if canImport(UIKit)
    private var memoryWarningObserver: NSObjectProtocol?
    #endif

    public init(
        engine: MLXEngine,
        workspaceStore: WorkspaceStore,
        gitService: Libgit2GitService,
        credentialProvider: GitCredentialProvider,
        taskStore: AgentTaskStore,
        runtimeCoordinator: NodeRuntimeCoordinator
    ) {
        self.engine = engine
        self.workspaceStore = workspaceStore
        self.gitService = gitService
        self.credentialProvider = credentialProvider
        self.taskStore = taskStore
        self.runtimeCoordinator = runtimeCoordinator

        #if canImport(UIKit)
        // Explicit checkpoint-on-memory-warning: when iOS warns about memory
        // pressure mid-run (e.g. a large model + a big diff in memory), save
        // a checkpoint and stop the loop instead of relying on the engine's
        // cancellation side effect. If we're idle this is a no-op.
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.checkpointAndStop()
            }
        }
        #endif
    }

    #if canImport(UIKit)
    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }
    #endif

    // MARK: - Lifecycle

    /// Mark any task that was running when the app last quit as interrupted,
    /// and surface the most recent one as a resume banner. Call at launch.
    public func markInterruptedOnLaunch() async {
        _ = try? await taskStore.markInterruptedOnLaunch()
        await refreshResumable()
    }

    public func attach(workspaceID: UUID?) {
        self.workspaceID = workspaceID
        Task { await refreshResumable() }
    }

    public func refreshResumable() async {
        guard let workspaceID else {
            resumableTaskID = nil
            return
        }
        let all = (try? await taskStore.list()) ?? []
        resumableTaskID = all.first(where: {
            $0.workspaceId == workspaceID && $0.state == .interrupted
        })?.taskId
    }

    // MARK: - Send

    /// Submit a user request. If the request is a clone intent for a GitHub
    /// URL and there's no current workspace repository, we clone first, then
    /// run the agent in the new workspace.
    public func send(_ text: String) async {
        guard !isRunning else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Handle clone intent before the loop: if the request names a GitHub
        // URL with clone intent AND the current workspace has no repository
        // (or there is no workspace), clone into a new workspace first.
        if let (name, url) = Self.parseCloneIntent(trimmed),
           await shouldCloneBeforeRun() {
            do {
                try await cloneIntoWorkspace(name: name, url: url)
            } catch {
                self.error = UserFacingErrorMapper.map(error)
                return
            }
        }

        guard let workspaceID else {
            self.error = UserFacingError(
                title: "No workspace",
                message: "Pick or create a workspace before running the agent.",
                recoveryAction: .dismiss,
                developerDetails: "workspaceID nil at send()"
            )
            return
        }

        let taskID = UUID()
        rows.append(.user(id: UUID(), text: trimmed))
        isRunning = true
        canPushToGitHub = false
        lastCommitSHA = nil
        changedFilesCount = 0

        let requestAuthorizedPush = PushIntentDetector.userAuthorizedPush(in: trimmed)
        let runner = self
        runTask = Task { @MainActor in
            await BackgroundTaskCoordinator.shared.perform(
                kind: .agentRun,
                onExpiration: { Task { await runner.checkpointAndStop() } }
            ) {
                await runner.execute(
                    taskID: taskID,
                    workspaceID: workspaceID,
                    userRequest: trimmed,
                    userAuthorizedPush: requestAuthorizedPush,
                    resume: false
                )
            }
        }
        await runTask?.value
    }

    /// Resume the most recent interrupted task for the current workspace.
    public func resumeInterruptedTask() async {
        guard let taskID = resumableTaskID, let workspaceID else { return }
        isRunning = true
        resumableTaskID = nil
        let runner = self
        runTask = Task { @MainActor in
            await BackgroundTaskCoordinator.shared.perform(
                kind: .agentRun,
                onExpiration: { Task { await runner.checkpointAndStop() } }
            ) {
                await runner.execute(
                    taskID: taskID,
                    workspaceID: workspaceID,
                    userRequest: "",
                    userAuthorizedPush: false,
                    resume: true
                )
            }
        }
        await runTask?.value
    }

    /// Stop the current run. The loop saves a checkpoint before exiting.
    public func stop() {
        runTask?.cancel()
        Task { await activeLoop?.stop() }
        isRunning = false
    }

    /// Memory-warning / background expiration hook. The loop saves a
    /// checkpoint on cancel, so this just cancels the in-flight run.
    public func checkpointAndStop() {
        stop()
    }

    // MARK: - Confirmation

    /// User answered the confirmation dialog. Bridges into the executor's
    /// `confirm` callback.
    public func resolveConfirmation(_ approved: Bool) {
        pendingConfirmation = nil
        confirmationContinuation?.resume(returning: approved)
        confirmationContinuation = nil
    }

    // MARK: - Push

    /// Push the most recent local commit to origin. Triggered by the
    /// "Push to GitHub" button after a commit when push wasn't in the
    /// original request.
    public func pushToGitHub() async {
        guard let workspaceID else { return }
        do {
            let directory = try await workspaceStore.repositoryURL(for: workspaceID)
            let credentials = try await credentialProvider.credentials(for: nil)
            try await gitService.push(
                in: directory,
                remote: "origin",
                branch: nil,
                credentials: credentials,
                force: false
            )
            canPushToGitHub = false
        } catch {
            self.error = UserFacingErrorMapper.map(error)
        }
    }

    /// Open the Code tab's diff view. Implemented by RootView; the runner
    /// just owns the request flag.
    @Published public var showDiffRequest: Bool = false
    public func requestShowDiff() {
        showDiffRequest = true
    }

    // MARK: - Private: run

    private func execute(
        taskID: UUID,
        workspaceID: UUID,
        userRequest: String,
        userAuthorizedPush: Bool,
        resume: Bool
    ) async {
        defer {
            isRunning = false
            Task { await refreshResumable() }
        }

        let repositoryURL: URL
        do {
            repositoryURL = try await workspaceStore.repositoryURL(for: workspaceID)
        } catch {
            self.error = UserFacingErrorMapper.map(error)
            return
        }

        let fileSystem: SandboxedFileSystem
        do {
            fileSystem = try SandboxedFileSystem(rootURL: repositoryURL)
        } catch {
            self.error = UserFacingErrorMapper.map(error)
            return
        }

        // Make sure the in-process Node host is up before the executor asks
        // for it. If NodeMobile isn't in this build, runtime is nil and the
        // executor surfaces a clear error when a run_node/run_npm tool fires.
        await runtimeCoordinator.ensureStarted()
        let runtime = runtimeCoordinator.makeRuntime()

        let search = RepositorySearch(fileSystem: fileSystem)
        let context = ToolContext(
            fileSystem: fileSystem,
            search: search,
            git: gitService,
            runtime: runtime,
            credentialProvider: credentialProvider,
            repositoryDirectory: repositoryURL,
            userAuthorizedPush: userAuthorizedPush,
            confirm: { [weak self] description in
                guard let self else { return false }
                return await self.askConfirmation(description: description)
            }
        )
        let executor = ToolExecutor(context: context)
        // 8K tokens is the budget used by AgentLoopTests/AgentAcceptanceTests;
        // matches what fits comfortably in small (~4B) on-device models.
        let contextWindow = ContextWindowManager(tokenBudget: 8192)
        let loop = AgentLoop(
            engine: engine,
            executor: executor,
            contextWindow: contextWindow,
            limits: .default,
            taskStore: taskStore,
            workspaceId: workspaceID
        )
        activeLoop = loop
        defer { activeLoop = nil }

        let stream: AsyncStream<AgentEvent> = resume
            ? await loop.resume(taskId: taskID)
            : await loop.run(taskId: taskID, userRequest: userRequest)

        var assistantText = ""
        var assistantID: UUID?
        var sawLocalCommit = false
        var toolsCompleted = 0

        for await event in stream {
            if Task.isCancelled { break }
            switch event {
            case .assistantDelta(let delta):
                if assistantID == nil {
                    let id = UUID()
                    assistantID = id
                    rows.append(.assistant(id: id, text: ""))
                }
                assistantText += delta
                if let id = assistantID,
                   let index = rows.firstIndex(where: { $0.id == "a-\(id.uuidString)" }) {
                    rows[index] = .assistant(id: id, text: assistantText)
                }

            case .toolStarted(let id, let activity):
                // Reset per-tool accumulation for the next assistant segment.
                assistantID = nil
                assistantText = ""
                rows.append(.tool(AgentToolRun(
                    id: id, title: activity.title, status: .running
                )))

            case .toolFinished(let id, let succeeded, let summary, let raw):
                if let index = rows.firstIndex(where: { $0.id == "t-\(id)" }),
                   case .tool(let existing) = rows[index] {
                    var updated = existing
                    updated.status = succeeded
                        ? .succeeded(summary: summary)
                        : .failed(summary: summary)
                    updated.rawOutput = raw
                    rows[index] = .tool(updated)
                }
                if succeeded {
                    // A successful git_commit emits "Committed <sha8>." from
                    // ToolExecutor+Git; capture the SHA and mark that we
                    // should offer push after the run.
                    if let sha = Self.extractCommitSHA(from: raw) {
                        lastCommitSHA = sha
                        sawLocalCommit = true
                    }
                }
                // Keep the iOS 26 continued-processing task's system UI
                // moving; stalled tasks may be expired by the system.
                toolsCompleted += 1
                BackgroundTaskCoordinator.shared.updateProgress(
                    kind: .agentRun,
                    completed: Int64(toolsCompleted),
                    total: Int64(toolsCompleted + 1),
                    subtitle: summary.isEmpty ? nil : String(summary.prefix(60))
                )
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif

            case .needsConfirmation:
                // The executor is blocking on confirm(); pendingConfirmation
                // was already set by askConfirmation.
                break

            case .changedFiles(let files, let added, let removed):
                changedFilesCount = files.count
                changedFilesAdded = added
                changedFilesRemoved = removed

            case .finished:
                if sawLocalCommit, !userAuthorizedPush {
                    canPushToGitHub = true
                }

            case .failed(let uf):
                self.error = uf

            case .cancelled:
                // Loop already saved the checkpoint; resume banner picks it up.
                break
            }
        }
    }

    private func askConfirmation(description: String) async -> Bool {
        await withCheckedContinuation { continuation in
            self.pendingConfirmation = description
            self.confirmationContinuation = continuation
        }
    }

    /// Pull the SHA8 out of a "Committed <sha>." tool output. Returns nil
    /// for any other success payload.
    static func extractCommitSHA(from output: String) -> String? {
        guard let range = output.range(of: #"Committed ([0-9a-f]{7,40})\."#, options: .regularExpression) else {
            return nil
        }
        let matched = output[range]
        // Drop "Committed " prefix and trailing "."
        let sha = matched.dropFirst("Committed ".count).dropLast()
        return String(sha)
    }

    // MARK: - Private: clone intent

    /// True when there's no active workspace or the active workspace has no
    /// repository URL. In that case a GitHub URL in the request should
    /// trigger a clone.
    private func shouldCloneBeforeRun() async -> Bool {
        guard let id = workspaceID else { return true }
        let all = (try? await workspaceStore.list()) ?? []
        guard let meta = all.first(where: { $0.id == id }) else { return true }
        return meta.repositoryURL == nil
    }

    /// Parse "clone https://github.com/owner/repo" or Korean equivalent.
    /// Returns (workspaceName, url) when matched.
    static func parseCloneIntent(_ text: String) -> (name: String, url: URL)? {
        let lowered = text.lowercased()
        guard lowered.contains("clone") || text.contains("클론") else { return nil }
        guard let urlMatch = text.range(of: #"https?://(?:www\.)?github\.com/[^\s"'<>]+"#, options: .regularExpression) else {
            return nil
        }
        let urlString = String(text[urlMatch]).trimmingCharacters(in: CharacterSet(charactersIn: "/.,"))
        guard let url = URL(string: urlString) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return (name: "\(parts[0])-\(repo)", url: url)
    }

    private func cloneIntoWorkspace(name: String, url: URL) async throws {
        let meta = try await workspaceStore.create(name: name, repositoryURL: url)
        let directory = try await workspaceStore.repositoryURL(for: meta.id)
        let credentials = try await credentialProvider.credentials(for: url)
        do {
            try await gitService.clone(url: url, to: directory, branch: nil, credentials: credentials)
        } catch {
            try? await workspaceStore.delete(id: meta.id, confirm: true)
            throw error
        }
        attach(workspaceID: meta.id)
    }
}
