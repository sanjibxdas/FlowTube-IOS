import Foundation

/// Lyrics for a track, from whichever provider has them.
///
/// Three sources are tried in order, because none of them covers everything: SimpMusic answers with
/// line- and word-timed lyrics for a large catalogue, LRCLIB has clean line-level LRC for Western
/// releases, and YouTube Music's own lyrics tab is plain text but always matches the exact video.
/// The first provider that returns anything wins; a provider that fails is skipped silently, since
/// "no lyrics" and "that provider is down" look the same to the screen.
final class LyricsService {

    static let shared = LyricsService()

    /// SimpMusic's per-video endpoint. The video id is appended directly.
    static let simpMusicURL = "https://api-lyrics.simpmusic.org/v1/"

    /// LRCLIB's exact-match lookup.
    static let lrcLibGetURL = "https://lrclib.net/api/get"

    /// LRCLIB's search, used when the exact lookup misses.
    static let lrcLibSearchURL = "https://lrclib.net/api/search"

    /// How long an answer stays fresh.
    static let cacheTTL: TimeInterval = 6 * 60 * 60

    private struct Entry {
        let lyrics: Lyrics
        let fetchedAt: Date
    }

    private let client: InnerTubeClient
    private let api: YouTubeAPI
    private let lock = NSLock()
    private var cache: [String: Entry] = [:]

    init(client: InnerTubeClient = InnerTubeClient(), api: YouTubeAPI? = nil) {
        self.client = client
        self.api = api ?? YouTubeAPI(client: client)
    }

    /// Lyrics for a video. A video with none is a success carrying nil.
    func lyrics(
        videoId: String,
        title: String = "",
        artist: String = "",
        duration: Int = 0,
        completion: @escaping (Result<Lyrics?, FlowError>) -> Void
    ) {
        lock.lock()
        if let entry = cache[videoId], Date().timeIntervalSince(entry.fetchedAt) < LyricsService.cacheTTL {
            lock.unlock()
            completion(.success(entry.lyrics))
            return
        }
        lock.unlock()

        fetchSimpMusic(videoId: videoId, duration: duration) { [weak self] lyrics in
            guard let self = self else { return }
            if let lyrics = lyrics {
                self.store(videoId: videoId, lyrics: lyrics)
                completion(.success(lyrics))
                return
            }
            self.fetchLrcLib(title: title, artist: artist, duration: duration) { lyrics in
                if let lyrics = lyrics {
                    self.store(videoId: videoId, lyrics: lyrics)
                    completion(.success(lyrics))
                    return
                }
                self.fetchYouTube(videoId: videoId) { result in
                    switch result {
                    case .success(let lyrics):
                        if let lyrics = lyrics {
                            self.store(videoId: videoId, lyrics: lyrics)
                        }
                        completion(.success(lyrics))
                    case .failure:
                        // Three providers have now missed; that is "no lyrics", not an error the
                        // screen can act on.
                        completion(.success(nil))
                    }
                }
            }
        }
    }

