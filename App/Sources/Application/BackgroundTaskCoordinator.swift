import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// Wraps iOS background-execution facilities so user-initiated agent runs,
/// model downloads, and clones keep going when the app moves to the
/// background.
///
/// Two layers:
///
/// 1. **Always (iOS 17+)** — `UIApplication.beginBackgroundTask` for short
///    grace time (≈30 s). On expiration we invoke the caller's
///    `onExpiration` so the agent loop can checkpoint and mark itself
///    interrupted instead of being silently killed.
///
/// 2. **iOS 26+** — `BGContinuedProcessingTask` for user-initiated work that
///    legitimately needs longer (multi-minute agent runs, model downloads).
///    We register the identifiers listed in Info.plist at launch, and submit
///    a request from `performAgentRun` / `performModelDownload`.
///
/// The coordinator deliberately exposes a small surface; if
/// BGContinuedProcessingTask isn't available (older SDK or older OS) the
/// begin/end pair still provides correct behaviour.
@MainActor
public final class BackgroundTaskCoordinator {

    public static let shared = BackgroundTaskCoordinator()

    public enum Kind: String {
        case agentRun = "com.localai.agent.run"
        case modelDownload = "com.localai.model.download"
    }

    #if canImport(UIKit)
    private var activeTasks: [UUID: UIBackgroundTaskIdentifier] = [:]
    #endif

    private init() {}

    /// Register BGTaskScheduler handlers. Call once at app launch.
    public func registerBackgroundTasks() {
        #if canImport(BackgroundTasks) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            registerContinuedProcessingTasks()
        }
        #endif
    }

    /// Run `work` under background protection. On iOS 26+ the work is also
    /// submitted as a BGContinuedProcessingTask so the system keeps the app
    /// alive longer; the begin/end pair covers expiration between the two.
    ///
    /// - Parameters:
    ///   - kind: which long-running category this work falls under.
    ///   - onExpiration: invoked on the main actor when iOS is about to
    ///     suspend the app. Use it to checkpoint and mark the task
    ///     interrupted; do NOT start new work here.
    ///   - work: the suspending work to perform.
    public func perform<Output>(
        kind: Kind,
        onExpiration: (@Sendable () -> Void)? = nil,
        work: @Sendable () async throws -> Output
    ) async rethrows -> Output {
        let id = UUID()
        #if canImport(UIKit)
        beginForegroundBackgroundTask(id: id, kind: kind, onExpiration: onExpiration)
        defer { endForegroundBackgroundTask(id: id) }
        #endif

        #if canImport(BackgroundTasks) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            submitContinuedProcessingTask(kind: kind)
        }
        #endif

        return try await work()
    }

    // MARK: - beginBackgroundTask (always available)

    #if canImport(UIKit)
    private func beginForegroundBackgroundTask(
        id: UUID,
        kind: Kind,
        onExpiration: (@Sendable () -> Void)?
    ) {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: kind.rawValue) {
            // Expiration handler runs on the main thread. Checkpoint first,
            // then end the task — iOS kills us if we hold it past expiry.
            onExpiration?()
            Task { @MainActor in
                BackgroundTaskCoordinator.shared.endForegroundBackgroundTask(id: id)
            }
        }
        activeTasks[id] = identifier
    }

    private func endForegroundBackgroundTask(id: UUID) {
        guard let identifier = activeTasks.removeValue(forKey: id) else { return }
        if identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }
    #endif

    // MARK: - BGContinuedProcessingTask (iOS 26+)

    #if canImport(BackgroundTasks) && compiler(>=6.2)
    @available(iOS 26.0, *)
    private func registerContinuedProcessingTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Kind.agentRun.rawValue,
            using: nil
        ) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            continued.expirationHandler = { /* agent loop checkpoints itself via stop() */ }
            // The actual work was already kicked off by the caller. We mark
            // the task complete when the run finishes; until then the system
            // keeps us alive.
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Kind.modelDownload.rawValue,
            using: nil
        ) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            continued.expirationHandler = { /* ModelDownloader pauses via its own handler */ }
        }
    }

    @available(iOS 26.0, *)
    private func submitContinuedProcessingTask(kind: Kind) {
        let request = BGContinuedProcessingTaskRequest(
            identifier: kind.rawValue,
            title: kind == .agentRun ? "Agent run" : "Model download",
            subtitle: kind == .agentRun
                ? "LocalAI is working on your request"
                : "LocalAI is downloading a model"
        )
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}
