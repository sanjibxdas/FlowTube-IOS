import Foundation

/// One community title for a video, as DeArrow ranks it.
struct DeArrowTitle {
    let title: String
    let votes: Int
    let locked: Bool
    let original: Bool
}

/// One community thumbnail for a video, identified by the frame it was taken from.
struct DeArrowThumbnail {
    let timestamp: Double?
    let votes: Int
    let locked: Bool
    let original: Bool
}

/// The `/api/branding` answer. Submissions arrive best first, as the server ranks them.
struct DeArrowContent {
    let titles: [DeArrowTitle]
    let thumbnails: [DeArrowThumbnail]
    let randomTime: Double?
    let videoDuration: Double?
}

/// What a card should show instead of YouTube's own title and thumbnail. A nil field keeps the
/// original.
struct DeArrowResult {
    let title: String?
    let thumbnailUrl: String?
}

/// Community titles and thumbnails from DeArrow (https://dearrow.ajay.app/).
///
/// A video nobody has submitted for answers `404` with a usable body — the random frame time — so a
/// 404 is cached like any other answer. One request per video per hour: concurrent asks share a
/// request, and a small semaphore keeps a fast scroll from filling the network pool.
final class DeArrowService {

    static let shared = DeArrowService()

    /// The branding endpoint.
    static let brandingURL = "https://sponsor.ajay.app/api/branding"

    /// The endpoint that renders a chosen frame as a thumbnail.
    static let thumbnailURL = "https://dearrow-thumb.ajay.app/api/v1/getThumbnail"

    /// How many videos can be remembered at once.
    static let capacity = 1_000

    /// How many requests may be in flight at once.
    static let maximumParallel = 4

    /// How long an answer stays fresh.
    static let cacheTTL: TimeInterval = 60 * 60

    private struct Entry {
        let content: DeArrowContent?
        let fetchedAt: Date
    }

    private let client: InnerTubeClient
    private let lock = NSLock()
    private var answers: [String: Entry] = [:]
    private var order: [String] = []
    private var inFlight: [String: [(DeArrowContent?) -> Void]] = [:]
    private let permits = DispatchSemaphore(value: DeArrowService.maximumParallel)
    private let requestQueue = DispatchQueue(label: "org.flowtube.Flow.deArrow", attributes: .concurrent)

    init(client: InnerTubeClient = InnerTubeClient()) {
        self.client = client
    }

    // MARK: - Fetching