    /// Lyrics already known, without a request.
    func cached(for videoId: String) -> Lyrics? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[videoId],
              Date().timeIntervalSince(entry.fetchedAt) < LyricsService.cacheTTL else {
            return nil
        }
        return entry.lyrics
    }

    /// Forgets every cached answer.
    func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private func store(videoId: String, lyrics: Lyrics) {
        lock.lock()
        cache[videoId] = Entry(lyrics: lyrics, fetchedAt: Date())
        lock.unlock()
    }

    // MARK: - Providers

    /// SimpMusic answers with a `data` array of candidates; the one whose duration is closest to the
    /// video's wins, because a search by video id can still return a different edit.
    private func fetchSimpMusic(videoId: String, duration: Int, completion: @escaping (Lyrics?) -> Void) {
        let urlString = LyricsService.simpMusicURL + videoId
        client.getText(urlString: urlString, headers: [
            "User-Agent": "SimpMusicLyrics/1.0",
            "Accept": "application/json",
        ]) { result in
            guard case .success(let text) = result else {
                completion(nil)
                return
            }
            completion(LyricsService.parseSimpMusic(text, duration: duration))
        }
    }

    private func fetchLrcLib(title: String, artist: String, duration: Int, completion: @escaping (Lyrics?) -> Void) {
        guard !title.isEmpty else {
            completion(nil)
            return
        }
        var components = URLComponents(string: LyricsService.lrcLibGetURL)
        var items = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty {
            items.insert(URLQueryItem(name: "artist_name", value: artist), at: 0)
        }
        if duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        components?.queryItems = items
        guard let urlString = components?.url?.absoluteString else {
            completion(nil)
            return
        }
        client.getText(urlString: urlString, headers: ["Accept": "application/json"]) { [weak self] result in
            guard let self = self else { return }
            if case .success(let text) = result, let lyrics = LyricsService.parseLrcLibObject(text) {
                completion(lyrics)
                return
            }
            self.searchLrcLib(title: title, artist: artist, duration: duration, completion: completion)
        }
    }

    private func searchLrcLib(title: String, artist: String, duration: Int, completion: @escaping (Lyrics?) -> Void) {
        let query = artist.isEmpty ? title : artist + " " + title
        var components = URLComponents(string: LyricsService.lrcLibSearchURL)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let urlString = components?.url?.absoluteString else {
            completion(nil)
            return
        }
        client.getText(urlString: urlString, headers: ["Accept": "application/json"]) { result in
            guard case .success(let text) = result else {
                completion(nil)
                return
            }
            completion(LyricsService.parseLrcLibSearch(text, duration: duration))
        }
    }

    private func fetchYouTube(videoId: String, completion: @escaping (Result<Lyrics?, FlowError>) -> Void) {
        api.lyrics(videoId: videoId, completion: completion)
    }

    // MARK: - Parsing

    /// Reads SimpMusic's answer: rich sync first, then synced LRC, then plain text.
    static func parseSimpMusic(_ body: String, duration: Int) -> Lyrics? {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        let candidates: [[String: Any]]
        if let array = root as? [[String: Any]] {
            candidates = array
        } else if let object = root as? [String: Any] {
            if let type = object["type"] as? String, type != "success" { return nil }
            candidates = object["data"] as? [[String: Any]] ?? []
        } else {
            return nil
        }
        guard !candidates.isEmpty else { return nil }

        let best = bestCandidate(candidates, duration: duration)

        if let rich = best["richSyncLyrics"] as? String, !rich.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let lines = parseRichSync(rich, duration: duration), !lines.isEmpty {
                return Lyrics(lines: lines, source: "SimpMusic", isSynchronised: true)
            }
        }
        if let synced = best["syncedLyrics"] as? String, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty {
                return Lyrics(lines: lines, source: "SimpMusic", isSynchronised: true)
            }
        }
        let plain = (best["plainLyrics"] as? String) ?? (best["plainLyric"] as? String)
        if let plain = plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Lyrics(lines: plainLines(plain), source: "SimpMusic", isSynchronised: false)
        }
        return nil
    }

    private static func bestCandidate(_ candidates: [[String: Any]], duration: Int) -> [String: Any] {
        guard duration > 0 else { return candidates[0] }
        var best = candidates[0]
        var bestDifference = Double.greatestFiniteMagnitude
        for candidate in candidates {
            let reported = (candidate["durationSeconds"] as? NSNumber)?.doubleValue
                ?? (candidate["duration"] as? NSNumber)?.doubleValue
                ?? 0
            let difference = abs(reported - Double(duration))
            if difference <= 10 && difference < bestDifference {
                bestDifference = difference
                best = candidate
            }
        }
        return best
    }

    /// Reads one LRCLIB object, which is the exact-match answer.
    static func parseLrcLibObject(_ body: String) -> Lyrics? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            return nil
        }
        return lyricsFromLrcLibEntry(object)
    }

    /// Reads LRCLIB's search answer, preferring the closest synced entry to the requested duration.
    static func parseLrcLibSearch(_ body: String, duration: Int) -> Lyrics? {
        guard let data = body.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [[String: Any]],
              !array.isEmpty else {
            return nil
        }
        if duration > 0 {
            let synced = array.filter { ($0["syncedLyrics"] as? String)?.isEmpty == false }
            let closest = synced.min { left, right in
                let leftGap = abs(((left["duration"] as? NSNumber)?.doubleValue ?? 0) - Double(duration))
                let rightGap = abs(((right["duration"] as? NSNumber)?.doubleValue ?? 0) - Double(duration))
                return leftGap < rightGap
            }
            if let closest = closest,
               abs(((closest["duration"] as? NSNumber)?.doubleValue ?? 0) - Double(duration)) < 5,
               let lyrics = lyricsFromLrcLibEntry(closest) {
                return lyrics
            }
        }
        if let firstSynced = array.first(where: { ($0["syncedLyrics"] as? String)?.isEmpty == false }),
           let lyrics = lyricsFromLrcLibEntry(firstSynced) {
            return lyrics
        }
        return lyricsFromLrcLibEntry(array[0])
    }

    private static func lyricsFromLrcLibEntry(_ entry: [String: Any]) -> Lyrics? {
        if let synced = entry["syncedLyrics"] as? String, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty {
                return Lyrics(lines: lines, source: "LRCLIB", isSynchronised: true)
            }
        }
        if let plain = entry["plainLyrics"] as? String, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Lyrics(lines: plainLines(plain), source: "LRCLIB", isSynchronised: false)
        }
        return nil
    }

    /// Splits plain text into one line per lyric line.
    static func plainLines(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(LyricLine(text: trimmed, startTime: nil, endTime: nil))
        }
        return lines
    }

    /// Parses standard LRC: `[MM:SS.mm] text`, with several timestamps allowed on one line.
    ///
    /// Each line's end time is the next line's start, which is what the lyrics screen uses to
    /// highlight the line that is being sung.
    static func parseLRC(_ text: String) -> [LyricLine] {
        var timed: [(time: TimeInterval, text: String)] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("[offset:") else { continue }
            let stamps = timestamps(in: line)
            guard !stamps.isEmpty else { continue }
            let content = stripTimestamps(from: line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            for stamp in stamps {
                timed.append((stamp, content))
            }
        }
        guard !timed.isEmpty else { return [] }
        let sorted = timed.sorted { $0.time < $1.time }
        var lines: [LyricLine] = []
        for (index, entry) in sorted.enumerated() {
            let end: TimeInterval? = index + 1 < sorted.count ? sorted[index + 1].time : nil
            lines.append(LyricLine(text: entry.text, startTime: entry.time, endTime: end))
        }
        return lines
    }

    /// Every `[MM:SS.mm]` stamp on a line, in order.
    private static func timestamps(in line: String) -> [TimeInterval] {
        var result: [TimeInterval] = []
        var index = line.startIndex
        while index < line.endIndex {
            guard line[index] == "[" else {
                index = line.index(after: index)
                continue
            }
            guard let close = line[index...].firstIndex(of: "]") else { break }
            let inner = String(line[line.index(after: index)..<close])
            if let time = parseStamp(inner) {
                result.append(time)
            }
            index = line.index(after: close)
        }
        return result
    }

    /// Reads `MM:SS.mm` or `MM:SS.mmm` into seconds.
    private static func parseStamp(_ text: String) -> TimeInterval? {
        let parts = text.components(separatedBy: ":")
        guard parts.count == 2 else { return nil }
        guard let minutes = Double(parts[0]) else { return nil }
        let secondsText = parts[1].replacingOccurrences(of: ".", with: ".")
        guard let seconds = Double(secondsText) else { return nil }
        return minutes * 60 + seconds
    }

    /// Removes every leading timestamp from a line, leaving the words.
    private static func stripTimestamps(from line: String) -> String {
        var result = line
        while result.hasPrefix("[") {
            guard let close = result.firstIndex(of: "]") else { break }
            let inner = String(result[result.index(after: result.startIndex)..<close])
            guard parseStamp(inner) != nil else { break }
            result = String(result[result.index(after: close)...])
        }
        return result
    }

    /// Parses SimpMusic's rich sync JSON: an array of `{ts, te, l:[{c,o}], x}` entries, where `ts`
    /// and `te` are line times and each word carries an offset into the line.
    static func parseRichSync(_ text: String, duration: Int) -> [LyricLine]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [[String: Any]] else {
            return nil
        }
        var lines: [LyricLine] = []
        for entry in array {
            let words = entry["l"] as? [[String: Any]] ?? []
            let fallback = entry["x"] as? String
            let text = lineText(words: words, fallback: fallback)
            guard !text.isEmpty else { continue }
            let start = normaliseTime((entry["ts"] as? NSNumber)?.doubleValue ?? 0, duration: duration)
            let rawEnd = normaliseTime((entry["te"] as? NSNumber)?.doubleValue ?? 0, duration: duration)
            let end = rawEnd > start ? rawEnd : start + 2
            lines.append(LyricLine(text: text, startTime: start, endTime: end))
        }
        guard !lines.isEmpty else { return nil }
        return lines.sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
    }

    private static func lineText(words: [[String: Any]], fallback: String?) -> String {
        let joined = words
            .compactMap { ($0["c"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let fallbackText = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if joined.isEmpty { return fallbackText }
        if fallbackText.isEmpty { return joined }
        // A fallback with no spaces is a single word the word list split; prefer the words.
        if !fallbackText.contains(" ") && joined.contains(" ") { return joined }
        return fallbackText
    }

    /// SimpMusic sometimes reports milliseconds and sometimes seconds; a value larger than the
    /// video's own length is the tell.
    private static func normaliseTime(_ value: Double, duration: Int) -> TimeInterval {
        let isProbablyMilliseconds = value > 1_000 || (duration > 0 && value > Double(duration) + 60)
        return isProbablyMilliseconds ? value / 1_000 : value
    }
}
