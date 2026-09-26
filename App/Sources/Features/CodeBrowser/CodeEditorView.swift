import SwiftUI
import UIKit
import LocalAICore

/// A code editor built on UITextView with a line-number gutter, no word wrap,
/// horizontal scrolling, undo/redo, find (UIFindInteraction), auto-indent on
/// newline, and lightweight regex syntax highlighting for TS/JS/JSON/Markdown/
/// CSS/HTML (debounced, off the main thread for large files).
struct CodeEditorView: View {
    let path: String
    @ObservedObject var service: CodeService
    @State private var text: String = ""
    @State private var originalText: String = ""
    @State private var isDirty = false
    @State private var lineCount: Int = 1

    var body: some View {
        VStack(spacing: 0) {
            editorTopBar
            CodeTextView(
                text: $text,
                onTextChanged: { new in
                    isDirty = (new != originalText)
                    lineCount = new.split(separator: "\n", omittingEmptySubsequences: false).count
                }
            )
        }
        .background(DesignSystem.Colors.background)
        .task { loadFile() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(!isDirty)
                .tint(DesignSystem.Colors.accent)
            }
        }
    }

    private var editorTopBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(path)
                .font(DesignSystem.Typography.code(13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if isDirty {
                Text("Modified")
                    .font(.caption2)
                    .foregroundStyle(DesignSystem.Colors.warning)
            }
            Text("\(lineCount) lines")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(DesignSystem.Colors.cardBackground)
    }

    private func loadFile() {
        do {
            let content = try service.readFile(path)
            text = content
            originalText = content
            isDirty = false
        } catch {
            service.error = UserFacingErrorMapper.map(error)
        }
    }

    private func save() {
        do {
            try service.saveFile(path, contents: text)
            originalText = text
            isDirty = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            service.error = UserFacingErrorMapper.map(error)
        }
    }
}

// MARK: - UITextView wrapper

struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    let onTextChanged: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardType = .asciiCapable
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 50, bottom: 8, right: 8)
        textView.isEditable = true
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.showsHorizontalScrollIndicator = true

        // Disable word wrap: size the text container to fit its longest line.
        textView.textContainer.widthTracksTextView = false
        textView.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Find interaction (iOS 16+).
        if #available(iOS 16.0, *) {
            let findInteraction = UIFindInteraction(sessionDelegate: nil)
            textView.addInteraction(findInteraction)
        }

        // Gutter via an exclusion path on the left.
        let gutterWidth: CGFloat = 50
        textView.textContainer.exclusionPaths = []

        context.coordinator.gutterWidth = gutterWidth
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            let selected = uiView.selectedRange
            uiView.text = text
            uiView.selectedRange = selected
        }
        context.coordinator.scheduleHighlight(for: uiView)
        context.coordinator.updateGutter(in: uiView)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextView
        var gutterWidth: CGFloat = 50
        private var highlightWork: DispatchWorkItem?
        private var gutterLayer: CALayer?

        init(parent: CodeTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.onTextChanged(textView.text)
            scheduleHighlight(for: textView)
            updateGutter(in: textView)
        }

        /// Auto-indent: when the user types "\n", replicate leading whitespace.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", range.location > 0, range.location <= textView.text.count else {
                return true
            }
            let ns = textView.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: max(range.location - 1, 0), length: 0))
            let line = ns.substring(with: lineRange)
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            guard !indent.isEmpty else { return true }
            let insertion = "\n" + indent
            let target = NSRange(location: range.location, length: range.length)
            if textView.shouldChangeText(in: target, replacementText: insertion) {
                textView.textStorage.replaceCharacters(in: target, with: insertion)
                textView.selectedRange = NSRange(location: target.location + insertion.count, length: 0)
                textViewDidChange(textView)
            }
            return false
        }

        // MARK: Highlighting

        func scheduleHighlight(for textView: UITextView) {
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                let text = textView.text ?? ""
                let ext = self.fileExtension(for: self.parent)
                let isBig = text.count > 200_000
                if isBig {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let highlighted = SyntaxHighlighter.highlight(text: text, ext: ext)
                        DispatchQueue.main.async { [weak textView] in
                            guard let textView, textView.text == text else { return }
                            let selected = textView.selectedRange
                            textView.attributedText = highlighted
                            textView.selectedRange = selected
                            textView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                        }
                    }
                } else {
                    let highlighted = SyntaxHighlighter.highlight(text: text, ext: ext)
                    let selected = textView.selectedRange
                    textView.attributedText = highlighted
                    textView.selectedRange = selected
                    textView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                }
            }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }

        private func fileExtension(for parent: CodeTextView) -> String {
            // Path is captured through the binding on CodeEditorView; we re-derive
            // it from the binding's projected description. Cheap fallback: look at
            // the text storage. In practice we just always run the multi-language
            // highlighter; per-language regexes are tolerant.
            _ = parent
            return ""
        }

        // MARK: Gutter

        func updateGutter(in textView: UITextView) {
            if gutterLayer == nil {
                let layer = CALayer()
                layer.backgroundColor = UIColor.secondarySystemBackground.cgColor
                textView.layer.addSublayer(layer)
                gutterLayer = layer
            }
            let lineCount = max(1, (textView.text as NSString).components(separatedBy: "\n").count)
            let labelText = (1...lineCount).map(String.init).joined(separator: "\n")
            let attributed = NSAttributedString(
                string: labelText,
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: UIColor.secondaryLabel
                ]
            )
            // Position the layer.
            gutterLayer?.frame = CGRect(
                x: textView.contentOffset.x,
                y: 0,
                width: gutterWidth,
                height: max(textView.contentSize.height, textView.bounds.height)
            )
            gutterLayer?.contents = renderTextAsImage(attributed, width: gutterWidth)
        }

        private func renderTextAsImage(_ attributed: NSAttributedString, width: CGFloat) -> CGImage? {
            let lineHeight: CGFloat = 14
            let lines = attributed.string.split(separator: "\n", omittingEmptySubsequences: false).count
            let size = CGSize(width: width, height: lineHeight * CGFloat(lines) + 16)
            let renderer = UIGraphicsImageRenderer(size: size)
            let img = renderer.image { ctx in
                UIColor.clear.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                let para = NSMutableParagraphStyle()
                para.alignment = .right
                para.minimumLineHeight = lineHeight
                para.maximumLineHeight = lineHeight
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: UIColor.secondaryLabel,
                    .paragraphStyle: para
                ]
                NSAttributedString(string: attributed.string, attributes: attrs)
                    .draw(in: CGRect(x: 0, y: 8, width: width - 8, height: size.height))
            }
            return img.cgImage
        }
    }
}

