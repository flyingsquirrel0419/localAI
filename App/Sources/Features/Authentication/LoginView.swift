import SwiftUI
import LocalAICore

/// First-run login: collect Hugging Face and GitHub access tokens.
/// OAuth flows arrive in a later phase — this screen only accepts PATs, honestly.
struct LoginView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var hfToken: String = ""
    @State private var ghToken: String = ""
    @State private var hfConnected: Bool = false
    @State private var ghConnected: Bool = false
    @State private var error: UserFacingError?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystem.Spacing.lg) {
                    header
                    providerCard(
                        title: "Hugging Face",
                        subtitle: "Access token for downloading models",
                        token: $hfToken,
                        isConnected: $hfConnected,
                        key: .huggingFaceToken,
                        placeholder: "hf_..."
                    )
                    providerCard(
                        title: "GitHub",
                        subtitle: "Personal access token for cloning repositories",
                        token: $ghToken,
                        isConnected: $ghConnected,
                        key: .githubToken,
                        placeholder: "ghp_... or github_pat_..."
                    )
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

    private func providerCard(
        title: String,
        subtitle: String,
        token: Binding<String>,
        isConnected: Binding<Bool>,
        key: CredentialKey,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text(title).font(DesignSystem.Typography.headline)
                Spacer()
                if isConnected.wrappedValue {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.success)
                }
            }
            Text(subtitle)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.secondaryText)

            if isConnected.wrappedValue {
                Button(role: .destructive) {
                    signOut(key: key, isConnected: isConnected)
                } label: {
                    Text("Sign out")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                SecureField(placeholder, text: token)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(DesignSystem.Typography.code())
                    .padding(DesignSystem.Spacing.sm)
                    .background(DesignSystem.Colors.background)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.card))

                Button {
                    connect(key: key, token: token.wrappedValue, isConnected: isConnected)
                } label: {
                    Text("Connect")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.accent)
                .disabled(token.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            Text("Continue")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(DesignSystem.Colors.accent)
        .disabled(!hfConnected && !ghConnected)
    }

    private func connect(key: CredentialKey, token: String, isConnected: Binding<Bool>) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try environment.credentialStore.set(trimmed, for: key)
            isConnected.wrappedValue = true
        } catch {
            self.error = UserFacingErrorMapper.map(error)
        }
    }

    private func signOut(key: CredentialKey, isConnected: Binding<Bool>) {
        do {
            try environment.credentialStore.delete(key)
            isConnected.wrappedValue = false
        } catch {
            self.error = UserFacingErrorMapper.map(error)
        }
    }
}

extension UserFacingError: Identifiable {
    public var id: String { title + message + developerDetails }
}

#Preview {
    LoginView().environmentObject(AppEnvironment())
}
