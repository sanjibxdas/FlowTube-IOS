import Foundation
import AVFoundation

/// The headers YouTube's media URLs require.
///
/// A stream URL handed out by the player response is only valid for a client that looks like the
/// player that asked for it. Without these the CDN answers 403, so every request the media stack
/// makes — playlist, segment or whole file — carries them.
enum PlaybackHeaders {

    static let userAgent = "com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X;)"

    /// The headers for a media request.
    static func media(referer: String = "https://www.youtube.com/") -> [String: String] {
        return [
            "User-Agent": userAgent,
            "Referer": referer,
            "Origin": "https://www.youtube.com",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        ]
    }
}

/// Serves an `AVURLAsset`'s requests through `URLSession` so HTTP headers can be attached.
///
/// `AVURLAsset` has no public way to set request headers, and YouTube's CDN rejects a request that
/// arrives without a `Referer`. The asset is therefore created with a private scheme
/// (`flow-https`), which makes AVFoundation route every request — the HLS playlist, each segment,
/// each byte range of a progressive file — through this delegate. The delegate maps the scheme back
/// to `https`, adds the headers and copies the response into the loading request.
final class HeaderInjectingAssetLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {

    /// The scheme the assets are created with. It must not be a scheme AVFoundation handles itself.
    static let scheme = "flow-https"

    private let headers: [String: String]
    private let lock = NSLock()
    private var tasks: [Int: URLSessionDataTask] = [:]
    private var nextIdentifier = 1
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30.0
        configuration.timeoutIntervalForResource = 60.0 * 60.0
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(headers: [String: String]) {
        self.headers = headers
        super.init()
    }

