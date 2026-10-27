import UIKit

/// The font the app draws its text in. Stored by `rawValue`, so entries can be renamed freely.
enum FlowFontChoice: String, CaseIterable {
    case system
    case condensed
    case serif

    var displayName: String {
        switch self {
        case .system: return "System"
        case .condensed: return "Condensed"
        case .serif: return "Serif"
        }
    }

    /// The family this choice resolves to on iOS 12.
    var family: String {
        switch self {
        case .system: return UIFont.systemFont(ofSize: 17.0).familyName
        case .condensed: return "HelveticaNeue-CondensedBold"
        case .serif: return "Georgia"
        }
    }
}

/// The app's type scale: Material 3's fifteen roles at the sizes `docs/PORT_SPEC.md` binds, set in
/// the user's chosen family, scaled by Dynamic Type through `UIFontMetrics`.
enum FlowTypography {

    /// Set by `FlowTheme.applyFont`. Read on every style request.
    static var activeChoice: FlowFontChoice = .system

    // MARK: - Families

    static func family(for choice: FlowFontChoice) -> String {
        return choice.family
    }

    /// A font at `size` in the active family, falling back to the system font when the named face
    /// is missing on this device.
    static func font(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        switch activeChoice {
        case .system:
            return UIFont.systemFont(ofSize: size, weight: weight)
        case .condensed:
            if let named = UIFont(name: "HelveticaNeue-CondensedBold", size: size) {
                return named
            }
            return UIFont.systemFont(ofSize: size, weight: weight)
        case .serif:
            if let named = UIFont(name: "Georgia", size: size) {
                return named
            }
            return UIFont.systemFont(ofSize: size, weight: weight)
        }
    }