    /// What a request already answered, for a card's first frame. Never requests.
    func cached(videoId: String) -> DeArrowContent? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = answers[videoId],
              Date().timeIntervalSince(entry.fetchedAt) < DeArrowService.cacheTTL else {
            return nil
        }
        return entry.content
    }

    /// The branding answer for a video. A video with no submissions yields nil, not an error.
    func branding(videoId: String, completion: @escaping (DeArrowContent?) -> Void) {
        lock.lock()
        if let entry = answers[videoId], Date().timeIntervalSince(entry.fetchedAt) < DeArrowService.cacheTTL {
            lock.unlock()
            completion(entry.content)
            return
        }
        if var waiting = inFlight[videoId] {
            waiting.append(completion)
            inFlight[videoId] = waiting
            lock.unlock()
            return
        }
        inFlight[videoId] = [completion]
        lock.unlock()

        requestQueue.async { [weak self] in
            guard let self = self else { return }
            self.permits.wait()
            self.fetch(videoId: videoId) { content in
                self.permits.signal()
                self.lock.lock()
                let waiting = self.inFlight.removeValue(forKey: videoId) ?? []
                self.store(videoId: videoId, content: content)
                self.lock.unlock()
                for callback in waiting {
                    callback(content)
                }
            }
        }
    }

    private func fetch(videoId: String, completion: @escaping (DeArrowContent?) -> Void) {
        var components = URLComponents(string: DeArrowService.brandingURL)
        components?.queryItems = [URLQueryItem(name: "videoID", value: videoId)]
        guard let urlString = components?.url?.absoluteString else {
            completion(nil)
            return
        }
        client.getText(urlString: urlString, headers: ["Accept": "application/json"]) { result in
            switch result {
            case .failure(let error):
                // A 404 carries the answer for a video with no submissions, so it is read like a
                // success. Any other failure is a real one and caches nothing.
                if case .http(let status, let body) = error, status == 404, let body = body {
                    completion(DeArrowService.parse(body))
                } else {
                    completion(nil)
                }
            case .success(let text):
                completion(DeArrowService.parse(text))
            }
        }
    }

    /// Remembers an answer, evicting the least recently stored video when the cache is full.
    private func store(videoId: String, content: DeArrowContent?) {
        if answers[videoId] == nil {
            order.append(videoId)
        }
        answers[videoId] = Entry(content: content, fetchedAt: Date())
        while order.count > DeArrowService.capacity {
            let oldest = order.removeFirst()
            answers.removeValue(forKey: oldest)
        }
    }

    /// Forgets every cached answer.
    func clearCache() {
        lock.lock()
        answers.removeAll()
        order.removeAll()
        lock.unlock()
    }

    // MARK: - Resolving

    /// Turns a branding answer into what a card shows, the way the DeArrow extension does: the
    /// server's first usable submission wins, a winning "original" keeps YouTube's version, and a
    /// video with no thumbnail submission shows the frame at the server's random time for it, so
    /// every DeArrow user sees the same one.
    static func resolve(
        content: DeArrowContent,
        videoId: String,
        fallbackDurationSeconds: Int,
        useRandomFrame: Bool,
        isLiveOrUpcoming: Bool
    ) -> DeArrowResult? {
        var title: String?
        if let winner = content.titles.first(where: { $0.locked || $0.votes >= 0 }), !winner.original {
            let stripped = stripCaseMarkers(winner.title)
            if !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = stripped
            }
        }

        var frameTime: Double?
        let winner = content.thumbnails.first { $0.locked || $0.votes >= 0 }
        if let winner = winner {
            if !winner.original {
                frameTime = winner.timestamp
            }
        } else if useRandomFrame && !isLiveOrUpcoming {
            frameTime = randomFrameTime(content: content, fallbackDurationSeconds: fallbackDurationSeconds)
        }

        var thumbnail: String?
        if let frameTime = frameTime {
            thumbnail = frameURL(videoId: videoId, timeSeconds: frameTime)
        }

        if title == nil && thumbnail == nil { return nil }
        return DeArrowResult(title: title, thumbnailUrl: thumbnail)
    }

    private static func randomFrameTime(content: DeArrowContent, fallbackDurationSeconds: Int) -> Double? {
        guard let randomTime = content.randomTime else { return nil }
        let duration: Double
        if let reported = content.videoDuration, reported > 0 {
            duration = reported
        } else if fallbackDurationSeconds > 0 {
            duration = Double(fallbackDurationSeconds)
        } else {
            return nil
        }
        return randomTime * duration
    }

    /// The URL that renders a chosen frame as a thumbnail.
    static func frameURL(videoId: String, timeSeconds: Double) -> String {
        var components = URLComponents(string: DeArrowService.thumbnailURL)
        components?.queryItems = [
            URLQueryItem(name: "videoID", value: videoId),
            URLQueryItem(name: "time", value: String(timeSeconds)),
        ]
        return components?.url?.absoluteString ?? DeArrowService.thumbnailURL
    }

    /// DeArrow submitters prefix a word with `>` to keep its casing when titles are auto-formatted;
    /// the marker is formatting metadata, never part of the title.
    static func stripCaseMarkers(_ title: String) -> String {
        var result = ""
        result.reserveCapacity(title.count)
        var atWordStart = true
        let characters = Array(title)
        for (index, character) in characters.enumerated() {
            let nextIsWord = index + 1 < characters.count && !characters[index + 1].isWhitespace
            let isMarker = character == ">" && atWordStart && nextIsWord
            if !isMarker {
                result.append(character)
            }
            atWordStart = character.isWhitespace
        }
        return result
    }

    // MARK: - Parsing

    /// Reads a branding body. Anything unreadable yields nil, which keeps YouTube's own branding.
    static func parse(_ body: String) -> DeArrowContent? {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let object = root as? [String: Any] else {
            return nil
        }
        var titles: [DeArrowTitle] = []
        for entry in object["titles"] as? [[String: Any]] ?? [] {
            titles.append(DeArrowTitle(
                title: entry["title"] as? String ?? "",
                votes: (entry["votes"] as? NSNumber)?.intValue ?? 0,
                locked: entry["locked"] as? Bool ?? false,
                original: entry["original"] as? Bool ?? false
            ))
        }
        var thumbnails: [DeArrowThumbnail] = []
        for entry in object["thumbnails"] as? [[String: Any]] ?? [] {
            thumbnails.append(DeArrowThumbnail(
                timestamp: (entry["timestamp"] as? NSNumber)?.doubleValue,
                votes: (entry["votes"] as? NSNumber)?.intValue ?? 0,
                locked: entry["locked"] as? Bool ?? false,
                original: entry["original"] as? Bool ?? false
            ))
        }
        return DeArrowContent(
            titles: titles,
            thumbnails: thumbnails,
            randomTime: (object["randomTime"] as? NSNumber)?.doubleValue,
            videoDuration: (object["videoDuration"] as? NSNumber)?.doubleValue
        )
    }
}
