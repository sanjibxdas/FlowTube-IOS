import Foundation

/// One cue of a subtitle file: a span of time and the text shown during it.
struct SubtitleCue: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    /// The text with formatting tags removed, one entry per display line.
    let lines: [String]

    /// The cue's text as one string, for accessibility and for a single-line overlay.
    var text: String {
        return lines.joined(separator: "\n")
    }

    /// Whether `time` falls inside the cue, with a small tolerance at the edges so a cue that starts
    /// exactly on a seek still shows.
    func contains(_ time: TimeInterval, tolerance: TimeInterval = 0.05) -> Bool {
        return time >= start - tolerance && time < end + tolerance
    }
}

/// A parsed subtitle track.
struct SubtitleTrackFile {
    let cues: [SubtitleCue]
    /// The format the file was read as.
    let format: SubtitleParser.Format

    var isEmpty: Bool {
        return cues.isEmpty
    }

    /// The cue shown at `time`, or nil in a gap.
    func cue(at time: TimeInterval) -> SubtitleCue? {
        // Cues are sorted and rarely overlap, so a binary search is both correct and cheap at 60 Hz.
        var low = 0
        var high = cues.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let cue = cues[middle]
            if time < cue.start {
                high = middle - 1
            } else if time >= cue.end {
                low = middle + 1
            } else {
                return cue
            }
        }
        // A cue whose end is exactly `time` has just finished; the next one may start there.
        if low < cues.count, cues[low].contains(time) {
            return cues[low]
        }
        return nil
    }
}

/// Reads SRT and WebVTT subtitle files.
///
/// YouTube serves WebVTT for its caption tracks, and downloaded or side-loaded files are usually
/// SRT, so both are supported. The parser is deliberately tolerant: a malformed cue is skipped
/// rather than failing the file, because a track with one broken line is still worth showing.
enum SubtitleParser {

    /// The formats the parser understands.
    enum Format: String {
        case srt
        case vtt

        var displayName: String {
            switch self {
            case .srt: return "SubRip"
            case .vtt: return "WebVTT"
            }
        }
    }

    /// Parses `text`, detecting the format from its header and its cue syntax.
    static func parse(_ text: String) -> SubtitleTrackFile? {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalised.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("WEBVTT") {
            return SubtitleTrackFile(cues: parseVTT(normalised), format: .vtt)
        }
        let srtCues = parseSRT(normalised)
        if !srtCues.isEmpty {
            return SubtitleTrackFile(cues: srtCues, format: .srt)
        }
        // A file with no header that still parses as VTT cues is a VTT file with its header cut off.
        let vttCues = parseVTT(normalised)
        if !vttCues.isEmpty {
            return SubtitleTrackFile(cues: vttCues, format: .vtt)
        }
        return nil
    }

    // MARK: - SRT

