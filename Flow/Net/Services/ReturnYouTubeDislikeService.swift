import Foundation

/// Return YouTube Dislike's counts for a video.
struct DislikeCounts {
    let videoId: String
    let likes: Int64?
    let dislikes: Int64?
    /// The 0–5 ratio the service computes, when it sent one.
    let rating: Double?
    let viewCount: Int64?
    /// True when the service has marked the video as deleted.
    let isDeleted: Bool

    /// The dislike count as a number, never negative.
    var dislikeCount: Int64 {
        return max(dislikes ?? 0, 0)
    }
}

/// Return YouTube Dislike's vote counts.
///
/// The endpoint is one GET per video, and its answers change slowly, so they are cached for an hour
/// and concurrent asks share a request. A failure is silent: the watch page simply shows no dislike
/// count, which is what it shows for a video the service has never seen.
final class ReturnYouTubeDislikeService {

    static let shared = ReturnYouTubeDislikeService()

    /// The votes endpoint.
    static let votesURL = "https://returnyoutubedislikeapi.com/votes"

    /// How long an answer stays fresh.
    static let cacheTTL: TimeInterval = 60 * 60

    private struct Entry {
        let counts: DislikeCounts
        let fetchedAt: Date
    }

    private let client: InnerTubeClient
    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var inFlight: [String: [(DislikeCounts?) -> Void]] = [:]

    init(client: InnerTubeClient = InnerTubeClient()) {
        self.client = client
    }

    /// The counts for a video, from the cache when fresh.
    func counts(for videoId: String, completion: @escaping (DislikeCounts?) -> Void) {
        lock.lock()
        if let entry = cache[videoId], Date().timeIntervalSince(entry.fetchedAt) < ReturnYouTubeDislikeService.cacheTTL {
            lock.unlock()
            completion(entry.counts)
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

        fetch(videoId: videoId) { [weak self] counts in
            guard let self = self else { return }
            self.lock.lock()
            let waiting = self.inFlight.removeValue(forKey: videoId) ?? []
            if let counts = counts {
                self.cache[videoId] = Entry(counts: counts, fetchedAt: Date())
            }
            self.lock.unlock()
            for callback in waiting {
                callback(counts)
            }
        }
    }

    /// The counts already known, without a request.
    func cached(for videoId: String) -> DislikeCounts? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[videoId],
              Date().timeIntervalSince(entry.fetchedAt) < ReturnYouTubeDislikeService.cacheTTL else {
            return nil
        }
        return entry.counts
    }

    /// Forgets every cached answer.
    func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private func fetch(videoId: String, completion: @escaping (DislikeCounts?) -> Void) {
        var components = URLComponents(string: ReturnYouTubeDislikeService.votesURL)
        components?.queryItems = [URLQueryItem(name: "videoId", value: videoId)]
        guard let urlString = components?.url?.absoluteString else {
            completion(nil)
            return
        }
        client.getText(urlString: urlString, headers: ["Accept": "application/json"]) { result in
            switch result {
            case .failure:
                completion(nil)
            case .success(let text):
                completion(ReturnYouTubeDislikeService.parse(text))
            }
        }
    }

    /// Reads a votes body. A body that is not the expected object yields nil.
    static func parse(_ body: String) -> DislikeCounts? {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let object = root as? [String: Any] else {
            return nil
        }
        guard let videoId = object["id"] as? String, !videoId.isEmpty else { return nil }
        return DislikeCounts(
            videoId: videoId,
            likes: (object["likes"] as? NSNumber)?.int64Value,
            dislikes: (object["dislikes"] as? NSNumber)?.int64Value,
            rating: (object["rating"] as? NSNumber)?.doubleValue,
            viewCount: (object["viewCount"] as? NSNumber)?.int64Value,
            isDeleted: object["deleted"] as? Bool ?? false
        )
    }
}
