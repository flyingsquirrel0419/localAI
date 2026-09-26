import SwiftUI

@main
struct LocalAIApp: App {
    @StateObject private var environment = AppEnvironment()

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
        }
    }
}