    /// Rewrites an `https` URL into the scheme this loader intercepts.
    static func interceptableURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = HeaderInjectingAssetLoader.scheme
        return components.url ?? url
    }

    /// The original `https` URL behind an intercepted one.
    static func originalURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    /// Creates an asset whose requests carry these headers. The loader is retained by the asset.
    static func asset(for url: URL, headers: [String: String]) -> AVURLAsset {
        let loader = HeaderInjectingAssetLoader(headers: headers)
        let asset = AVURLAsset(url: interceptableURL(url))
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "org.flowtube.Flow.assetLoader"))
        objc_setAssociatedObject(asset, Unmanaged.passUnretained(loader).toOpaque(), loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let requestURL = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorBadURL,
                userInfo: nil
            ))
            return false
        }

        let original = HeaderInjectingAssetLoader.originalURL(requestURL)
        var request = URLRequest(url: original)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // AVFoundation asks for byte ranges on progressive media; forwarding the range is what lets
        // it seek without downloading the file from the start.
        if let dataRequest = loadingRequest.dataRequest {
            let start = dataRequest.requestedOffset
            let length = dataRequest.requestedLength
            if length > 0 {
                request.setValue("bytes=\(start)-\(start + Int64(length) - 1)", forHTTPHeaderField: "Range")
            } else if start > 0 {
                request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
            }
        }

        let task = session.dataTask(with: request)
        lock.lock()
        let identifier = nextIdentifier
        nextIdentifier += 1
        tasks[identifier] = task
        lock.unlock()
        objc_setAssociatedObject(loadingRequest, Unmanaged.passUnretained(task).toOpaque(), identifier as NSNumber, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(task, Unmanaged.passUnretained(loadingRequest).toOpaque(), loadingRequest, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        task.resume()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        lock.lock()
        let snapshot = tasks
        lock.unlock()
        for (identifier, task) in snapshot {
            if let associated = objc_getAssociatedObject(task, Unmanaged.passUnretained(loadingRequest).toOpaque()) {
                _ = associated
                task.cancel()
                lock.lock()
                tasks.removeValue(forKey: identifier)
                lock.unlock()
            }
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let loadingRequest = objc_getAssociatedObject(dataTask, Unmanaged.passUnretained(dataTask).toOpaque()) as? AVAssetResourceLoadingRequest else {
            completionHandler(.allow)
            return
        }
        if let http = response as? HTTPURLResponse,
           let information = loadingRequest.contentInformationRequest {
            information.contentType = http.mimeType
            information.isByteRangeAccessSupported = http.statusCode == 206
                || PlayerItemFactory.header("Accept-Ranges", in: http) == "bytes"
            if let lengthText = PlayerItemFactory.header("Content-Length", in: http), let length = Int64(lengthText) {
                information.contentLength = length
            } else {
                information.contentLength = response.expectedContentLength
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let loadingRequest = objc_getAssociatedObject(dataTask, Unmanaged.passUnretained(dataTask).toOpaque()) as? AVAssetResourceLoadingRequest else {
            return
        }
        loadingRequest.dataRequest?.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let loadingRequest = objc_getAssociatedObject(task, Unmanaged.passUnretained(task).toOpaque()) as? AVAssetResourceLoadingRequest else {
            return
        }
        lock.lock()
        for (identifier, candidate) in tasks where candidate === task {
            tasks.removeValue(forKey: identifier)
            break
        }
        lock.unlock()
        if let error = error {
            let nsError = error as NSError
            if nsError.code != NSURLErrorCancelled {
                loadingRequest.finishLoading(with: error)
                return
            }
        }
        loadingRequest.finishLoading()
    }
}

/// A quality the viewer can pick on the player.
struct PlaybackQuality: Equatable {

    /// The value stored in preferences: "auto", or a height such as "1080".
    let value: String
    /// The label the menu shows: "Auto", "1080p", "720p60".
    let label: String
    /// The height the choice resolves to, or 0 for Auto.
    let height: Int

    static let auto = PlaybackQuality(value: "auto", label: "Auto", height: 0)
}

/// Builds a playable `AVPlayerItem` from a watch page.
///
/// The order of preference is the same as the Android app's resolver:
///
/// 1. **HLS**, when the player response carries a manifest. One asset, adaptive switching and no
///    merging, so it is always the first choice.
/// 2. **Progressive**, when an itag with both video and audio is available. One asset, no merge,
///    fixed quality.
/// 3. **Composed**, when only adaptive tracks exist. The chosen video track and the chosen audio
///    track are inserted into an `AVMutableComposition`, which is what lets a video-only DASH-style
///    stream play with sound.
///
/// A finished download short-circuits all three: the local file is played directly, with no network
/// and no headers.
enum PlayerItemFactory {

    /// What the player asked for.
    struct Options {
        /// The stored quality preference, "auto" or a height.
        var quality: String = "auto"
        /// The preferred audio language tag, when the viewer picked one.
        var audioLanguage: String?
        /// A local file to play instead of a stream.
        var localFileURL: URL?
        /// How far ahead to buffer, in seconds. Zero leaves AVFoundation's own policy in place.
        var forwardBufferDuration: TimeInterval = 0.0
        /// Whether playback should start as soon as enough data is buffered.
        var automaticallyWaits: Bool = true
        /// The page's referer, for the media headers.
        var referer: String = "https://www.youtube.com/"

        init(
            quality: String = "auto",
            audioLanguage: String? = nil,
            localFileURL: URL? = nil,
            forwardBufferDuration: TimeInterval = 0.0,
            automaticallyWaits: Bool = true,
            referer: String = "https://www.youtube.com/"
        ) {
            self.quality = quality
            self.audioLanguage = audioLanguage
            self.localFileURL = localFileURL
            self.forwardBufferDuration = forwardBufferDuration
            self.automaticallyWaits = automaticallyWaits
            self.referer = referer
        }
    }

    /// The qualities a page offers, best first, always ending with Auto.
    static func qualities(for page: WatchPage) -> [PlaybackQuality] {
        var seen = Set<Int>()
        var result: [PlaybackQuality] = [.auto]
        let heights = page.videoFormats.map { $0.height } + page.progressiveFormats.map { $0.height }
        for height in heights where height > 0 && !seen.contains(height) {
            seen.insert(height)
            let format = page.videoFormats.first { $0.height == height }
                ?? page.progressiveFormats.first { $0.height == height }
            let label = format?.displayLabel ?? "\(height)p"
            result.append(PlaybackQuality(value: String(height), label: label, height: height))
        }
        return result.sorted { left, right in
            if left.height == 0 { return true }
            if right.height == 0 { return false }
            return left.height > right.height
        }
    }

    /// The height the stored quality resolves to, or 0 for Auto.
    static func requestedHeight(from quality: String) -> Int {
        if quality == "auto" || quality.isEmpty { return 0 }
        // A stored value may be a label ("1080p60") from an older settings screen.
        let digits = quality.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    /// Builds an item for a page.
    static func makeItem(
        for page: WatchPage,
        options: Options,
        completion: @escaping (Result<AVPlayerItem, FlowError>) -> Void
    ) {
        if let local = options.localFileURL, FileManager.default.fileExists(atPath: local.path) {
            let item = AVPlayerItem(url: local)
            applyBufferPolicy(to: item, options: options)
            completion(.success(item))
            return
        }

        guard page.isPlayable else {
            completion(.failure(.unavailable(reason: page.playabilityReason ?? "This video cannot be played.")))
            return
        }

        // 1. HLS.
        if let manifest = page.hlsManifestUrl, let url = URL(string: manifest) {
            let asset = HeaderInjectingAssetLoader.asset(for: url, headers: PlaybackHeaders.media(referer: options.referer))
            let item = AVPlayerItem(asset: asset)
            applyBufferPolicy(to: item, options: options)
            applyQualityCap(to: item, height: requestedHeight(from: options.quality), page: page)
            completion(.success(item))
            return
        }

        // 2. Progressive.
        if let progressive = bestProgressive(in: page, height: requestedHeight(from: options.quality)),
           let urlString = progressive.url, let url = URL(string: urlString) {
            let asset = HeaderInjectingAssetLoader.asset(for: url, headers: PlaybackHeaders.media(referer: options.referer))
            let item = AVPlayerItem(asset: asset)
            applyBufferPolicy(to: item, options: options)
            completion(.success(item))
            return
        }

        // 3. Composed video + audio.
        guard let video = bestVideo(in: page, height: requestedHeight(from: options.quality)),
              let videoURLString = video.url, let videoURL = URL(string: videoURLString) else {
            completion(.failure(.noPlayableStream))
            return
        }
        guard let audio = bestAudio(in: page, language: options.audioLanguage),
              let audioURLString = audio.url, let audioURL = URL(string: audioURLString) else {
            // A silent video is better than no video, so the video track alone still plays.
            let asset = HeaderInjectingAssetLoader.asset(for: videoURL, headers: PlaybackHeaders.media(referer: options.referer))
            let item = AVPlayerItem(asset: asset)
            applyBufferPolicy(to: item, options: options)
            completion(.success(item))
            return
        }

        compose(
            videoURL: videoURL,
            audioURL: audioURL,
            headers: PlaybackHeaders.media(referer: options.referer),
            options: options,
            completion: completion
        )
    }

    // MARK: - Composition

    /// Merges a video-only track and an audio-only track into one asset.
    private static func compose(
        videoURL: URL,
        audioURL: URL,
        headers: [String: String],
        options: Options,
        completion: @escaping (Result<AVPlayerItem, FlowError>) -> Void
    ) {
        let videoAsset = HeaderInjectingAssetLoader.asset(for: videoURL, headers: headers)
        let audioAsset = HeaderInjectingAssetLoader.asset(for: audioURL, headers: headers)
        let keys = ["tracks", "duration"]

        var remaining = 2
        var failure: FlowError?

        let finish: () -> Void = {
            guard remaining == 0 else { return }
            if let failure = failure {
                completion(.failure(failure))
                return
            }
            guard let videoTrack = videoAsset.tracks(withMediaType: .video).first else {
                completion(.failure(.noPlayableStream))
                return
            }
            let composition = AVMutableComposition()
            guard let compositionVideo = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                completion(.failure(.underlying("The video track could not be added to the composition.")))
                return
            }
            do {
                try compositionVideo.insertTimeRange(
                    CMTimeRange(start: .zero, duration: videoAsset.duration),
                    of: videoTrack,
                    at: .zero
                )
            } catch {
                completion(.failure(.underlying("The video track could not be inserted: \(error.localizedDescription)")))
                return
            }
            if let audioTrack = audioAsset.tracks(withMediaType: .audio).first,
               let compositionAudio = composition.addMutableTrack(
                   withMediaType: .audio,
                   preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                // A stream's audio can run a few milliseconds longer than its video; clamping the
                // range keeps the insert from failing on the overhang.
                let videoDuration = composition.duration
                let audioDuration = audioAsset.duration
                let usable = CMTimeMinimum(videoDuration, audioDuration)
                do {
                    try compositionAudio.insertTimeRange(
                        CMTimeRange(start: .zero, duration: usable),
                        of: audioTrack,
                        at: .zero
                    )
                } catch {
                    // Audio is optional; the video still plays.
                }
            }
            let item = AVPlayerItem(asset: composition)
            applyBufferPolicy(to: item, options: options)
            completion(.success(item))
        }

        videoAsset.loadValuesAsynchronously(forKeys: keys) {
            if let error = PlayerItemFactory.loadError(for: videoAsset, keys: keys) {
                failure = error
            }
            remaining -= 1
            finish()
        }
        audioAsset.loadValuesAsynchronously(forKeys: keys) {
            if let error = PlayerItemFactory.loadError(for: audioAsset, keys: keys) {
                failure = error
            }
            remaining -= 1
            finish()
        }
    }

    private static func loadError(for asset: AVAsset, keys: [String]) -> FlowError? {
        for key in keys {
            var error: NSError?
            let status = asset.statusOfValue(forKey: key, error: &error)
            if status == .failed {
                return .underlying(error?.localizedDescription ?? "The stream could not be loaded.")
            }
        }
        return nil
    }

    /// Reads a response header without `value(forHTTPHeaderField:)`, which is iOS 13 and later.
    fileprivate static func header(_ name: String, in response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame {
                return value as? String
            }
        }
        return nil
    }

    // MARK: - Selection

    /// The best progressive format within the requested height.
    static func bestProgressive(in page: WatchPage, height: Int) -> StreamFormat? {
        let candidates = page.progressiveFormats
        guard !candidates.isEmpty else { return nil }
        if height > 0 {
            let within = candidates.filter { $0.height <= height }
            if let best = within.max(by: { $0.height < $1.height }) {
                return best
            }
        }
        return candidates.first
    }

    /// The best video-only track within the requested height.
    static func bestVideo(in page: WatchPage, height: Int) -> StreamFormat? {
        let candidates = page.videoFormats
        guard !candidates.isEmpty else { return nil }
        if height > 0 {
            let within = candidates.filter { $0.height <= height }
            if let best = within.max(by: { $0.height < $1.height }) {
                return best
            }
        }
        return candidates.first
    }

    /// The best audio track, preferring the requested language and the original mix.
    static func bestAudio(in page: WatchPage, language: String?) -> StreamFormat? {
        let candidates = page.audioFormats
        guard !candidates.isEmpty else { return nil }
        if let language = language, !language.isEmpty {
            let matching = candidates.filter {
                ($0.audioLanguageTag ?? "").lowercased() == language.lowercased()
            }
            if let best = matching.first {
                return best
            }
        }
        return candidates.first
    }

    // MARK: - Item policy

    private static func applyBufferPolicy(to item: AVPlayerItem, options: Options) {
        item.preferredForwardBufferDuration = max(options.forwardBufferDuration, 0.0)
        // A live stream keeps downloading while paused so resuming does not jump back to the start
        // of the window.
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
    }

    /// Caps HLS's adaptive ladder at the chosen height.
    ///
    /// AVFoundation picks HLS renditions itself, but `preferredPeakBitRate` biases that choice. The
    /// cap is derived from the height the viewer asked for, so picking 480p on a metered connection
    /// actually keeps the stream near 480p instead of climbing to 1080p.
    private static func applyQualityCap(to item: AVPlayerItem, height: Int, page: WatchPage) {
        guard height > 0 else { return }
        let matching = page.videoFormats.filter { $0.height <= height }.max { $0.height < $1.height }
        guard let format = matching, format.bitrate > 0 else { return }
        item.preferredPeakBitRate = Double(format.bitrate)
    }
}
