import Foundation

/// Everything that can go wrong between a screen and YouTube, in the shape a screen can act on.
enum FlowError: Error {

    /// The device has no usable connection.
    case offline

    /// The request timed out.
    case timedOut

    /// The server answered, but not with success.
    case http(status: Int, body: String?)

    /// The response was not the JSON the endpoint promises.
    case malformedResponse(detail: String)

    /// The response parsed, but carried no playable content — age-gated, private, removed.
    case unavailable(reason: String)

    /// The video's streams could not be resolved.
    case noPlayableStream

    /// The request was cancelled because the screen went away.
    case cancelled

    /// Anything else, with the underlying description kept for the log.
    case underlying(String)

    /// Wording a person can read, used by snackbars and empty states.
    var displayMessage: String {
        switch self {
        case .offline:
            return "You are offline. Check your connection and try again."
        case .timedOut:
            return "The request took too long. Try again."
        case .http(let status, _):
            if status == 429 {
                return "YouTube is rate limiting requests. Try again in a moment."
            }
            if status == 403 {
                return "YouTube refused this request."
            }
            return "YouTube returned an error (\(status))."
        case .malformedResponse:
            return "YouTube sent a response Flow could not read."
        case .unavailable(let reason):
            return reason.isEmpty ? "This video is unavailable." : reason
        case .noPlayableStream:
            return "No playable stream was found for this video."
        case .cancelled:
            return "The request was cancelled."
        case .underlying(let detail):
            return detail.isEmpty ? "Something went wrong." : detail
        }
    }

    /// Whether retrying the same request could plausibly succeed.
    var isRetryable: Bool {
        switch self {
        case .offline, .timedOut:
            return true
        case .http(let status, _):
            return status >= 500 || status == 429
        case .malformedResponse, .cancelled:
            return false
        case .unavailable, .noPlayableStream:
            return false
        case .underlying:
            return true
        }
    }

    /// Maps a `URLSession` error onto the app's error vocabulary.
    static func from(urlError: Error) -> FlowError {
        let nsError = urlError as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                 NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
                return .offline
            case NSURLErrorTimedOut:
                return .timedOut
            case NSURLErrorCancelled:
                return .cancelled
            default:
                return .underlying(nsError.localizedDescription)
            }
        }
        return .underlying(nsError.localizedDescription)
    }
}

/// One entry in the client's request log, kept so the diagnostics screen can show what the app
/// actually asked YouTube for.
struct InnerTubeLogEntry {
    let date: Date
    let method: String
    let url: String
    let status: Int?
    let duration: TimeInterval
    let byteCount: Int
    let attempt: Int
    let errorDescription: String?
}

/// The HTTP layer for InnerTube: builds the context, signs logged-in requests, retries transient
/// failures with exponential backoff, and keeps the visitor identity and cookies across launches.
///
/// It does not parse responses. Every method hands back the raw `Data`, and the page parsers in the
/// sibling files turn that into models.
final class InnerTubeClient {

    // MARK: - State

    /// The locale every request is answered in.
    var locale: YouTubeLocale = .current

    /// The visitor identity. Changing it is reported so the caller can persist it.
    var visitorData: String? {
        didSet {
            guard visitorData != oldValue else { return }
            onVisitorDataChanged?(visitorData)
        }
    }

    /// Called whenever the visitor identity changes, including when YouTube rejects one and it is
    /// dropped back to nil.
    var onVisitorDataChanged: ((String?) -> Void)?

    /// The signed-in user's data sync id, when the app has a cookie.
    var dataSyncId: String?

    /// The raw `Cookie` header value, when the app has a signed-in session.
    var cookie: String? {
        didSet {
            cookieMap = InnerTubeClient.parseCookieString(cookie ?? "")
        }
    }

    /// Whether browse requests should carry the signed-in identity.
    var useLoginForBrowse: Bool = false

    /// How many attempts a transient failure gets, including the first.
    var maximumAttempts: Int = 3

    /// The delay before the second attempt; each further attempt doubles it.
    var initialRetryDelay: TimeInterval = 0.5

    /// The number of entries the request log keeps.
    var logCapacity: Int = 100

    // MARK: - Private state

    private var cookieMap: [String: String] = [:]
    private let session: URLSession
    private let logQueue = DispatchQueue(label: "org.flowtube.Flow.innerTubeLog")
    private var logEntries: [InnerTubeLogEntry] = []
    private var visitorBootstrapInFlight = false
    private var pendingBootstrapCompletions: [(String?) -> Void] = []
    private let bootstrapLock = NSLock()

