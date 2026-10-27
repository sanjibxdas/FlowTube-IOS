import Foundation

/// One SponsorBlock category, with the wording and colour the app shows for it.
///
/// These are fixed convention values rather than theme roles: a segment keeps the colour people
/// already know from SponsorBlock everywhere else, so the seek bar reads the same in Flow as in a
/// browser. A user can override any of them in settings.
enum SponsorBlockCategory: String, CaseIterable {

    case sponsor
    case intro
    case outro
    case selfPromo = "selfpromo"
    case interaction
    case musicOffTopic = "music_offtopic"
    case filler
    case preview
    case exclusiveAccess = "exclusive_access"

    /// Every category Flow fetches, configures and submits, in the order settings list them.
    /// Chapters and highlights are left out: they are not ranges to act on.
    static let all: [String] = SponsorBlockCategory.allCases.map { $0.rawValue }

    /// The server only accepts `exclusive_access` as a whole-video label, never as a time range.
    static let submittable: [String] = all.filter { $0 != SponsorBlockCategory.exclusiveAccess.rawValue }

    /// `full` is what returns whole-video labels, which arrive as a zero-length `[0, 0]` segment.
    static let actionTypes: [String] = ["skip", "mute", "full"]

    /// The name a settings row and a skip toast show.
    var displayName: String {
        switch self {
        case .sponsor: return "Sponsor"
        case .intro: return "Intro / Intermission"
        case .outro: return "Outro / Endcard"
        case .selfPromo: return "Self-promotion"
        case .interaction: return "Interaction reminder"
        case .musicOffTopic: return "Non-music segment"
        case .filler: return "Filler / Tangent"
        case .preview: return "Preview / Recap"
        case .exclusiveAccess: return "Exclusive Access"
        }
    }

    /// The display name for a raw category id, or nil for one this build does not name.
    static func displayName(for category: String) -> String? {
        return SponsorBlockCategory(rawValue: category)?.displayName
    }

    /// The default colour for a category, as a 0xRRGGBB value. Unknown categories fall back to the
    /// sponsor colour, which is what the app has always done.
    static func defaultColor(for category: String) -> Int64 {
        switch category {
        case "sponsor": return 0x00D100
        case "selfpromo": return 0xFFFF00
        case "interaction": return 0xFF00FF
        case "intro", "outro": return 0x00FFFF
        case "music_offtopic": return 0xFF8000
        case "filler": return 0x7300FF
        case "preview": return 0x008FD6
        default: return 0x00D100
        }
    }

    /// The colours offered when a person picks their own colour for a category.
    static let segmentColorPresets: [Int64] = [
        0x00D400, 0xFFFF00, 0x0000FF, 0xFF0000, 0xFF7700, 0xFF69B4,
        0x7700FF, 0x00FFFF, 0xFFFFFF, 0x008080, 0x3F51B5, 0xFFC107,
        0xCDDC39, 0x673AB7, 0xFF5722, 0xE91E63, 0x006400, 0x8B4513,
        0x808080, 0xC0C0C0, 0xFFD700, 0x40E0D0, 0x4B0082,
    ]

    /// The opacity a segment is drawn at, so the progress track stays readable underneath it.
    static let segmentAlpha: CGFloat = 0.78

    /// Filler and previews are often wanted, so they show on the seek bar without being skipped.
    static func defaultAction(for category: String) -> SponsorBlockAction {
        switch category {
        case "filler", "preview": return .ignore
        default: return .skip
        }
    }
}

/// What the player does when playback enters a segment.
enum SponsorBlockAction: String, CaseIterable {
    case skip
    case mute
    case showToast
    case ignore

    var displayName: String {
        switch self {
        case .skip: return "Skip"
        case .mute: return "Mute"
        case .showToast: return "Notify only"
        case .ignore: return "Ignore"
        }
    }

    /// The action a stored preference names, defaulting to skip for an unknown value.
    static func fromString(_ name: String) -> SponsorBlockAction {
        return SponsorBlockAction(rawValue: name) ?? .skip
    }
}

/// One SponsorBlock segment.
struct SponsorBlockSegment {
    let category: String
    let startTime: Float
    let endTime: Float
    let uuid: String
    let actionType: String
    /// The segment's votes, when the response carried them.
    let votes: Int
    /// True for a whole-video label, which arrives as a zero-length segment.
    let isFullVideo: Bool

