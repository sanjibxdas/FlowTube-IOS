import UIKit
import Foundation

// MARK: - Colour

extension UIColor {
    /// Builds an opaque colour from a 24-bit RGB literal, e.g. 0xFF0000.
    convenience init(hex: UInt32) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255.0
        let green = CGFloat((hex >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hex & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue, alpha: 1.0)
    }

    /// Builds a colour from a 32-bit ARGB literal, e.g. 0x80FF0000.
    convenience init(argb: UInt32) {
        let alpha = CGFloat((argb >> 24) & 0xFF) / 255.0
        let red = CGFloat((argb >> 16) & 0xFF) / 255.0
        let green = CGFloat((argb >> 8) & 0xFF) / 255.0
        let blue = CGFloat(argb & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Parses "#RRGGBB", "#AARRGGBB" or the same without the hash. Returns nil for anything else.
    convenience init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") {
            text = String(text.dropFirst())
        }
        if text.count == 3 {
            var expanded = ""
            for character in text {
                expanded.append(character)
                expanded.append(character)
            }
            text = expanded
        }
        guard text.count == 6 || text.count == 8 else { return nil }
        guard let value = UInt32(text, radix: 16) else { return nil }
        if text.count == 8 {
            self.init(argb: value)
        } else {
            self.init(hex: value)
        }
    }

    /// The colour as "#RRGGBBAA", matching the format the export files use.
    var hexString: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            let r = Int((red * 255.0).rounded())
            let g = Int((green * 255.0).rounded())
            let b = Int((blue * 255.0).rounded())
            let a = Int((alpha * 255.0).rounded())
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        }
        var white: CGFloat = 0
        if getWhite(&white, alpha: &alpha) {
            let w = Int((white * 255.0).rounded())
            let a = Int((alpha * 255.0).rounded())
            return String(format: "#%02X%02X%02X%02X", w, w, w, a)
        }
        return "#00000000"
    }

    /// The colour's channels, or nil when it cannot be expressed in RGB.
    var rgbaComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return (red, green, blue, alpha)
    }

    /// CSS `color-mix(in srgb, self amount, other)`: `amount` of the receiver, the rest of `other`.
    /// Mixing is premultiplied, so mixing with a transparent colour only lowers the opacity.
    func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
        let t = min(max(amount, 0.0), 1.0)
        guard let first = rgbaComponents, let second = other.rgbaComponents else { return self }
        if first.alpha >= 1.0 && second.alpha >= 1.0 {
            return UIColor(
                red: first.red * t + second.red * (1.0 - t),
                green: first.green * t + second.green * (1.0 - t),
                blue: first.blue * t + second.blue * (1.0 - t),
                alpha: 1.0
            )
        }
        let firstWeight = first.alpha * t
        let secondWeight = second.alpha * (1.0 - t)
        let alpha = firstWeight + secondWeight
        if alpha <= 0.0 { return UIColor.clear }
        func channel(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let value = (a * firstWeight + b * secondWeight) / alpha
            return min(max(value, 0.0), 1.0)
        }
        return UIColor(
            red: channel(first.red, second.red),
            green: channel(first.green, second.green),
            blue: channel(first.blue, second.blue),
            alpha: alpha
        )
    }

    /// The receiver composited over `ground`. Contrast is only meaningful between opaque colours.
    func opaqueOver(_ ground: UIColor) -> UIColor {
        guard let components = rgbaComponents, components.alpha < 1.0 else { return self }
        guard let back = ground.rgbaComponents else { return self }
        let alpha = components.alpha
        return UIColor(
            red: components.red * alpha + back.red * (1.0 - alpha),
            green: components.green * alpha + back.green * (1.0 - alpha),
            blue: components.blue * alpha + back.blue * (1.0 - alpha),
            alpha: 1.0
        )
    }

    /// Relative luminance as WCAG defines it. Used to pick readable content colours.
    var relativeLuminance: CGFloat {
        guard let components = rgbaComponents else { return 0.0 }
        func linear(_ value: CGFloat) -> CGFloat {
            if value <= 0.03928 { return value / 12.92 }
            return pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(components.red) + 0.7152 * linear(components.green) + 0.0722 * linear(components.blue)
    }

    /// Black or white, whichever reads better on the receiver.
    var readableContentColor: UIColor {
        return relativeLuminance > 0.179 ? UIColor.black : UIColor.white
    }

    /// WCAG contrast ratio between two opaque colours.
    static func contrastRatio(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let a = first.relativeLuminance
        let b = second.relativeLuminance
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Nudges the receiver towards black or white until it reaches `ratio` against `background`,
    /// keeping the hue. Mirrors the Kotlin `ensureContrastOn` used for `inversePrimary`.
    func adjustedForContrast(against background: UIColor, ratio: CGFloat) -> UIColor {
        let ground = background.opaqueOver(UIColor.black)
        if UIColor.contrastRatio(self, ground) >= ratio { return self }
        let target = ground.readableContentColor
        var low: CGFloat = 0.0
        var high: CGFloat = 1.0
        var best = self
        for _ in 0..<12 {
            let middle = (low + high) / 2.0
            let candidate = self.mixed(with: target, amount: middle)
            if UIColor.contrastRatio(candidate, ground) >= ratio {
                best = candidate
                high = middle
            } else {
                low = middle
            }
        }
        return best
    }

    /// A copy with a different alpha.
    func withAlpha(_ alpha: CGFloat) -> UIColor {
        return withAlphaComponent(min(max(alpha, 0.0), 1.0))
    }
}

// MARK: - Geometry and layout

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }

    /// Rounds to the nearest whole pixel for the given screen scale.
    func roundedToPixel(scale: CGFloat = UIScreen.main.scale) -> CGFloat {
        return (self * scale).rounded() / scale
    }
}

