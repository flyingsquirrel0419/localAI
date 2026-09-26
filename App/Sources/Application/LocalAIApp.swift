import SwiftUI

@main
struct LocalAIApp: App {
    @StateObject private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Register BGTaskScheduler identifiers at launch (no-op on iOS < 26).
        // Must run before any BGTaskScheduler.submit call.
        BackgroundTaskCoordinator.shared.registerBackgroundTasks()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if environment.hasCompletedOnboarding {
                    RootView()
                } else {
                    LoginView()
                }
            }
            .environmentObject(environment)
            .preferredColorScheme(nil) // follow system; dark mode friendly via system colors
            .task {
                // Mark any task that was running when we last quit as
                // interrupted, and surface the most recent one as a resume
                // banner in the Agent tab.
                await environment.agentRunner.markInterruptedOnLaunch()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background {
                    // The system is about to suspend us. Tell the agent loop
                    // to checkpoint and stop; the beginBackgroundTask
                    // expiration handler does the same, but scenePhase is the
                    // earlier signal when both fire.
                    environment.agentRunner.checkpointAndStop()
                }
            }
        }
    }
}