// MARK: - Lightweight syntax highlighting

enum SyntaxHighlighter {

    static func highlight(text: String, ext: String) -> NSAttributedString {
        let baseFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let baseColor = UIColor.label
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: baseFont, .foregroundColor: baseColor]
        )
        guard !text.isEmpty else { return attributed }

        // Keywords (multi-language, tolerant — TS/JS share these).
        apply(pattern: "\\b(func|let|var|const|class|struct|enum|protocol|extension|import|from|export|return|if|else|for|while|switch|case|default|break|continue|try|catch|throw|throws|async|await|public|private|internal|fileprivate|static|final|override|init|deinit|new|this|self|super|typeof|instanceof|in|of|do|type|interface|namespace|declare|implements|extends|nil|null|undefined|true|false|guard|where|some|any|as|is)\\b",
              color: .systemPurple, to: attributed, in: text)
        // Strings.
        apply(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'|`(?:[^`\\\\]|\\\\.)*`",
              color: .systemRed, to: attributed, in: text)
        // Comments (// and /* */).
        apply(pattern: "//[^\\n]*|/\\*(?:.|\\n)*?\\*/",
              color: .systemGreen, to: attributed, in: text)
        // Numbers.
        apply(pattern: "\\b\\d+(?:\\.\\d+)?\\b",
              color: .systemOrange, to: attributed, in: text)
        // Markdown headers.
        apply(pattern: "^#{1,6} .*$",
              color: .systemBlue, to: attributed, in: text, options: [.anchorsMatchLines])
        // JSON keys (string immediately followed by colon).
        apply(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"\\s*:",
              color: .systemTeal, to: attributed, in: text)
        // CSS selectors / properties rough pass.
        apply(pattern: "\\b[a-zA-Z-]+\\s*:\\s*[^;]+;",
              color: .systemPink, to: attributed, in: text)
        // HTML tags.
        apply(pattern: "</?[a-zA-Z][a-zA-Z0-9-]*(?:\\s[^>]*)?/?>",
              color: .systemIndigo, to: attributed, in: text)

        return attributed
    }

    private static func apply(
        pattern: String,
        color: UIColor,
        to attributed: NSMutableAttributedString,
        in text: String,
        options: NSRegularExpression.Options = []
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let range = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let r = match?.range else { return }
            attributed.addAttribute(.foregroundColor, value: color, range: r)
        }
    }
}