    init(
        category: String,
        startTime: Float,
        endTime: Float,
        uuid: String,
        actionType: String,
        votes: Int = 0,
        isFullVideo: Bool = false
    ) {
        self.category = category
        self.startTime = startTime
        self.endTime = endTime
        self.uuid = uuid
        self.actionType = actionType
        self.votes = votes
        self.isFullVideo = isFullVideo
    }

    var duration: Float {
        return max(endTime - startTime, 0)
    }

    var displayName: String {
        return SponsorBlockCategory.displayName(for: category) ?? category
    }

    var color: Int64 {
        return SponsorBlockCategory.defaultColor(for: category)
    }

    /// Whether a playback position falls inside the segment.
    func contains(_ time: Float) -> Bool {
        return time >= startTime && time < endTime
    }
}

/// Fetches, caches and submits SponsorBlock segments.
///
/// The lookup is one request per video, asking for every category and action type Flow handles. A
/// video nobody has submitted for answers `404` with an empty body, which is a valid "no segments"
/// rather than an error. Answers are cached for an hour so a video visited twice in a session does
/// not pay twice, and concurrent asks for the same video share one request.
final class SponsorBlockService {

    static let shared = SponsorBlockService()

    /// The endpoint every lookup and submission goes to.
    static let skipSegmentsURL = "https://sponsor.ajay.app/api/skipSegments"

    /// How long an answer stays fresh.
    static let cacheTTL: TimeInterval = 60 * 60

    /// The categories a lookup asks for, as the user configured them.
    var categories: [String] = SponsorBlockCategory.all

    /// The action types a lookup asks for.
    var actionTypes: [String] = SponsorBlockCategory.actionTypes

