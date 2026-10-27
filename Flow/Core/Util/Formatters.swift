import Foundation
import UIKit

/// Number, duration and date formatting shared by every screen, so a count never reads two
/// different ways in two places. Mirrors the Android `YouTubeCountParser` and `CompactNumberSuffixes`.
enum Formatters {

    // MARK: - Counts

    private static let compactSuffixes: [(threshold: Double, divisor: Double, suffix: String)] = [
        (1_000_000_000_000, 1_000_000_000_000, "T"),
        (1_000_000_000, 1_000_000_000, "B"),
        (1_000_000, 1_000_000, "M"),
        (1_000, 1_000, "K"),
    ]

    /// 1_234 -> "1.2K", 12_345_678 -> "12M", 999 -> "999".
    static func compactCount(_ value: Int) -> String {
        if value < 0 { return "0" }
        let magnitude = Double(value)
        for entry in compactSuffixes {
            if magnitude >= entry.threshold {
                let scaled = magnitude / entry.divisor
                if scaled >= 100.0 {
                    return String(format: "%.0f%@", scaled, entry.suffix)
                }
                if scaled >= 10.0 {
                    let rounded = (scaled * 10.0).rounded() / 10.0
                    if rounded == rounded.rounded() {
                        return String(format: "%.0f%@", rounded, entry.suffix)
                    }
                    return String(format: "%.1f%@", rounded, entry.suffix)
                }
                let rounded = (scaled * 10.0).rounded() / 10.0
                return String(format: "%.1f%@", rounded, entry.suffix)
            }
        }
        return String(value)
    }

    /// "1,234,567" with the user's grouping separator.
    static func groupedCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// The Android app's "1.2K views" / "1 view" wording.
    static func viewCount(_ value: Int) -> String {
        if value < 0 { return "" }
        let amount = compactCount(value)
        return value == 1 ? "1 view" : "\(amount) views"
    }

    /// The Android app's "1.2K subscribers" wording.
    static func subscriberCount(_ value: Int) -> String {
        if value < 0 { return "" }
        let amount = compactCount(value)
        return value == 1 ? "1 subscriber" : "\(amount) subscribers"
    }

    // MARK: - Durations

    /// mm:ss, or h:mm:ss once the duration passes an hour. Negative values clamp to zero.
    static func playbackTime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0.0, seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// "1:02:03" style duration for a video badge; nil when the duration is unknown.
    static func durationBadge(_ seconds: TimeInterval?) -> String? {
        guard let value = seconds, value > 0 else { return nil }
        return playbackTime(value)
    }

    /// "2 hours 5 minutes" for storage and recap summaries.
    static func longDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0.0, seconds.rounded()))
        if total < 60 { return total == 1 ? "1 second" : "\(total) seconds" }
        let minutes = total / 60
        if minutes < 60 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
        if remainingMinutes == 0 { return hourText }
        let minuteText = remainingMinutes == 1 ? "1 minute" : "\(remainingMinutes) minutes"
        return "\(hourText) \(minuteText)"
    }

    // MARK: - Relative dates

    /// "3 hours ago", "yesterday", "2 weeks ago", "12 Mar 2024" — the Android relative-time wording.
    static func relativeDate(_ date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 0 { return "just now" }
        if interval < 60 { return "just now" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        let days = hours / 24
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        if days < 30 {
            let weeks = days / 7
            return weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
        }
        if days < 365 {
            let months = days / 30
            return months == 1 ? "1 month ago" : "\(months) months ago"
        }
        let years = days / 365
        if years == 1 { return "1 year ago" }
        return "\(years) years ago"
    }

    /// "12 Mar 2024", used where an absolute date reads better than a relative one.
    static func absoluteDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return formatter.string(from: date)
    }

    /// "Today 14:32", "Yesterday 09:10", "12 Mar 2024".
    static func historyDate(_ date: Date, now: Date = Date()) -> String {
        let time = DateFormatter()
        time.locale = Locale.current
        time.setLocalizedDateFormatFromTemplate("HH:mm")
        let clock = time.string(from: date)
        if date.isToday { return "Today \(clock)" }
        if date.isYesterday { return "Yesterday \(clock)" }
        return absoluteDate(date)
    }

    /// A day heading for history sections: "Today", "Yesterday", or a long date.
    static func dayHeading(_ date: Date) -> String {
        if date.isToday { return "Today" }
        if date.isYesterday { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("EEEE, d MMMM")
        return formatter.string(from: date)
    }

    // MARK: - Bytes

    /// "1.4 GB" for storage summaries.
    static func fileSize(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024.0 && index < units.count - 1 {
            value /= 1024.0
            index += 1
        }
        if index == 0 {
            return String(format: "%.0f %@", value, units[index])
        }
        return String(format: "%.1f %@", value, units[index])
    }

    // MARK: - Speed

    /// "1.25x", with no trailing zero for whole speeds.
    static func playbackSpeed(_ speed: Double) -> String {
        if speed == speed.rounded() {
            return String(format: "%.0fx", speed)
        }
        return String(format: "%.2fx", speed)
    }

    // MARK: - Percent

    /// "42%" from a 0...1 fraction.
    static func percent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0.0), 1.0)
        return String(format: "%.0f%%", clamped * 100.0)
    }
}
