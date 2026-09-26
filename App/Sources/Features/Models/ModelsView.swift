import SwiftUI
import UIKit
import LocalAICore

/// Models tab: paste a Hugging Face URL, view compatibility, download, manage,
/// load into the MLX engine, and try the active model with a small prompt.
struct ModelsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var service: ModelService

    @State private var urlInput: String = ""
    @State private var tryPrompt: String = ""
    @State private var tryOutput: String = ""
    @State private var isTrying = false
    @State private var tryTask: Task<Void, Never>?
    @State private var showTrySheet = false
    @State private var pendingDeleteID: String?

    init(service: ModelService) {
        _service = StateObject(wrappedValue: service)
    }

    var body: some View {
        NavigationStack {
            List {
                pasteSection
                if !service.rows.isEmpty {
                    Section("Models") {
                        ForEach(service.rows) { row in
                            ModelRowView(
                                row: row,
                                onDownload: { Task { await service.startDownload(rowID: row.id) } },
                                onPause: { Task { await service.pauseDownload() } },
                                onResume: { Task { await service.resumeDownload() } },
                                onCancel: { Task { await service.cancelDownload() } },
                                onUse: { Task { await service.useModel(row.id) } },
                                onUnload: { Task { await service.unloadActiveModel() } },
                                onDelete: { pendingDeleteID = row.id },
                                onOpenHF: {
                                    if let url = URL(string: "https://huggingface.co/\(row.repo.id)") {
                                        UIApplication.shared.open(url)
                                    }
                                }
                            )
                        }
                    }
                } else {
                    Section {
                        ContentUnavailableView(
                            "No models yet",
                            systemImage: "cube",
                            description: Text("Paste a Hugging Face model URL above to see size, memory needs, and download it for on-device inference.")
                        )
                        .listRowBackground(Color.clear)
                    }
                }

                if service.activeModelID != nil {
                    Section("Active model") {
                        Button {
                            showTrySheet = true
                        } label: {
                            Label("Try model", systemImage: "play.circle")
                        }
                        Button(role: .destructive) {
                            Task { await service.unloadActiveModel() }
                        } label: {
                            Label("Unload", systemImage: "eject")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Models")
            .background(DesignSystem.Colors.background)
            .task { await service.refreshDownloaded() }
            .refreshable { await service.refreshDownloaded() }
            .alert(item: $service.error) { uf in
                alert(for: uf)
            }
            .alert("Delete model?", isPresented: Binding(
                get: { pendingDeleteID != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let id = pendingDeleteID {
                        Task { await service.deleteModel(id) }
                    }
                    pendingDeleteID = nil
                }
                Button("Cancel", role: .cancel) { pendingDeleteID = nil }
            } message: {
                Text("This removes the model from on-device storage.")
            }
            .sheet(isPresented: $showTrySheet) {
                trySheet
            }
        }
    }

    private var pasteSection: some View {
        Section {
            HStack(spacing: DesignSystem.Spacing.sm) {
                TextField("https://huggingface.co/org/name", text: $urlInput)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(DesignSystem.Typography.code())
                Button {
                    let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !url.isEmpty else { return }
                    urlInput = ""
                    Task { await service.inspect(urlString: url) }
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                }
                .tint(DesignSystem.Colors.accent)
                .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Fetch model info")
            }
        } header: {
            Text("Add from Hugging Face")
        } footer: {
            Text("MLX-format models work on device. GGUF is not yet supported.")
                .font(DesignSystem.Typography.caption)
        }
    }

    private var trySheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                TextField("Ask anything…", text: $tryPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                HStack {
                    Button {
                        startTry()
                    } label: {
                        Label("Generate", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.accent)
                    .disabled(tryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTrying)

                    if isTrying {
                        Button(role: .cancel) {
                            tryTask?.cancel()
                            isTrying = false
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                ScrollView {
                    Text(tryOutput.isEmpty ? "Tokens will stream here." : tryOutput)
                        .font(DesignSystem.Typography.code())
                        .foregroundStyle(tryOutput.isEmpty ? DesignSystem.Colors.secondaryText : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .padding(DesignSystem.Spacing.md)
            .navigationTitle("Try model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        tryTask?.cancel()
                        showTrySheet = false
                    }
                }
            }
        }
    }

    private func startTry() {
        tryOutput = ""
        isTrying = true
        let prompt = tryPrompt
        let engine = service.engine
        tryTask = Task {
            let stream = await engine.generate(
                messages: [ChatMessage(role: .user, content: prompt)],
                parameters: .default
            )
            do {
                for try await chunk in stream {
                    await MainActor.run { tryOutput += chunk }
                }
            } catch {
                await MainActor.run {
                    service.error = UserFacingErrorMapper.map(error)
                }
            }
            await MainActor.run { isTrying = false }
        }
    }

    private func alert(for uf: UserFacingError) -> Alert {
        switch uf.recoveryAction {
        case .openURL(let url):
            return Alert(
                title: Text(uf.title),
                message: Text(uf.message),
                primaryButton: .default(Text("Open Hugging Face")) {
                    UIApplication.shared.open(url)
                },
                secondaryButton: .cancel()
            )
        case .retry:
            return Alert(
                title: Text(uf.title),
                message: Text(uf.message),
                primaryButton: .default(Text("Retry")) {
                    if let last = service.rows.last {
                        Task { await service.inspect(urlString: last.repo.id) }
                    }
                },
                secondaryButton: .cancel()
            )
        default:
            return Alert(
                title: Text(uf.title),
                message: Text(uf.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

// MARK: - Row view

struct ModelRowView: View {
    let row: ModelRow
    let onDownload: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onUse: () -> Void
    let onUnload: () -> Void
    let onDelete: () -> Void
    let onOpenHF: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            header
            content
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(row.repo.id)
                .font(DesignSystem.Typography.headline)
                .lineLimit(1)
            Spacer()
            statusBadge
        }
    }

    private var statusBadge: some View {
        Group {
            switch row.state {
            case .active:
                Label("ACTIVE", systemImage: "checkmark.circle.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DesignSystem.Colors.success)
            case .downloaded:
                Label("Downloaded", systemImage: "arrow.down.circle.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DesignSystem.Colors.accent)
            case .downloading(let progress):
                Text(progress.state.rawValue.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DesignSystem.Colors.accent)
            case .failed:
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DesignSystem.Colors.destructive)
            case .inspected:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch row.state {
        case .inspected(let report):
            inspectedContent(report)
        case .downloading(let progress):
            downloadingContent(progress)
        case .downloaded(let model):
            downloadedContent(model)
        case .active(let model):
            activeContent(model)
        case .failed(let message):
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(message)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.destructive)
                HStack {
                    Button("Dismiss", action: onCancel)
                    Spacer()
                }
            }
        }
    }

    private func inspectedContent(_ report: ModelCompatibilityReport) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            if let info = row.info {
                HStack(spacing: DesignSystem.Spacing.md) {
                    if let params = report.parameterCountBillions {
                        Text(String(format: "%.1fB params", params))
                    }
                    if let bits = report.quantizationBits {
                        Text("\(bits)-bit")
                    }
                    Text(report.format.rawValue.uppercased())
                }
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.secondaryText)

                if info.gated {
                    Label("Gated — accept terms on Hugging Face first.", systemImage: "lock.fill")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.warning)
                    Button("Open Hugging Face", action: onOpenHF)
                        .font(DesignSystem.Typography.caption)
                }
            }

            HStack {
                VStack(alignment: .leading) {
                    Text("Download").font(.caption2).foregroundStyle(.secondary)
                    Text(formatBytes(report.downloadBytes)).font(DesignSystem.Typography.caption)
                }
                Spacer()
                VStack(alignment: .leading) {
                    Text("Est. memory").font(.caption2).foregroundStyle(.secondary)
                    Text(formatBytes(report.estimatedMemoryBytes)).font(DesignSystem.Typography.caption)
                }
            }

            verdictLine(report.verdict)

            HStack {
                Button(action: onDownload) {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.accent)
                .disabled(isUnsupported(report.verdict))
            }
        }
    }

    @ViewBuilder
    private func verdictLine(_ verdict: CompatibilityVerdict) -> some View {
        switch verdict {
        case .compatible:
            Label("Should run on this device.", systemImage: "checkmark.circle.fill")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.success)
        case .mayNotRunReliably(let estimated, let ram):
            Label("May not run reliably on this device (needs ~\(formatBytes(estimated)), has \(formatBytes(ram))).",
                  systemImage: "exclamationmark.triangle.fill")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.warning)
        case .unsupportedFormat(let reason):
            Label(reason, systemImage: "xmark.octagon.fill")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.destructive)
        case .insufficientStorage(let needed, let available):
            Label("Not enough free storage (need \(formatBytes(needed)), have \(formatBytes(available))).",
                  systemImage: "externaldrive.fill.badge.exclamationmark")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.destructive)
        }
    }

    private func isUnsupported(_ verdict: CompatibilityVerdict) -> Bool {
        if case .unsupportedFormat = verdict { return true }
        return false
    }

    private func downloadingContent(_ progress: DownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            ProgressView(value: Double(progress.bytesDownloaded),
                         total: max(Double(progress.totalBytes), 1))
                .tint(DesignSystem.Colors.accent)
            HStack {
                Text("\(formatBytes(progress.bytesDownloaded)) / \(formatBytes(progress.totalBytes))")
                    .font(DesignSystem.Typography.caption)
                Spacer()
                Text("\(formatBytes(Int64(progress.bytesPerSecond)))/s")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
            }
            if !progress.currentFile.isEmpty {
                Text(progress.currentFile)
                    .font(.caption2)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                    .lineLimit(1)
            }
            HStack(spacing: DesignSystem.Spacing.md) {
                switch progress.state {
                case .running:
                    Button(action: onPause) { Label("Pause", systemImage: "pause.fill") }
                        .buttonStyle(.bordered)
                case .paused:
                    Button(action: onResume) { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(.bordered)
                case .failed:
                    Button(action: onResume) { Label("Retry", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                default:
                    EmptyView()
                }
                Spacer()
                Button(role: .destructive, action: onCancel) {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
            }
            .font(DesignSystem.Typography.caption)
        }
    }

    private func downloadedContent(_ model: DownloadedModel) -> some View {
        HStack {
            Text(formatBytes(model.totalBytes))
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.secondaryText)
            Spacer()
            Button("Use model", action: onUse)
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.accent)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
        }
    }

    private func activeContent(_ model: DownloadedModel) -> some View {
        HStack {
            Text(formatBytes(model.totalBytes))
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.secondaryText)
            Spacer()
            Button("Unload", action: onUnload)
                .buttonStyle(.bordered)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
