import Foundation
import LocalAICore
#if canImport(Combine)
import Combine
#endif

/// Dependency container for the app. Owns long-lived services.
@MainActor
final class AppEnvironment: ObservableObject {
    /// Persisted flag: has the user completed first-run login?
    @Published private(set) var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.onboardingKey) }
    }

    let workspaceStore: WorkspaceStore
    let credentialStore: CredentialStore

    private static let onboardingKey = "com.localai.workspace.hasCompletedOnboarding"

    init() {
        // Application Support/LocalAI as the app root.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = appSupport.appendingPathComponent("LocalAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        self.workspaceStore = WorkspaceStore(rootURL: root)

        #if canImport(Security)
        self.credentialStore = KeychainCredentialStore()
        #else
        self.credentialStore = InMemoryCredentialStore()
        #endif

        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingKey)
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
    }

    /// Clear onboarding flag and sign out all credentials (used by Sign out).
    func signOut() async {
        for key in CredentialKey.allCases {
            try? credentialStore.delete(key)
        }
        hasCompletedOnboarding = false
    }

    func hasCredential(_ key: CredentialKey) -> Bool {
        (try? credentialStore.get(key)) != nil
    }
}
