import SwiftUI

// MARK: - App Theme

struct Theme {

    // MARK: Colours
    struct Colors {
        static let background       = Color(hex: "#0A0A0F")
        static let surface          = Color(hex: "#13131A")
        static let surfaceElevated  = Color(hex: "#1C1C28")
        static let accent            = Color(hex: "#7C5CFC")   // deep purple
        static let accentSecondary  = Color(hex: "#FC5CA0")   // pink
        static let safe             = Color(hex: "#34D399")   // green — safe to delete
        static let review           = Color(hex: "#FBBF24")   // amber — review
        static let keep             = Color(hex: "#60A5FA")   // blue — keep
        static let danger           = Color(hex: "#F87171")   // red — destructive
        static let textPrimary      = Color.white
        static let textSecondary    = Color(hex: "#A0A0B8")
        static let textTertiary     = Color(hex: "#5A5A72")
        static let separator        = Color(hex: "#2A2A38")
    }

    // MARK: Gradients
    struct Gradients {
        static let accent = LinearGradient(
            colors: [Colors.accent, Colors.accentSecondary],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        static let safe = LinearGradient(
            colors: [Color(hex: "#10B981"), Color(hex: "#34D399")],
            startPoint: .leading, endPoint: .trailing
        )
        static let danger = LinearGradient(
            colors: [Color(hex: "#EF4444"), Color(hex: "#F87171")],
            startPoint: .leading, endPoint: .trailing
        )
        static let darkCard = LinearGradient(
            colors: [Colors.surface, Colors.surfaceElevated],
            startPoint: .top, endPoint: .bottom
        )
    }

    // MARK: Typography
    struct Typography {
        static let largeTitle = Font.system(size: 34, weight: .bold, design: .rounded)
        static let title      = Font.system(size: 22, weight: .bold, design: .rounded)
        static let headline   = Font.system(size: 17, weight: .semibold, design: .rounded)
        static let body       = Font.system(size: 15, weight: .regular, design: .rounded)
        static let caption    = Font.system(size: 12, weight: .medium, design: .rounded)
        static let tiny       = Font.system(size: 10, weight: .semibold, design: .rounded)
    }

    // MARK: Spacing
    struct Spacing {
        static let xs: CGFloat   = 4
        static let sm: CGFloat   = 8
        static let md: CGFloat   = 16
        static let lg: CGFloat   = 24
        static let xl: CGFloat   = 32
        static let xxl: CGFloat  = 48
    }

    // MARK: Corners
    struct Radius {
        static let sm: CGFloat   = 8
        static let md: CGFloat   = 14
        static let lg: CGFloat   = 20
        static let xl: CGFloat   = 28
        static let pill: CGFloat = 999
    }
}

// MARK: - Color Hex Init

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        let int = UInt64(hex, radix: 16) ?? 0
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Confidence Color

extension GroupConfidence {
    var themeColor: Color {
        switch self {
        case .safeToDelete:      return Theme.Colors.safe
        case .reviewRecommended: return Theme.Colors.review
        case .keepRecommended:   return Theme.Colors.keep
        }
    }
}
