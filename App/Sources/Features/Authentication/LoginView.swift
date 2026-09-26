import SwiftUI
import LocalAICore

/// First-run login: collect Hugging Face and GitHub credentials.
/// - Hugging Face: PAT validated against /api/whoami-v2 (shows username on success).
/// - GitHub: PAT validated against GET /user (shows login on success).
/// - GitHub OAuth Device Flow is available when `GitHubOAuthClientID` is set in
///   Info.plist. The button is hidden otherwise — never faked.
/// - Hugging Face OAuth (via swift-huggingface) is shown only when
///   `HuggingFaceOAuthClientID` is set.
struct LoginView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var hfToken: String = ""
    @State private var ghToken: String = ""
    @State private var hfConnected: Bool = false
    @State private var ghConnected: Bool = false
    @State private var hfUsername: String?
    @State private var ghLogin: String?
    @State private var hfIsValidating = false
    @State private var ghIsValidating = false
    @State private var error: UserFacingError?

    // GitHub device flow state
    @State private var deviceFlow: GitHubAuthService.DeviceCode?
    @State private var isPollingDeviceFlow = false
    @State private var deviceFlowTask: Task<Void, Never>?

    private var gitHubClientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "GitHubOAuthClientID") as? String) ?? ""
    }
    private var huggingFaceClientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "HuggingFaceOAuthClientID") as? String) ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystem.Spacing.lg) {
                    header
                    hfCard
                    ghCard
                    continueButton
                }
                .padding(DesignSystem.Spacing.md)
            }
            .background(DesignSystem.Colors.background)
            .navigationTitle("Sign in")
            .onAppear {
                hfConnected = environment.hasCredential(.huggingFaceToken)
                ghConnected = environment.hasCredential(.githubToken)
            }
            .alert(item: $error) { uf in
                Alert(
                    title: Text(uf.title),
                    message: Text(uf.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .sheet(item: $deviceFlow) { flow in
                deviceFlowSheet(flow)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Connect your accounts")
                .font(DesignSystem.Typography.title)
            Text("Tokens are stored in the iOS Keychain and never leave your device except to call the respective service.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Hugging Face

    private var hfCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("Hugging Face").font(DesignSystem.Typography.headline)
                Spacer()
                if hfConnected, let name = hfUsername {
                    Label("Connected as \(name)", systemImage: "checkmark.circle.fill")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.success)
                } else if hfConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.success)
                }
            }
            Text("Access token for downloading models")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.secondaryText)

            if hfConnected {
                Button(role: .destructive) {
                    signOut(key: .huggingFaceToken) { hfConnected = false; hfUsername = nil }
                } label: { Text("Sign out").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
            } else {
                SecureField("hf_...", text: $hfToken)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(DesignSystem.Typography.code())
                    .padding(DesignSystem.Spacing.sm)
                    .background(DesignSystem.Colors.background)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.card))

                Button {
                    connectHF()
                } label: {
                    if hfIsValidating {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Connect").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.accent)
                .disabled(hfToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hfIsValidating)

                if !huggingFaceClientID.isEmpty {
                    Button {
                        error = UserFacingError(
                            title: "OAuth not configured in this build",
                            message: "HF OAuth via swift-huggingface is wired but this build does not yet launch the browser session. Use a personal access token above.",
                            recoveryAction: .dismiss,
                            developerDetails: "HF OAuth deferred to a follow-up — see research note §4"
                        )
                    } label: {
                        Label("Sign in with Hugging Face", systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.card))
    }

    // MARK: - GitHub

    private var ghCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("GitHub").font(DesignSystem.Typography.headline)
                Spacer()
                if ghConnected, let login = ghLogin {
                    Label("Connected as \(login)", systemImage: "checkmark.circle.fill")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.success)
                } else if ghConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.success)
                }
            }
            Text("Personal access token for cloning repositories")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.secondaryText)

            if ghConnected {
                Button(role: .destructive) {
                    signOut(key: .githubToken) { ghConnected = false; ghLogin = nil }
                } label: { Text("Sign out").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
            } else {
                SecureField("ghp_... or github_pat_...", text: $ghToken)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(DesignSystem.Typography.code())
                    .padding(DesignSystem.Spacing.sm)
                    .background(DesignSystem.Colors.background)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.card))

                Button {
                    connectGH()
                } label: {
                    if ghIsValidating {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Connect").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.accent)
                .disabled(ghToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ghIsValidating)

                if !gitHubClientID.isEmpty {
                    Button {
                        startDeviceFlow()
                    } label: {
                        Label("Sign in with GitHub", systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isPollingDeviceFlow)
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.card))
    }

    private var continueButton: some View {
        Button {
            environment.completeOnboarding()
        } label: {
            Text("Continue").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(DesignSystem.Colors.accent)
        .disabled(!hfConnected && !ghConnected)
    }

    // MARK: - Actions

    private func connectHF() {
        let trimmed = hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hfIsValidating = true
        Task {
            defer { hfIsValidating = false }
            do {
                let client = HuggingFaceClient(token: trimmed)
                let user = try await client.whoami()
                try environment.credentialStore.set(trimmed, for: .huggingFaceToken)
                hfUsername = user.name
                hfConnected = true
                hfToken = ""
            } catch {
                self.error = UserFacingErrorMapper.map(error)
            }
        }
    }

    private func connectGH() {
        let trimmed = ghToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ghIsValidating = true
        Task {
            defer { ghIsValidating = false }
            do {
                let service = GitHubAuthService()
                let user = try await service.validatePAT(trimmed)
                try environment.credentialStore.set(trimmed, for: .githubToken)
                ghLogin = user.login
                ghConnected = true
                ghToken = ""
            } catch let err as GitHubAuthService.AuthError {
                switch err {
                case .invalidToken:
                    self.error = UserFacingError(
                        title: "Invalid token",
                        message: "GitHub rejected that token. Check it and try again.",
                        recoveryAction: .retry,
                        developerDetails: "GET /user returned 401/403"
                    )
                default:
                    self.error = UserFacingErrorMapper.map(URLError(.badServerResponse))
                }
            } catch {
                self.error = UserFacingErrorMapper.map(error)
            }
        }
    }

    private func signOut(key: CredentialKey, then: @escaping () -> Void) {
        do {
            try environment.credentialStore.delete(key)
            then()
        } catch {
            self.error = UserFacingErrorMapper.map(error)
        }
    }

    // MARK: - GitHub Device Flow

    private func startDeviceFlow() {
        let clientID = gitHubClientID
        guard !clientID.isEmpty else { return }
        isPollingDeviceFlow = true
        deviceFlowTask = Task {
            do {
                let service = GitHubAuthService()
                let flow = try await service.startDeviceFlow(clientID: clientID)
                await MainActor.run {
                    deviceFlow = flow
                }
                // Poll in the background.
                let pollInterval = max(flow.interval, 5)
                let deadline = Date().addingTimeInterval(TimeInterval(flow.expiresIn))
                while Date() < deadline {
                    try? await Task.sleep(nanoseconds: UInt64(pollInterval) * 1_000_000_000)
                    do {
                        let token = try await service.pollDeviceFlow(clientID: clientID, deviceCode: flow.deviceCode)
                        try environment.credentialStore.set(token, for: .githubToken)
                        let user = try await service.validatePAT(token)
                        await MainActor.run {
                            ghLogin = user.login
                            ghConnected = true
                            deviceFlow = nil
                            isPollingDeviceFlow = false
                        }
                        return
                    } catch GitHubAuthService.AuthError.authorizationPending {
                        continue
                    } catch GitHubAuthService.AuthError.slowDown {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        continue
                    } catch {
                        throw error
                    }
                }
                await MainActor.run {
                    deviceFlow = nil
                    isPollingDeviceFlow = false
                    self.error = UserFacingError(
                        title: "Sign-in timed out",
                        message: "The device flow code expired. Try again.",
                        recoveryAction: .retry,
                        developerDetails: "device flow deadline reached"
                    )
                }
            } catch {
                await MainActor.run {
                    deviceFlow = nil
                    isPollingDeviceFlow = false
                    self.error = UserFacingErrorMapper.map(error)
                }
            }
        }
    }

    private func deviceFlowSheet(_ flow: GitHubAuthService.DeviceCode) -> some View {
        NavigationStack {
            VStack(spacing: DesignSystem.Spacing.lg) {
                Text("Authorize LocalAI on GitHub")
                    .font(DesignSystem.Typography.title)
                Text("Enter this code at the URL below:")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                Text(flow.userCode)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .padding()
                    .background(DesignSystem.Colors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.card))
                    .textSelection(.enabled)
                Link(destination: flow.verificationURL) {
                    Label(flow.verificationURL.host ?? flow.verificationURL.absoluteString,
                          systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.accent)
                Spacer()
            }
            .padding(DesignSystem.Spacing.lg)
            .navigationTitle("GitHub sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        deviceFlowTask?.cancel()
                        deviceFlow = nil
                        isPollingDeviceFlow = false
                    }
                }
            }
        }
    }
}

// DeviceCode is declared in this module (App/Sources/Services), so plain
// conformance is fine — `@retroactive` is only for cross-module conformances.
extension GitHubAuthService.DeviceCode: Identifiable {
    public var id: String { deviceCode }
}

extension UserFacingError: @retroactive Identifiable {
    public var id: String { title + message + developerDetails }
}

#Preview {
    LoginView().environmentObject(AppEnvironment())
}
