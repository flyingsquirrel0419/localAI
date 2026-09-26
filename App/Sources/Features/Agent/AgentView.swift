import SwiftUI
import LocalAICore

/// Agent tab: minimal chat that streams from the active MLX model.
/// Tool use and the agent loop arrive in a later phase — this is an honest
/// chat against the loaded model.
struct AgentChatView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var modelService: ModelService

    @State private var messages: [ChatMessage] = []
    @State private var input: String = ""
    @State private var isGenerating = false
    @State private var currentTask: Task<Void, Never>?
    @State private var error: UserFacingError?

    var body: some View {
        VStack(spacing: 0) {
            if modelService.activeModelID == nil {
                Spacer()
                ContentUnavailableView(
                    "No active model",
                    systemImage: "cube",
                    description: Text("Open the Models tab, download a model, then tap \"Use model\" to start chatting.")
                )
                Spacer()
            } else {
                chatList
                inputBar
            }
        }
        .background(DesignSystem.Colors.background)
        .alert(item: $error) { uf in
            Alert(title: Text(uf.title), message: Text(uf.message), dismissButton: .default(Text("OK")))
        }
    }

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(DesignSystem.Spacing.md)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            TextField("Message", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
            if isGenerating {
                Button {
                    currentTask?.cancel()
                    isGenerating = false
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                }
                .tint(DesignSystem.Colors.destructive)
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .tint(DesignSystem.Colors.accent)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.cardBackground)
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, content: ""))

        isGenerating = true
        let engine = modelService.engine
        let history = messages
        currentTask = Task {
            let stream = await engine.generate(messages: history, parameters: .default)
            var received = ""
            do {
                for try await chunk in stream {
                    received += chunk
                    await MainActor.run {
                        if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                            messages[index].content = received
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.error = UserFacingErrorMapper.map(error)
                }
            }
            await MainActor.run { isGenerating = false }
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            Text(message.content.isEmpty && message.role == .assistant ? "…" : message.content)
                .font(DesignSystem.Typography.body)
                .padding(DesignSystem.Spacing.sm)
                .background(backgroundColor)
                .foregroundStyle(foregroundColor)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.card))
                .textSelection(.enabled)
            if message.role != .user { Spacer(minLength: 32) }
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user: return DesignSystem.Colors.accent
        case .assistant: return DesignSystem.Colors.cardBackground
        case .system, .tool: return Color.orange.opacity(0.15)
        }
    }

    private var foregroundColor: Color {
        switch message.role {
        case .user: return .white
        default: return .primary
        }
    }
}