    /// The identifier submissions are attributed to. A stable per-install value, never a person.
    var userID: String {
        get {
            let key = "sponsorBlock.userID"
            if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty {
                return stored
            }
            let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            UserDefaults.standard.set(generated, forKey: key)
            return generated
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "sponsorBlock.userID")
        }
    }

    private struct CacheEntry {
        let segments: [SponsorBlockSegment]
        let fetchedAt: Date
    }

    private let client: InnerTubeClient
    private let queue = DispatchQueue(label: "org.flowtube.Flow.sponsorBlock", attributes: .concurrent)
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: [(Result<[SponsorBlockSegment], FlowError>) -> Void]] = [:]
    private let lock = NSLock()

    init(client: InnerTubeClient = InnerTubeClient()) {
        self.client = client
    }

    // MARK: - Fetching

    /// The segments for a video, from the cache when fresh.
    func segments(
        for videoId: String,
        completion: @escaping (Result<[SponsorBlockSegment], FlowError>) -> Void
    ) {
        lock.lock()
        if let entry = cache[videoId], Date().timeIntervalSince(entry.fetchedAt) < SponsorBlockService.cacheTTL {
            lock.unlock()
            completion(.success(entry.segments))
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

        fetch(videoId: videoId) { [weak self] result in
            guard let self = self else { return }
            self.lock.lock()
            let waiting = self.inFlight.removeValue(forKey: videoId) ?? []
            if case .success(let segments) = result {
                self.cache[videoId] = CacheEntry(segments: segments, fetchedAt: Date())
            }
            self.lock.unlock()
            for callback in waiting {
                callback(result)
            }
        }
    }

    /// The segments already known for a video, without a request. Used to paint a card's first frame.
    func cachedSegments(for videoId: String) -> [SponsorBlockSegment]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[videoId],
              Date().timeIntervalSince(entry.fetchedAt) < SponsorBlockService.cacheTTL else {
            return nil
        }
        return entry.segments
    }

    /// Stores segments that came with a download, so they survive offline.
    func store(_ segments: [SponsorBlockSegment], for videoId: String) {
        lock.lock()
        cache[videoId] = CacheEntry(segments: segments, fetchedAt: Date())
        lock.unlock()
    }

    /// Forgets every cached answer.
    func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private func fetch(videoId: String, completion: @escaping (Result<[SponsorBlockSegment], FlowError>) -> Void) {
        var components = URLComponents(string: SponsorBlockService.skipSegmentsURL)
        components?.queryItems = [
            URLQueryItem(name: "videoID", value: videoId),
            URLQueryItem(name: "categories", value: SponsorBlockService.jsonArray(categories)),
            URLQueryItem(name: "actionTypes", value: SponsorBlockService.jsonArray(actionTypes)),
        ]
        guard let urlString = components?.url?.absoluteString else {
            completion(.failure(.malformedResponse(detail: "Unbuildable SponsorBlock URL")))
            return
        }
        client.getText(urlString: urlString, headers: ["Accept": "application/json"]) { result in
            switch result {
            case .failure(let error):
                // A 404 is the service's way of saying nobody has submitted for this video.
                if case .http(let status, _) = error, status == 404 {
                    completion(.success([]))
                } else {
                    completion(.failure(error))
                }
            case .success(let text):
                completion(.success(SponsorBlockService.parseSegments(text)))
            }
        }
    }

    // MARK: - Submitting

    /// Submits a new segment. The server answers 200 once it has accepted the submission.
    func submitSegment(
        videoId: String,
        startTime: Float,
        endTime: Float,
        category: String,
        completion: @escaping (Result<Void, FlowError>) -> Void
    ) {
        guard SponsorBlockCategory.submittable.contains(category) else {
            completion(.failure(.underlying("SponsorBlock does not accept \(category) as a time range.")))
            return
        }
        var components = URLComponents(string: SponsorBlockService.skipSegmentsURL)
        components?.queryItems = [
            URLQueryItem(name: "videoID", value: videoId),
            URLQueryItem(name: "startTime", value: String(startTime)),
            URLQueryItem(name: "endTime", value: String(endTime)),
            URLQueryItem(name: "category", value: category),
            URLQueryItem(name: "userID", value: userID),
            URLQueryItem(name: "userAgent", value: "FlowYouTube/1.0"),
            URLQueryItem(name: "UUID", value: UUID().uuidString.replacingOccurrences(of: "-", with: "")),
            URLQueryItem(name: "duration", value: String(endTime - startTime)),
        ]
        guard let urlString = components?.url?.absoluteString else {
            completion(.failure(.malformedResponse(detail: "Unbuildable SponsorBlock URL")))
            return
        }
        // The submission is a POST with an empty body; the parameters ride in the query.
        client.postEmpty(urlString: urlString) { result in
            switch result {
            case .success:
                self.lock.lock()
                self.cache.removeValue(forKey: videoId)
                self.lock.unlock()
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Parsing

    /// Reads the segment array the service returns. A body that is not an array of objects yields
    /// no segments rather than failing: the service answers a 404 with a plain string.
    static func parseSegments(_ body: String) -> [SponsorBlockSegment] {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let array = root as? [[String: Any]] else {
            return []
        }
        var segments: [SponsorBlockSegment] = []
        for entry in array {
            guard let category = entry["category"] as? String else { continue }
            let points = entry["segment"] as? [Any] ?? []
            let start = (points.first as? NSNumber)?.floatValue ?? 0
            let end = points.count > 1 ? ((points[1] as? NSNumber)?.floatValue ?? 0) : 0
            let uuid = entry["UUID"] as? String ?? ""
            let actionType = entry["actionType"] as? String ?? "skip"
            let votes = (entry["votes"] as? NSNumber)?.intValue ?? 0
            let isFull = actionType == "full" || (start == 0 && end == 0)
            segments.append(SponsorBlockSegment(
                category: category,
                startTime: start,
                endTime: end,
                uuid: uuid,
                actionType: actionType,
                votes: votes,
                isFullVideo: isFull
            ))
        }
        return segments.sorted { $0.startTime < $1.startTime }
    }

    /// Serialises segments for the download store, in the shape `parseSegments` reads back.
    static func serialize(_ segments: [SponsorBlockSegment]) -> String {
        let objects: [[String: Any]] = segments.map { segment in
            [
                "category": segment.category,
                "segment": [segment.startTime, segment.endTime],
                "UUID": segment.uuid,
                "actionType": segment.actionType,
                "votes": segment.votes,
            ]
        }
        guard JSONSerialization.isValidJSONObject(objects),
              let data = try? JSONSerialization.data(withJSONObject: objects, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    /// A JSON array literal, which is how the service expects a category list in a query string.
    private static func jsonArray(_ values: [String]) -> String {
        let quoted = values.map { "\"" + $0 + "\"" }
        return "[" + quoted.joined(separator: ",") + "]"
    }
}
