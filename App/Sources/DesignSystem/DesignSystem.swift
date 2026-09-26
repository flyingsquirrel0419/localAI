import SwiftUI

/// Design tokens for consistent spacing, radius, color, and typography.
enum DesignSystem {
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 12
        static let sheet: CGFloat = 16
    }

    enum Colors {
        /// Single accent used for primary actions and highlights.
        static let accent = Color.indigo
        static let cardBackground = Color(uiColor: .secondarySystemBackground)
        static let background = Color(uiColor: .systemBackground)
        static let secondaryText = Color.secondary
        static let destructive = Color.red
        static let success = Color.green
        static let warning = Color.orange
    }

    enum Typography {
        static func code(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }

        static let title = Font.title2.weight(.semibold)
        static let headline = Font.headline
        static let body = Font.body
        static let caption = Font.caption
    }
}

/// Small status glyph used across the app.
struct StatusIcon: View {
    enum Kind {
        case running
        case done
        case failed

        var symbol: String {
            switch self {
            case .running: return "●"
            case .done: return "✓"
            case .failed: return "!"
            }
        }

        var color: Color {
            switch self {
            case .running: return DesignSystem.Colors.accent
            case .done: return DesignSystem.Colors.success
            case .failed: return DesignSystem.Colors.destructive
            }
        }
    }

    let kind: Kind

    init(_ kind: Kind) { self.kind = kind }

    var body: some View {
        Text(kind.symbol)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(kind.color)
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch kind {
        case .running: return "Running"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }
}