extension UIView {
    /// Adds `subview` and turns off its autoresizing translation in one step.
    func addSubviewForAutoLayout(_ subview: UIView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subview)
    }

    /// Pins `subview` to all four edges, optionally inset.
    func pinEdges(of subview: UIView, insets: UIEdgeInsets = .zero) {
        addSubviewForAutoLayout(subview)
        NSLayoutConstraint.activate([
            subview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            subview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            subview.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            subview.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }

    /// A rounded-corner mask that survives bounds changes, unlike `layer.cornerRadius` on a
    /// view whose size is still zero when the radius is set.
    func applyCornerRadius(_ radius: CGFloat, maskedCorners: CACornerMask? = nil) {
        layer.cornerRadius = radius
        layer.masksToBounds = true
        if let corners = maskedCorners {
            layer.maskedCorners = corners
        }
    }

    /// The view's own tinted background, used by cards and sheets.
    func applyBackground(_ color: UIColor) {
        backgroundColor = color
    }

    /// Fades the view in over `duration`, honouring Reduce Motion.
    func fadeIn(duration: TimeInterval = FlowMotion.standard) {
        if UIAccessibility.isReduceMotionEnabled {
            alpha = 1.0
            return
        }
        alpha = 0.0
        UIView.animate(withDuration: duration, delay: 0.0, options: [.curveEaseOut], animations: {
            self.alpha = 1.0
        }, completion: nil)
    }

    /// A one-pixel hairline that follows the screen scale.
    static func hairline() -> UIView {
        let line = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        let thickness = 1.0 / UIScreen.main.scale
        line.heightAnchor.constraint(equalToConstant: thickness).isActive = true
        return line
    }
}

extension UIViewController {
    /// The controller currently on top of the receiver's presented stack, if any.
    var flowTopMost: UIViewController {
        if let presented = presentedViewController {
            return presented.flowTopMost
        }
        if let navigation = self as? UINavigationController, let visible = navigation.visibleViewController {
            return visible.flowTopMost
        }
        if let tabs = self as? UITabBarController, let selected = tabs.selectedViewController {
            return selected.flowTopMost
        }
        return self
    }

    /// Presents `controller` from the top-most controller, ignoring a request that is already in flight.
    func flowPresent(_ controller: UIViewController, animated: Bool = true, completion: (() -> Void)? = nil) {
        let host = flowTopMost
        guard host.presentedViewController == nil else { return }
        host.present(controller, animated: animated, completion: completion)
    }
}

extension UIEdgeInsets {
    static func all(_ value: CGFloat) -> UIEdgeInsets {
        return UIEdgeInsets(top: value, left: value, bottom: value, right: value)
    }

    static func horizontal(_ horizontal: CGFloat, vertical: CGFloat) -> UIEdgeInsets {
        return UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
}

// MARK: - Strings

extension String {
    var trimmed: String {
        return trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isBlank: Bool {
        return trimmed.isEmpty
    }

    /// Truncates to `limit` characters, appending an ellipsis when it had to cut.
    func truncated(to limit: Int) -> String {
        guard limit > 0, count > limit else { return self }
        return String(prefix(limit - 1)) + "\u{2026}"
    }

    /// A stable non-negative hash, used for cache keys and deterministic placeholder colours.
    var stableHash: UInt64 {
        var hash: UInt64 = 5381
        for byte in utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return hash
    }

    /// Percent-encodes a value for use in a query string, including "+" and "&".
    var queryEncoded: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }

    /// True when the string is a YouTube video id: exactly eleven URL-safe characters.
    var looksLikeVideoID: Bool {
        guard count == 11 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return rangeOfCharacter(from: allowed.inverted) == nil
    }
}

extension Optional where Wrapped == String {
    var orEmpty: String {
        return self ?? ""
    }
}

extension Array {
    /// The element at `index`, or nil instead of a crash.
    func element(at index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}

extension Collection {
    var isNotEmpty: Bool {
        return !isEmpty
    }
}

// MARK: - Numbers

extension Int {
    /// 1234 -> "1.2K", matching the Android compact formatter.
    var compactCount: String {
        return Formatters.compactCount(self)
    }
}

extension TimeInterval {
    /// mm:ss, or h:mm:ss once the duration passes an hour.
    var playbackTime: String {
        return Formatters.playbackTime(self)
    }
}

// MARK: - Dates

extension Date {
    var startOfDay: Date {
        return Calendar.current.startOfDay(for: self)
    }

    func addingDays(_ days: Int) -> Date {
        return Calendar.current.date(byAdding: .day, value: days, to: self) ?? self
    }

    var isToday: Bool {
        return Calendar.current.isDateInToday(self)
    }

    var isYesterday: Bool {
        return Calendar.current.isDateInYesterday(self)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let flowThemeDidChange = Notification.Name("FlowThemeDidChange")
    static let flowPlaybackStateDidChange = Notification.Name("FlowPlaybackStateDidChange")
    static let flowHistoryDidChange = Notification.Name("FlowHistoryDidChange")
    static let flowSubscriptionsDidChange = Notification.Name("FlowSubscriptionsDidChange")
    static let flowPlaylistsDidChange = Notification.Name("FlowPlaylistsDidChange")
    static let flowDownloadsDidChange = Notification.Name("FlowDownloadsDidChange")
    static let flowNotesDidChange = Notification.Name("FlowNotesDidChange")
    static let flowPrefsDidChange = Notification.Name("FlowPrefsDidChange")
    static let flowImageCacheDidClear = Notification.Name("FlowImageCacheDidClear")
}