    /// A scaled font: the base size grows with the user's text-size setting.
    static func scaled(size: CGFloat, weight: UIFont.Weight, textStyle: UIFont.TextStyle) -> UIFont {
        let base = font(size: size, weight: weight)
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: base)
    }

    // MARK: - Roles

    static var displayLarge: UIFont { return scaled(size: 57.0, weight: .bold, textStyle: .largeTitle) }
    static var displayMedium: UIFont { return scaled(size: 45.0, weight: .bold, textStyle: .largeTitle) }
    static var displaySmall: UIFont { return scaled(size: 36.0, weight: .bold, textStyle: .largeTitle) }

    static var headlineLarge: UIFont { return scaled(size: 32.0, weight: .semibold, textStyle: .title1) }
    static var headlineMedium: UIFont { return scaled(size: 28.0, weight: .semibold, textStyle: .title1) }
    static var headlineSmall: UIFont { return scaled(size: 24.0, weight: .semibold, textStyle: .title2) }

    static var titleLarge: UIFont { return scaled(size: 22.0, weight: .medium, textStyle: .title2) }
    static var titleMedium: UIFont { return scaled(size: 16.0, weight: .medium, textStyle: .headline) }
    static var titleSmall: UIFont { return scaled(size: 14.0, weight: .medium, textStyle: .subheadline) }

    static var bodyLarge: UIFont { return scaled(size: 16.0, weight: .regular, textStyle: .body) }
    static var bodyMedium: UIFont { return scaled(size: 14.0, weight: .regular, textStyle: .subheadline) }
    static var bodySmall: UIFont { return scaled(size: 12.0, weight: .regular, textStyle: .footnote) }

    static var labelLarge: UIFont { return scaled(size: 14.0, weight: .medium, textStyle: .subheadline) }
    static var labelMedium: UIFont { return scaled(size: 12.0, weight: .medium, textStyle: .footnote) }
    static var labelSmall: UIFont { return scaled(size: 11.0, weight: .medium, textStyle: .caption2) }

    // MARK: - Emphasized variants

    static var displayLargeEmphasized: UIFont { return scaled(size: 57.0, weight: .heavy, textStyle: .largeTitle) }
    static var displayMediumEmphasized: UIFont { return scaled(size: 45.0, weight: .heavy, textStyle: .largeTitle) }
    static var displaySmallEmphasized: UIFont { return scaled(size: 36.0, weight: .bold, textStyle: .largeTitle) }
    static var headlineLargeEmphasized: UIFont { return scaled(size: 32.0, weight: .bold, textStyle: .title1) }
    static var headlineMediumEmphasized: UIFont { return scaled(size: 28.0, weight: .bold, textStyle: .title1) }
    static var headlineSmallEmphasized: UIFont { return scaled(size: 24.0, weight: .bold, textStyle: .title2) }
    static var titleLargeEmphasized: UIFont { return scaled(size: 22.0, weight: .semibold, textStyle: .title2) }
    static var titleMediumEmphasized: UIFont { return scaled(size: 16.0, weight: .semibold, textStyle: .headline) }
    static var titleSmallEmphasized: UIFont { return scaled(size: 14.0, weight: .semibold, textStyle: .subheadline) }
    static var bodyLargeEmphasized: UIFont { return scaled(size: 16.0, weight: .medium, textStyle: .body) }
    static var bodyMediumEmphasized: UIFont { return scaled(size: 14.0, weight: .medium, textStyle: .subheadline) }
    static var bodySmallEmphasized: UIFont { return scaled(size: 12.0, weight: .medium, textStyle: .footnote) }
    static var labelLargeEmphasized: UIFont { return scaled(size: 14.0, weight: .semibold, textStyle: .subheadline) }
    static var labelMediumEmphasized: UIFont { return scaled(size: 12.0, weight: .semibold, textStyle: .footnote) }
    static var labelSmallEmphasized: UIFont { return scaled(size: 11.0, weight: .semibold, textStyle: .caption2) }

    // MARK: - Line heights

    /// The line height Material assigns each role, as a multiple of the font size. Applied through
    /// `NSMutableParagraphStyle` so multi-line labels keep Material's rhythm.
    static func lineHeight(for size: CGFloat) -> CGFloat {
        switch size {
        case 57.0: return 64.0
        case 45.0: return 52.0
        case 36.0: return 44.0
        case 32.0: return 40.0
        case 28.0: return 36.0
        case 24.0: return 32.0
        case 22.0: return 28.0
        case 16.0: return 24.0
        case 14.0: return 20.0
        case 12.0: return 16.0
        case 11.0: return 16.0
        default: return (size * 1.35).rounded()
        }
    }

    /// Letter spacing Material assigns each role, in points.
    static func letterSpacing(for size: CGFloat) -> CGFloat {
        switch size {
        case 57.0, 45.0, 36.0, 32.0, 28.0, 24.0, 22.0: return 0.0
        case 16.0: return 0.15
        case 14.0: return 0.1
        case 12.0: return 0.4
        case 11.0: return 0.5
        default: return 0.0
        }
    }

    /// A paragraph style carrying this role's line height and spacing.
    static func paragraphStyle(size: CGFloat, alignment: NSTextAlignment = .natural) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.minimumLineHeight = lineHeight(for: size)
        style.maximumLineHeight = lineHeight(for: size)
        return style
    }

    /// Applies a role to a label, including line height and letter spacing.
    static func apply(_ font: UIFont, size: CGFloat, to label: UILabel, color: UIColor) {
        let paragraph = paragraphStyle(size: size)
        let attributed = NSMutableAttributedString(string: label.text ?? "")
        let range = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.font, value: font, range: range)
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)
        attributed.addAttribute(.kern, value: letterSpacing(for: size), range: range)
        attributed.addAttribute(.foregroundColor, value: color, range: range)
        label.attributedText = attributed
    }
}

/// Convenience constructors so screens read like Material rather than like font plumbing.
extension UILabel {
    /// Creates a label in one of the app's roles, already coloured.
    static func flow(_ text: String, font: UIFont, color: UIColor, lines: Int = 1) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = lines
        return label
    }
}
