import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Wraps iOS background-execution facilities so user-initiated agent runs,
/// model downloads, and clones keep going when the app moves to the
/// background.
///
/// Currently uses `UIApplication.beginBackgroundTask` (iOS 17+) for short
/// grace time (≈30 s). On expiration we invoke the caller's `onExpiration`
/// so the agent loop can checkpoint and mark itself interrupted instead of
/// being silently killed.
///
/// **BGContinuedProcessingTask (iOS 26+)**: the API exists per WWDC25 session
/// 227 ("Finish tasks in the background") but its declarations don't appear
/// in the iOS 26.2 SDK's BackgroundTasks headers as of Xcode 26.3 — the
/// types may be exposed via Swift-only overlays that aren't visible to the
/// header-grep verification we run in CI. Rather than guess at the surface
/// and break the build, the coordinator currently uses beginBackgroundTask
/// only; once the BGContinuedProcessingTask types are reachable from Swift
/// (and verified in CI), they can be added behind `#if compiler(>=6.2)` +
/// `if #available(iOS 26, *)` without changing call sites.
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

    /// Placeholder for parity with a future BGTaskScheduler registration.
    /// Safe to call at app launch; currently a no-op.
    public func registerBackgroundTasks() {
        // No-op until BGContinuedProcessingTask is reachable from Swift.
    }

    /// Run `work` under background protection.
    ///
    /// - Parameters:
    ///   - kind: which long-running category this work falls under (used
    ///     for the system-visible task name).
    ///   - onExpiration: invoked on the main actor when iOS is about to
    ///     suspend the app. Use it to checkpoint and mark the task
    ///     interrupted; do NOT start new work here.
    ///   - work: the suspending work to perform.
    public func perform<Output>(
        kind: Kind,
        onExpiration: (@Sendable () -> Void)? = nil,
        work: @Sendable () async throws -> Output
    ) async rethrows -> Output {
        #if canImport(UIKit)
        let id = UUID()
        beginForegroundBackgroundTask(id: id, kind: kind, onExpiration: onExpiration)
        defer { endForegroundBackgroundTask(id: id) }
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
}