    /// Parses SubRip: an index line, a `00:00:01,000 --> 00:00:04,000` timing line, then text,
    /// with a blank line between cues.
    static func parseSRT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = text.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard lines.count >= 2 else { continue }
            // The timing line is either first (no index) or second (index present).
            var timingIndex = 0
            if lines[0].contains("-->") {
                timingIndex = 0
            } else if lines.count >= 2 && lines[1].contains("-->") {
                timingIndex = 1
            } else {
                continue
            }
            guard let times = parseTimingLine(lines[timingIndex]) else { continue }
            let body = Array(lines[(timingIndex + 1)...])
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(
                start: times.start,
                end: max(times.end, times.start + 0.2),
                lines: cleanLines(body)
            ))
        }
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: - WebVTT

    /// Parses WebVTT: an optional `WEBVTT` header, then cues with `00:00:01.000 --> 00:00:04.000`
    /// timing lines and optional cue settings after the arrow.
    static func parseVTT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var blocks = text.components(separatedBy: "\n\n")
        // The header block may carry metadata lines, which are not cues.
        if let first = blocks.first, first.hasPrefix("WEBVTT") {
            blocks.removeFirst()
        }
        for block in blocks {
            var lines = block.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            // A cue identifier may precede the timing line; NOTE and STYLE blocks are skipped.
            if lines[0].hasPrefix("NOTE") || lines[0].hasPrefix("STYLE") || lines[0].hasPrefix("REGION") {
                continue
            }
            var timingIndex: Int?
            for (index, line) in lines.enumerated() where line.contains("-->") {
                timingIndex = index
                break
            }
            guard let index = timingIndex else { continue }
            guard let times = parseTimingLine(lines[index]) else { continue }
            lines.removeSubrange(0...index)
            guard !lines.isEmpty else { continue }
            cues.append(SubtitleCue(
                start: times.start,
                end: max(times.end, times.start + 0.2),
                lines: cleanLines(lines)
            ))
        }
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: - Timing

    /// Reads `HH:MM:SS,mmm --> HH:MM:SS,mmm`, accepting `.` as the millisecond separator and
    /// ignoring any cue settings after the second stamp.
    static func parseTimingLine(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        guard let start = parseTimestamp(parts[0]) else { return nil }
        // The end stamp may be followed by settings such as "align:start position:10%".
        let endText = parts[1].trimmingCharacters(in: .whitespaces)
        let endToken = endText.components(separatedBy: " ").first ?? endText
        guard let end = parseTimestamp(endToken) else { return nil }
        return (start, end)
    }

    /// Reads `HH:MM:SS,mmm`, `MM:SS.mmm` or `SS.mmm` into seconds.
    static func parseTimestamp(_ text: String) -> TimeInterval? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        let parts = cleaned.components(separatedBy: ":")
        switch parts.count {
        case 3:
            guard let hours = Double(parts[0]),
                  let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        case 2:
            guard let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { return nil }
            return minutes * 60 + seconds
        case 1:
            return Double(parts[0])
        default:
            return nil
        }
    }

    // MARK: - Text

    /// Strips the markup both formats allow and drops empty lines.
    ///
    /// WebVTT carries `<c.classname>`, `<v Speaker>` and `<00:00:01.000>` tags; SRT carries
    /// `<i>`, `<b>`, `<u>` and `{\an8}`-style overrides. All of them are invisible in the overlay,
    /// so removing them here keeps the renderer simple.
    static func cleanLines(_ lines: [String]) -> [String] {
        var result: [String] = []
        for raw in lines {
            var text = raw
            text = stripAngleTags(text)
            text = stripBraceTags(text)
            text = decodeEntities(text)
            text = text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                result.append(text)
            }
        }
        return result
    }

    private static func stripAngleTags(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            if character == "<" {
                depth += 1
            } else if character == ">" {
                if depth > 0 { depth -= 1 }
            } else if depth == 0 {
                result.append(character)
            }
        }
        return result
    }

    private static func stripBraceTags(_ text: String) -> String {
        var result = ""
        var inside = false
        for character in text {
            if character == "{" {
                inside = true
            } else if character == "}" {
                inside = false
            } else if !inside {
                result.append(character)
            }
        }
        return result
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let replacements: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " "),
            ("&lrm;", ""),
            ("&rlm;", ""),
        ]
        for (entity, value) in replacements {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }

    // MARK: - Rolling captions

    /// Collapses YouTube's rolling auto-captions into one cue per line.
    ///
    /// Automatic captions arrive as overlapping two-line cues where each new cue repeats the tail of
    /// the previous one. Shown naively they flicker and duplicate. This keeps each cue's last line
    /// only when it is new, which is the same rule the Android `RollingCaptionText` applies.
    static func collapseRollingCaptions(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        guard cues.count > 1 else { return cues }
        var result: [SubtitleCue] = []
        var previousTail = ""
        for cue in cues {
            var lines = cue.lines
            if let first = lines.first, first == previousTail {
                lines.removeFirst()
            }
            guard !lines.isEmpty else { continue }
            previousTail = cue.lines.last ?? previousTail
            result.append(SubtitleCue(start: cue.start, end: cue.end, lines: lines))
        }
        return result
    }
}
