import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(BackgroundTasks) && compiler(>=6.2)
import BackgroundTasks
#endif

/// Wraps iOS background-execution facilities so user-initiated agent runs,
/// model downloads, and clones keep going when the app moves to the
/// background.
///
/// Two layers:
///
/// 1. `BGContinuedProcessingTask` (iOS 26+): user-initiated work the system
///    commits to letting finish, with a system-visible Live Activity showing
///    title/subtitle/progress. Handlers are registered at launch for the
///    identifiers in `BGTaskSchedulerPermittedIdentifiers`; a request is
///    submitted when the user starts the work. On expiration we checkpoint
///    and mark the task interrupted via the caller's `onExpiration`.
///
/// 2. `UIApplication.beginBackgroundTask` (all iOS versions): short grace
///    time (≈30 s). Always active as a fallback — on < iOS 26 it is the only
///    protection, and on iOS 26 it covers the window between work start and
///    the system granting the continued-processing task.
@MainActor
public final class BackgroundTaskCoordinator {

    public static let shared = BackgroundTaskCoordinator()

    public enum Kind: String, Sendable {
        case agentRun = "com.localai.agent.run"
        case modelDownload = "com.localai.model.download"

        /// User-facing title for the system progress UI.
        var title: String {
            switch self {
            case .agentRun: "Agent working"
            case .modelDownload: "Downloading model"
            }
        }
    }

    #if canImport(UIKit)
    private var legacyTasks: [UUID: UIBackgroundTaskIdentifier] = [:]
    #endif

    #if canImport(BackgroundTasks) && compiler(>=6.2)
    /// Tasks the system has delivered to our launch handlers, by identifier.
    /// Values are `BGContinuedProcessingTask` type-erased to `AnyObject` so
    /// this stored property compiles when targeting < iOS 26; all accesses
    /// happen behind `if #available(iOS 26.0, *)`.
    private var continuedTasks: [String: AnyObject] = [:]
    #endif

    /// Expiration callbacks for in-flight work, keyed by kind raw value.
    /// Set by `perform` and invoked from the BGTask expirationHandler so the
    /// agent loop can checkpoint + mark interrupted instead of being killed.
    private var expirationCallbacks: [String: @Sendable () -> Void] = [:]

    private init() {}

    /// Register BGTaskScheduler launch handlers. MUST be called before the
    /// app finishes launching (from `App.init()`), per BGTaskScheduler docs —
    /// late registration silently drops submitted requests.
    public func registerBackgroundTasks() {
        #if canImport(BackgroundTasks) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            for kind in [Kind.agentRun, Kind.modelDownload] {
                _ = BGTaskScheduler.shared.register(
                    forTaskWithIdentifier: kind.rawValue,
                    using: nil
                ) { task in
                    Task { @MainActor in
                        BackgroundTaskCoordinator.shared.handleContinuedTask(task, kind: kind)
                    }
                }
            }
        }
        #endif
    }

    /// Run `work` under background protection.
    ///
    /// - Parameters:
    ///   - kind: which long-running category this work falls under (drives
    ///     the BGTaskScheduler identifier and the system-visible title).
    ///   - onExpiration: invoked on the main actor when iOS is about to
    ///     suspend the app or the user cancels from the system UI. Use it to
    ///     checkpoint and mark the task interrupted; do NOT start new work.
    ///   - work: the suspending work to perform.
    public func perform<Output>(
        kind: Kind,
        onExpiration: (@Sendable () -> Void)? = nil,
        work: @Sendable () async throws -> Output
    ) async rethrows -> Output {
        expirationCallbacks[kind.rawValue] = onExpiration
        defer { expirationCallbacks.removeValue(forKey: kind.rawValue) }

        #if canImport(UIKit)
        let legacyID = UUID()
        beginLegacyBackgroundTask(id: legacyID, kind: kind, onExpiration: onExpiration)
        defer { endLegacyBackgroundTask(id: legacyID) }
        #endif

        var submitted = false
        #if canImport(BackgroundTasks) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            submitted = submitContinuedRequest(kind: kind)
        }
        #else
        _ = submitted
        #endif

        do {
            let output = try await work()
            #if canImport(BackgroundTasks) && compiler(>=6.2)
            if #available(iOS 26.0, *), submitted {
                completeContinuedTask(kind: kind, success: true)
            }
            #endif
            return output
        } catch {
            #if canImport(BackgroundTasks) && compiler(>=6.2)
            if #available(iOS 26.0, *), submitted {
                completeContinuedTask(kind: kind, success: false)
            }
            #endif
            throw error
        }
    }

    /// Update the system-visible progress for an in-flight continued task.
    /// Safe to call when no task was delivered (no-op).
    public func updateProgress(kind: Kind, completed: Int64, total: Int64, subtitle: String? = nil) {
        #if canImport(BackgroundTasks) && compiler(>=6.2)
        if #available(iOS 26.0, *),
           let task = continuedTasks[kind.rawValue] as? BGContinuedProcessingTask {
            if task.progress.totalUnitCount != total {
                task.progress.totalUnitCount = total
            }
            task.progress.completedUnitCount = completed
            if let subtitle {
                task.updateTitle(kind.title, subtitle: subtitle)
            }
        }
        #endif
    }

    // MARK: - BGContinuedProcessingTask (iOS 26+)

    #if canImport(BackgroundTasks) && compiler(>=6.2)
    @available(iOS 26.0, *)
    private func handleContinuedTask(_ task: BGTask, kind: Kind) {
        guard let continued = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        continuedTasks[kind.rawValue] = continued
        continued.expirationHandler = { [kind] in
            Task { @MainActor in
                let coordinator = BackgroundTaskCoordinator.shared
                coordinator.expirationCallbacks[kind.rawValue]?()
                coordinator.completeContinuedTask(kind: kind, success: false)
            }
        }
    }

    /// Submit a request for the given kind. Returns false when the system
    /// refuses (e.g. user disabled background work for this app) — the caller
    /// still runs `work` under the legacy beginBackgroundTask protection.
    @available(iOS 26.0, *)
    private func submitContinuedRequest(kind: Kind) -> Bool {
        // Only one pending request per identifier is allowed; drop any stale
        // one from a previous run before submitting ours.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: kind.rawValue)
        let request = BGContinuedProcessingTaskRequest(
            identifier: kind.rawValue,
            title: kind.title,
            subtitle: "Starting"
        )
        // Wait for a free slot rather than failing when the per-app limit is
        // momentarily reached — the work runs in-process regardless.
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            return false
        }
    }

    @available(iOS 26.0, *)
    private func completeContinuedTask(kind: Kind, success: Bool) {
        if let task = continuedTasks.removeValue(forKey: kind.rawValue) as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: success)
        } else {
            // Request was submitted but never delivered (or already expired):
            // cancel it so it can't launch us later for stale work.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: kind.rawValue)
        }
    }
    #endif

    // MARK: - beginBackgroundTask (fallback, all iOS versions)

    #if canImport(UIKit)
    private func beginLegacyBackgroundTask(
        id: UUID,
        kind: Kind,
        onExpiration: (@Sendable () -> Void)?
    ) {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: kind.rawValue) {
            // Expiration handler runs on the main thread. Checkpoint first,
            // then end the task — iOS kills us if we hold it past expiry.
            onExpiration?()
            Task { @MainActor in
                BackgroundTaskCoordinator.shared.endLegacyBackgroundTask(id: id)
            }
        }
        legacyTasks[id] = identifier
    }

    private func endLegacyBackgroundTask(id: UUID) {
        guard let identifier = legacyTasks.removeValue(forKey: id) else { return }
        if identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }
    #endif
}