    // MARK: - Construction

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30.0
        configuration.timeoutIntervalForResource = 45.0
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [
            "Accept": "application/json",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept-Encoding": "gzip, deflate",
        ]
        self.session = session ?? URLSession(configuration: configuration)
    }

    // MARK: - Public requests

    /// Posts to an endpoint on the music host, which is where browse, search and next live.
    func postMusic(
        path: String,
        client: YouTubeClient,
        body: [String: Any],
        query: [String: String] = [:],
        completion: @escaping (Result<Data, FlowError>) -> Void
    ) {
        var parameters = query
        parameters["prettyPrint"] = "false"
        let base = YouTubeClient.apiURLYouTubeMusic + path
        post(
            urlString: base,
            client: client,
            body: body,
            query: parameters,
            origin: YouTubeClient.originYouTubeMusic,
            referer: YouTubeClient.refererYouTubeMusic,
            setLogin: false,
            completion: completion
        )
    }

    /// Posts to an endpoint on the main site, which is where the watch page, comments and the
    /// web player live.
    func postMainSite(
        path: String,
        client: YouTubeClient,
        body: [String: Any],
        query: [String: String] = [:],
        anonymous: Bool = false,
        completion: @escaping (Result<Data, FlowError>) -> Void
    ) {
        var parameters = query
        parameters["prettyPrint"] = "false"
        let base = YouTubeClient.apiURLYouTube + path
        post(
            urlString: base,
            client: client,
            body: body,
            query: parameters,
            origin: YouTubeClient.originYouTube,
            referer: YouTubeClient.refererYouTube,
            setLogin: false,
            anonymous: anonymous,
            completion: completion
        )
    }

    /// Posts a player request. Player requests always carry the signed-in identity when there is
    /// one, and use the main site when the client is a web client.
    func postPlayer(
        client: YouTubeClient,
        body: [String: Any],
        useMainSite: Bool,
        completion: @escaping (Result<Data, FlowError>) -> Void
    ) {
        if useMainSite {
            post(
                urlString: YouTubeClient.apiURLYouTube + "player",
                client: client,
                body: body,
                query: ["prettyPrint": "false"],
                origin: YouTubeClient.originYouTube,
                referer: YouTubeClient.refererYouTube,
                setLogin: true,
                completion: completion
            )
        } else {
            post(
                urlString: YouTubeClient.apiURLYouTubeMusic + "player",
                client: client,
                body: body,
                query: ["prettyPrint": "false"],
                origin: YouTubeClient.originYouTubeMusic,
                referer: YouTubeClient.refererYouTubeMusic,
                setLogin: true,
                completion: completion
            )
        }
    }

    /// Fetches a plain URL, for the third-party services and for the caption tracks YouTube hands
    /// out as absolute URLs. Returns the body as text, because captions are XML and suggestions are
    /// JSONP rather than JSON.
    func getText(
        urlString: String,
        headers: [String: String] = [:],
        completion: @escaping (Result<String, FlowError>) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            completion(.failure(.malformedResponse(detail: "Unparseable URL: \(urlString)")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        perform(request: request, attempt: 1) { result in
            switch result {
            case .success(let payload):
                let text = String(data: payload.data, encoding: .utf8)
                    ?? String(data: payload.data, encoding: .isoLatin1)
                    ?? ""
                completion(.success(text))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Fetches a plain URL and decodes it as JSON.
    func getJSON(
        urlString: String,
        headers: [String: String] = [:],
        completion: @escaping (Result<Any, FlowError>) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            completion(.failure(.malformedResponse(detail: "Unparseable URL: \(urlString)")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        perform(request: request, attempt: 1) { result in
            switch result {
            case .success(let payload):
                completion(InnerTubeClient.decode(payload.data))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Posts to an arbitrary URL with no body, for the third-party services whose write endpoints
    /// take their parameters in the query string.
    func postEmpty(
        urlString: String,
        headers: [String: String] = [:],
        completion: @escaping (Result<Void, FlowError>) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            completion(.failure(.malformedResponse(detail: "Unparseable URL: \(urlString)")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        perform(request: request, attempt: 1) { result in
            switch result {
            case .success:
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Typeahead suggestions. Not an InnerTube endpoint, but it honours the same locale.
    func fetchSuggestions(
        query: String,
        completion: @escaping (Result<[String], FlowError>) -> Void
    ) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "suggestqueries-clients6.youtube.com"
        components.path = "/complete/search"
        components.queryItems = [
            URLQueryItem(name: "client", value: "youtube"),
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "hl", value: locale.hl),
            URLQueryItem(name: "gl", value: locale.gl),
            URLQueryItem(name: "q", value: query),
        ]
        guard let urlString = components.url?.absoluteString else {
            completion(.success([]))
            return
        }
        getText(urlString: urlString, headers: ["User-Agent": YouTubeClient.web.userAgent]) { result in
            switch result {
            case .success(let text):
                completion(.success(InnerTubeClient.parseSuggestionsPayload(text)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Visitor identity

    /// Ensures a visitor identity exists, bootstrapping one if necessary. Safe to call from several
    /// screens at once: only one bootstrap request is in flight, and every caller is answered.
    func ensureVisitorData(completion: @escaping (String?) -> Void) {
        if let existing = visitorData, !existing.isEmpty {
            completion(existing)
            return
        }
        bootstrapLock.lock()
        if visitorBootstrapInFlight {
            pendingBootstrapCompletions.append(completion)
            bootstrapLock.unlock()
            return
        }
        visitorBootstrapInFlight = true
        pendingBootstrapCompletions.append(completion)
        bootstrapLock.unlock()

        requestVisitorData { [weak self] value in
            guard let self = self else { return }
            if let value = value, !value.isEmpty {
                self.visitorData = value
            }
            self.bootstrapLock.lock()
            let waiting = self.pendingBootstrapCompletions
            self.pendingBootstrapCompletions = []
            self.visitorBootstrapInFlight = false
            self.bootstrapLock.unlock()
            let resolved = self.visitorData
            DispatchQueue.main.async {
                for callback in waiting {
                    callback(resolved)
                }
            }
        }
    }

    /// Asks YouTube for a visitor identity, falling back to the sw.js_data payload and then to the
    /// identity already sitting in the cookie jar.
    private func requestVisitorData(completion: @escaping (String?) -> Void) {
        let body: [String: Any] = [
            "context": YouTubeClient.web.context(locale: locale, visitorData: nil, dataSyncId: nil),
        ]
        post(
            urlString: YouTubeClient.apiURLYouTube + "visitor_id",
            client: YouTubeClient.web,
            body: body,
            query: ["prettyPrint": "false"],
            origin: YouTubeClient.originYouTube,
            referer: YouTubeClient.refererYouTube,
            setLogin: false,
            completion: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let data):
                    if case .success(let json) = InnerTubeClient.decode(data),
                       let root = json as? [String: Any],
                       let context = root["responseContext"] as? [String: Any],
                       let value = context["visitorData"] as? String,
                       !value.isEmpty {
                        completion(value)
                        return
                    }
                    self.requestVisitorDataFromScript(completion: completion)
                case .failure:
                    self.requestVisitorDataFromScript(completion: completion)
                }
            }
        )
    }

    /// The fallback the Android client uses: the music site's service-worker payload carries a
    /// visitor identity in a nested array.
    private func requestVisitorDataFromScript(completion: @escaping (String?) -> Void) {
        let scriptURL = "https://music.youtube.com/sw.js_data"
        getText(urlString: scriptURL, headers: [:]) { [weak self] result in
            guard let self = self else { return }
            if case .success(let text) = result,
               let value = InnerTubeClient.visitorDataFromScriptPayload(text) {
                completion(value)
                return
            }
            let fromCookie = self.cookieMap["VISITOR_INFO1_LIVE"]
            completion(fromCookie?.isEmpty == false ? fromCookie : nil)
        }
    }

    /// Reads a visitor identity out of the sw.js_data payload, which is JSON behind a five-character
    /// prefix.
    static func visitorDataFromScriptPayload(_ payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 5 else { return nil }
        let jsonStart = trimmed.index(trimmed.startIndex, offsetBy: 5)
        let jsonText = String(trimmed[jsonStart...])
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let outer = root as? [Any],
              let first = outer.first as? [Any],
              first.count > 2,
              let nested = first[2] as? [Any] else {
            return nil
        }
        for candidate in nested {
            guard let text = candidate as? String else { continue }
            if text.hasPrefix("Cgt") || text.hasPrefix("Cgs") {
                return text
            }
        }
        return nil
    }

    // MARK: - Request log

    /// The most recent requests, newest last.
    func recentLog() -> [InnerTubeLogEntry] {
        logQueue.sync { logEntries }
    }

    /// Empties the request log.
    func clearLog() {
        logQueue.sync { logEntries.removeAll() }
    }

    private func record(_ entry: InnerTubeLogEntry) {
        logQueue.async { [weak self] in
            guard let self = self else { return }
            self.logEntries.append(entry)
            if self.logEntries.count > self.logCapacity {
                self.logEntries.removeFirst(self.logEntries.count - self.logCapacity)
            }
        }
    }

    // MARK: - The request itself

    private struct Payload {
        let data: Data
        let status: Int
    }

    private func post(
        urlString: String,
        client: YouTubeClient,
        body: [String: Any],
        query: [String: String],
        origin: String,
        referer: String,
        setLogin: Bool,
        anonymous: Bool = false,
        completion: @escaping (Result<Data, FlowError>) -> Void
    ) {
        guard var components = URLComponents(string: urlString) else {
            completion(.failure(.malformedResponse(detail: "Unparseable endpoint: \(urlString)")))
            return
        }
        var items = components.queryItems ?? []
        for (key, value) in query.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        guard let url = components.url else {
            completion(.failure(.malformedResponse(detail: "Unparseable endpoint: \(urlString)")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        request.setValue(client.clientId, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if anonymous {
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue(origin + "/", forHTTPHeaderField: "Referer")
            request.setValue("SOCS=CAE=", forHTTPHeaderField: "Cookie")
        } else {
            request.setValue(origin, forHTTPHeaderField: "X-Origin")
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if let visitor = visitorData, !visitor.isEmpty {
            request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        if setLogin, client.loginSupported, let cookie = cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            if let sapisid = cookieMap["SAPISID"] {
                let timestamp = Int(Date().timeIntervalSince1970)
                let hashInput = "\(timestamp) \(sapisid) \(origin)"
                let digest = InnerTubeClient.sha1Hex(hashInput)
                request.setValue("SAPISIDHASH \(timestamp)_\(digest)", forHTTPHeaderField: "Authorization")
            }
        }

        guard JSONSerialization.isValidJSONObject(body),
              let payload = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            completion(.failure(.malformedResponse(detail: "Request body is not valid JSON")))
            return
        }
        request.httpBody = payload

        perform(request: request, attempt: 1, completion: completion)
    }

    /// Runs a request, retrying transient failures with exponential backoff. A 400 on a request that
    /// carried visitor data is retried once without it, and the rejected identity is dropped — that
    /// is what YouTube does when a visitor has been walled.
    private func perform(
        request: URLRequest,
        attempt: Int,
        completion: @escaping (Result<Payload, FlowError>) -> Void
    ) {
        let started = Date()
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let elapsed = Date().timeIntervalSince(started)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode

            if let error = error {
                let mapped = FlowError.from(urlError: error)
                self.record(InnerTubeLogEntry(
                    date: started,
                    method: request.httpMethod ?? "GET",
                    url: request.url?.absoluteString ?? "",
                    status: nil,
                    duration: elapsed,
                    byteCount: 0,
                    attempt: attempt,
                    errorDescription: mapped.displayMessage
                ))
                if mapped.isRetryable, attempt < self.maximumAttempts {
                    self.retry(request: request, attempt: attempt, completion: completion)
                } else {
                    completion(.failure(mapped))
                }
                return
            }

            guard let status = status else {
                self.record(InnerTubeLogEntry(
                    date: started,
                    method: request.httpMethod ?? "GET",
                    url: request.url?.absoluteString ?? "",
                    status: nil,
                    duration: elapsed,
                    byteCount: data?.count ?? 0,
                    attempt: attempt,
                    errorDescription: "No HTTP response"
                ))
                completion(.failure(.malformedResponse(detail: "The response carried no status")))
                return
            }

            let bodyText = data.flatMap { String(data: $0, encoding: .utf8) }
            self.record(InnerTubeLogEntry(
                date: started,
                method: request.httpMethod ?? "GET",
                url: request.url?.absoluteString ?? "",
                status: status,
                duration: elapsed,
                byteCount: data?.count ?? 0,
                attempt: attempt,
                errorDescription: status >= 400 ? bodyText.map { String($0.prefix(200)) } : nil
            ))

            if status >= 200, status < 300 {
                completion(.success(Payload(data: data ?? Data(), status: status)))
                return
            }

            if status == 400, request.value(forHTTPHeaderField: "X-Goog-Visitor-Id") != nil {
                self.dropVisitorDataAndRetry(request: request, completion: completion)
                return
            }

            let error = FlowError.http(status: status, body: bodyText)
            if error.isRetryable, attempt < self.maximumAttempts {
                self.retry(request: request, attempt: attempt, completion: completion)
            } else {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    private func retry(
        request: URLRequest,
        attempt: Int,
        completion: @escaping (Result<Payload, FlowError>) -> Void
    ) {
        let delay = initialRetryDelay * pow(2.0, Double(attempt - 1))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.perform(request: request, attempt: attempt + 1, completion: completion)
        }
    }

    /// Retries without the visitor identity and forgets it, so the next request bootstraps a new one.
    private func dropVisitorDataAndRetry(
        request: URLRequest,
        completion: @escaping (Result<Payload, FlowError>) -> Void
    ) {
        var retried = request
        retried.setValue(nil, forHTTPHeaderField: "X-Goog-Visitor-Id")
        let rejected = visitorData
        visitorData = nil
        perform(request: retried, attempt: 2) { [weak self] result in
            if case .success = result {
                _ = rejected
            }
            completion(result)
        }
    }

    // MARK: - Helpers

    /// Decodes a JSON payload into Foundation objects.
    static func decode(_ data: Data) -> Result<Any, FlowError> {
        guard !data.isEmpty else {
            return .failure(.malformedResponse(detail: "Empty response body"))
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return .success(object)
        } catch {
            return .failure(.malformedResponse(detail: "JSON parse failed: \(error.localizedDescription)"))
        }
    }

    /// Parses the JSONP array the suggest endpoint returns.
    static func parseSuggestionsPayload(_ payload: String) -> [String] {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "["),
              let end = trimmed.lastIndex(of: "]"),
              start < end else {
            return []
        }
        let jsonText = String(trimmed[start...end])
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let outer = root as? [Any],
              outer.count > 1,
              let suggestions = outer[1] as? [Any] else {
            return []
        }
        return suggestions.compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    /// Splits a `Cookie` header into its name/value pairs.
    static func parseCookieString(_ cookie: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in cookie.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex..<separator])
            let value = String(trimmed[trimmed.index(after: separator)...])
            if !name.isEmpty {
                result[name] = value
            }
        }
        return result
    }

    /// SHA-1, hex encoded. `CryptoKit` is iOS 13, so the digest is computed here — the SAPISIDHASH
    /// scheme YouTube's logged-in requests use is defined in terms of SHA-1 and nothing else.
    static func sha1Hex(_ input: String) -> String {
        let digest = sha1(Array(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The SHA-1 digest of a byte array.
    static func sha1(_ message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 {
            data.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var words = [UInt32](repeating: 0, count: 80)
        var chunkStart = 0
        while chunkStart < data.count {
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                words[index] = (UInt32(data[offset]) << 24)
                    | (UInt32(data[offset + 1]) << 16)
                    | (UInt32(data[offset + 2]) << 8)
                    | UInt32(data[offset + 3])
            }
            for index in 16..<80 {
                let value = words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16]
                words[index] = (value << 1) | (value >> 31)
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4

            for index in 0..<80 {
                var f: UInt32
                var k: UInt32
                switch index {
                case 0..<20:
                    f = (b & c) | ((~b) & d)
                    k = 0x5A827999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ words[index]
                e = d
                d = c
                c = (b << 30) | (b >> 2)
                b = a
                a = temp
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
            chunkStart += 64
        }

        var digest: [UInt8] = []
        for word in [h0, h1, h2, h3, h4] {
            digest.append(UInt8((word >> 24) & 0xFF))
            digest.append(UInt8((word >> 16) & 0xFF))
            digest.append(UInt8((word >> 8) & 0xFF))
            digest.append(UInt8(word & 0xFF))
        }
        return digest
    }

    /// Base64 of a UTF-8 string, for the transcript endpoint's `params`.
    static func base64(_ text: String) -> String {
        let data = text.data(using: .utf8) ?? Data()
        return data.base64EncodedString()
    }

    /// A client-generated playback nonce, which YouTube's player expects on every request.
    static func playbackNonce() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        var result = ""
        for _ in 0..<16 {
            let index = Int(arc4random_uniform(UInt32(alphabet.count)))
            result.append(alphabet[index])
        }
        return result
    }
}
