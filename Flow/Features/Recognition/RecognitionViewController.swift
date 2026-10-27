import UIKit
import AVFoundation
import Accelerate

// MARK: - Errors

/// Everything that can go wrong while listening for a song, with wording the screen can show.
enum RecognitionError: Error {
    case permissionDenied
    case noInput
    case engineFailed(String)
    case tooQuiet
    case noProvider
    case providerUnavailable(String)
    case noMatch
    case network(String)
    case malformedResponse

    var message: String {
        switch self {
        case .permissionDenied:
            return "Microphone access is needed to recognise music. Turn it on in Settings."
        case .noInput:
            return "No microphone is available on this device."
        case .engineFailed(let detail):
            return detail.isEmpty ? "The microphone could not be started." : detail
        case .tooQuiet:
            return "That was too quiet to recognise. Move closer to the speaker and try again."
        case .noProvider:
            return "No recognition provider is configured."
        case .providerUnavailable(let name):
            return name + " is not configured yet."
        case .noMatch:
            return "No match found. Try again with clearer audio."
        case .network(let detail):
            return detail.isEmpty ? "Recognition needs an internet connection." : detail
        case .malformedResponse:
            return "The recognition service sent a response Flow could not read."
        }
    }
}

// MARK: - Sample

/// A short mono recording, normalised to floats in -1...1.
struct RecognitionSample {
    let samples: [Float]
    let sampleRate: Double

    var duration: TimeInterval {
        guard sampleRate > 0.0 else { return 0.0 }
        return TimeInterval(samples.count) / sampleRate
    }

    /// Peak amplitude, used to tell "silence" from "a quiet song".
    var peak: Float {
        var maximum: Float = 0.0
        for value in samples {
            maximum = max(maximum, abs(value))
        }
        return maximum
    }
}

// MARK: - Fingerprint

/// A landmark fingerprint: the pairs of spectral peaks that make a recording recognisable even when
/// it is noisy or played through a speaker. Two recordings of the same song share most of their
/// hashes and, crucially, the same time offsets between them.
struct RecognitionFingerprint {

    struct Peak {
        let hash: UInt32
        let time: Int
    }

    let peaks: [Peak]
    let sampleRate: Double
    let duration: TimeInterval

    var isEmpty: Bool {
        return peaks.isEmpty
    }

    /// The compact form the catalog stores: one `[hash, time]` pair per peak.
    func encodedPeaks() -> [[Int]] {
        return peaks.map { [Int($0.hash), $0.time] }
    }

    static func decode(peaks: [[Int]], sampleRate: Double, duration: TimeInterval) -> RecognitionFingerprint {
        let decoded = peaks.compactMap { pair -> Peak? in
            guard pair.count == 2, pair[0] >= 0 else { return nil }
            return Peak(hash: UInt32(truncatingIfNeeded: pair[0]), time: pair[1])
        }
        return RecognitionFingerprint(peaks: decoded, sampleRate: sampleRate, duration: duration)
    }
}

/// Turns samples into a fingerprint with a real FFT (Accelerate's vDSP), the same shape of
/// algorithm the Android app's `VibraSignature` produces: windowed spectra, the strongest local
/// peaks per frame, and hashes of peak pairs.
enum FingerprintBuilder {

    private static let fftSize = 1024
    private static let hopSize = 512
    private static let minimumFrequency = 300.0
    private static let maximumFrequency = 5000.0
    private static let peaksPerFrame = 5
    private static let fanOut = 5
    private static let maximumPairGap = 63

    /// Builds the fingerprint for `samples`. Returns an empty fingerprint when the audio is too
    /// short to analyse.
    static func build(samples: [Float], sampleRate: Double) -> RecognitionFingerprint {
        guard sampleRate > 0.0, samples.count >= fftSize else {
            return RecognitionFingerprint(peaks: [], sampleRate: sampleRate, duration: 0.0)
        }

        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return RecognitionFingerprint(peaks: [], sampleRate: sampleRate, duration: 0.0)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0.0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let binWidth = sampleRate / Double(fftSize)
        let lowestBin = max(1, Int(minimumFrequency / binWidth))
        let highestBin = min(fftSize / 2 - 1, Int(maximumFrequency / binWidth))
        guard highestBin > lowestBin else {
            return RecognitionFingerprint(peaks: [], sampleRate: sampleRate, duration: 0.0)
        }

        var real = [Float](repeating: 0.0, count: fftSize / 2)
        var imaginary = [Float](repeating: 0.0, count: fftSize / 2)
        var magnitudes = [Float](repeating: 0.0, count: fftSize / 2)
        var windowed = [Float](repeating: 0.0, count: fftSize)

        var framePeaks: [(frame: Int, bin: Int, magnitude: Float)] = []
        var frame = 0
        var offset = 0

        while offset + fftSize <= samples.count {
            samples.withUnsafeBufferPointer { source in
                vDSP_vmul(source.baseAddress! + offset, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
            }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                    windowed.withUnsafeBufferPointer { source in
                        source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { pointer in
                            vDSP_ctoz(pointer, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                }
            }

            // A frame's peaks are its local maxima above the frame's mean magnitude, strongest first.
            var sum: Float = 0.0
            vDSP_sve(magnitudes, 1, &sum, vDSP_Length(fftSize / 2))
            let mean = sum / Float(fftSize / 2)
            let threshold = max(mean * 2.2, 0.0001)

            var candidates: [(bin: Int, magnitude: Float)] = []
            for bin in (lowestBin + 1)..<highestBin {
                let value = magnitudes[bin]
                guard value > threshold else { continue }
                if value >= magnitudes[bin - 1], value >= magnitudes[bin + 1] {
                    candidates.append((bin, value))
                }
            }
            candidates.sort { $0.magnitude > $1.magnitude }
            for candidate in candidates.prefix(peaksPerFrame) {
                framePeaks.append((frame, candidate.bin, candidate.magnitude))
            }

            frame += 1
            offset += hopSize
        }

        // Pair each peak with the next few peaks in time; the pair's hash and time offset are what
        // makes matching robust to a recording starting anywhere in the song.
        var peaks: [RecognitionFingerprint.Peak] = []
        for index in 0..<framePeaks.count {
            let anchor = framePeaks[index]
            var paired = 0
            var next = index + 1
            while next < framePeaks.count, paired < fanOut {
                let target = framePeaks[next]
                let gap = target.frame - anchor.frame
                if gap > maximumPairGap { break }
                if gap > 0 {
                    let hash = (UInt32(anchor.bin) & 0x3FF)
                        | ((UInt32(target.bin) & 0x3FF) << 10)
                        | ((UInt32(gap) & 0xFFF) << 20)
                    peaks.append(RecognitionFingerprint.Peak(hash: hash, time: anchor.frame))
                    paired += 1
                }
                next += 1
            }
        }

        let duration = TimeInterval(samples.count) / sampleRate
        return RecognitionFingerprint(peaks: peaks, sampleRate: sampleRate, duration: duration)
    }

    /// How many hashes two fingerprints share at the same relative time. A song that is merely
    /// similar scores low; the same recording scores high even with noise on top of it.
    static func score(_ query: RecognitionFingerprint, against candidate: [RecognitionFingerprint.Peak]) -> Int {
        guard !query.peaks.isEmpty, !candidate.isEmpty else { return 0 }
        var index: [UInt32: [Int]] = [:]
        index.reserveCapacity(candidate.count)
        for peak in candidate {
            index[peak.hash, default: []].append(peak.time)
        }
        var offsets: [Int: Int] = [:]
        for peak in query.peaks {
            guard let times = index[peak.hash] else { continue }
            for time in times {
                let offset = time - peak.time
                offsets[offset, default: 0] += 1
            }
        }
        return offsets.values.max() ?? 0
    }
}

// MARK: - Match

/// A recognised song.
struct RecognitionMatch {
    let title: String
    let artist: String
    let album: String
    let artworkUrl: String
    let youtubeVideoId: String
    let providerName: String
    let confidence: Double
}

// MARK: - Provider

/// Something that can turn a fingerprint into a song. The screen never talks to a service directly:
/// it asks the registry for the configured provider, so a build can plug in a local catalog, a
/// self-hosted service or nothing at all.
protocol RecognitionProvider: AnyObject {
    /// Stable id, stored in the preferences.
    var identifier: String { get }
    /// The name shown in the configuration sheet.
    var displayName: String { get }
    /// Whether the provider has everything it needs to answer.
    var isConfigured: Bool { get }
    /// One line explaining what is missing, shown when `isConfigured` is false.
    var configurationHint: String { get }

    func recognize(
        fingerprint: RecognitionFingerprint,
        sample: RecognitionSample,
        completion: @escaping (Result<RecognitionMatch, RecognitionError>) -> Void
    )
}

// MARK: - Local catalog provider

/// One song in the on-device fingerprint catalog.
struct RecognitionCatalogEntry {
    let id: String
    let title: String
    let artist: String
    let album: String
    let artworkUrl: String
    let youtubeVideoId: String
    let peaks: [RecognitionFingerprint.Peak]
}

/// The on-device catalog of fingerprints, stored as JSON in Application Support. It is filled by
/// importing a catalog file — Flow does not ship a song database, and it does not upload audio.
final class RecognitionCatalogStore {

    static let shared = RecognitionCatalogStore()

    private let lock = NSLock()
    private var cached: [RecognitionCatalogEntry]?

    private var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("Flow", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
        return directory.appendingPathComponent("recognition-catalog.json")
    }

    var count: Int {
        return entries().count
    }

    func entries() -> [RecognitionCatalogEntry] {
        lock.lock()
        if let cached = cached {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let loaded = loadFromDisk()
        lock.lock()
        cached = loaded
        lock.unlock()
        return loaded
    }

    private func loadFromDisk() -> [RecognitionCatalogEntry] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return RecognitionCatalogStore.decode(data: data)
    }

    /// Reads a catalog file: `{ "songs": [{ id, title, artist, album, artwork, videoId, peaks: [[hash, time]] }] }`.
    static func decode(data: Data) -> [RecognitionCatalogEntry] {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return []
        }
        let songs = (root["songs"] as? [[String: Any]]) ?? (root["tracks"] as? [[String: Any]]) ?? []
        return songs.compactMap { song in
            let title = (song["title"] as? String) ?? ""
            guard !title.isEmpty else { return nil }
            let rawPeaks = (song["peaks"] as? [[Any]]) ?? []
            let peaks = rawPeaks.compactMap { pair -> RecognitionFingerprint.Peak? in
                guard pair.count == 2,
                      let hash = (pair[0] as? NSNumber)?.uint32Value,
                      let time = (pair[1] as? NSNumber)?.intValue else { return nil }
                return RecognitionFingerprint.Peak(hash: hash, time: time)
            }
            guard !peaks.isEmpty else { return nil }
            return RecognitionCatalogEntry(
                id: (song["id"] as? String) ?? title,
                title: title,
                artist: (song["artist"] as? String) ?? "",
                album: (song["album"] as? String) ?? "",
                artworkUrl: (song["artwork"] as? String) ?? (song["artworkUrl"] as? String) ?? "",
                youtubeVideoId: (song["videoId"] as? String) ?? "",
                peaks: peaks
            )
        }
    }

    /// Imports a catalog file, replacing the stored one. Returns how many songs it held.
    @discardableResult
    func importCatalog(data: Data) -> Int {
        let decoded = RecognitionCatalogStore.decode(data: data)
        guard !decoded.isEmpty else { return 0 }
        let payload: [String: Any] = [
            "version": 1,
            "songs": decoded.map { entry in
                [
                    "id": entry.id,
                    "title": entry.title,
                    "artist": entry.artist,
                    "album": entry.album,
                    "artwork": entry.artworkUrl,
                    "videoId": entry.youtubeVideoId,
                    "peaks": entry.peaks.map { [Int($0.hash), $0.time] },
                ] as [String: Any]
            },
        ]
        guard let url = fileURL,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return 0
        }
        try? data.write(to: url, options: .atomic)
        lock.lock()
        cached = decoded
        lock.unlock()
        return decoded.count
    }

    func clear() {
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        lock.lock()
        cached = []
        lock.unlock()
    }
}

/// Matches a fingerprint against the on-device catalog. No audio and no fingerprint leaves the
/// device; the catalog has to be imported once.
final class LocalCatalogRecognitionProvider: RecognitionProvider {

    let identifier = "local"
    let displayName = "On-device catalog"

    var isConfigured: Bool {
        return RecognitionCatalogStore.shared.count > 0
    }

    var configurationHint: String {
        return "Import a fingerprint catalog file to recognise songs without a network."
    }

    func recognize(
        fingerprint: RecognitionFingerprint,
        sample: RecognitionSample,
        completion: @escaping (Result<RecognitionMatch, RecognitionError>) -> Void
    ) {
        let entries = RecognitionCatalogStore.shared.entries()
        guard !entries.isEmpty else {
            completion(.failure(.providerUnavailable(displayName)))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var best: (entry: RecognitionCatalogEntry, score: Int)?
            for entry in entries {
                let score = FingerprintBuilder.score(fingerprint, against: entry.peaks)
                if score > (best?.score ?? 0) {
                    best = (entry, score)
                }
            }
            DispatchQueue.main.async {
                guard let winner = best, winner.score >= 6 else {
                    completion(.failure(.noMatch))
                    return
                }
                let confidence = min(Double(winner.score) / 40.0, 1.0)
                completion(.success(RecognitionMatch(
                    title: winner.entry.title,
                    artist: winner.entry.artist,
                    album: winner.entry.album,
                    artworkUrl: winner.entry.artworkUrl,
                    youtubeVideoId: winner.entry.youtubeVideoId,
                    providerName: self.displayName,
                    confidence: confidence
                )))
            }
        }
    }
}

// MARK: - Remote provider

/// Posts the fingerprint to a service the viewer configured — a self-hosted instance, a home
/// server, anything that speaks the small JSON contract. The endpoint lives in the preferences, so
/// the screen has no service baked into it.
final class RemoteRecognitionProvider: RecognitionProvider {

    let identifier = "remote"
    let displayName = "Fingerprint service"

    private static let endpointKey = "recognition.endpoint"

    var endpoint: String {
        get { return UserDefaults.standard.string(forKey: RemoteRecognitionProvider.endpointKey) ?? "" }
        set {
            let trimmed = newValue.trimmed
            UserDefaults.standard.set(trimmed, forKey: RemoteRecognitionProvider.endpointKey)
        }
    }

    var isConfigured: Bool {
        guard let url = URL(string: endpoint) else { return false }
        return url.scheme == "https" || url.scheme == "http"
    }

    var configurationHint: String {
        return "Enter the address of a fingerprint service that accepts Flow's JSON request."
    }

    func recognize(
        fingerprint: RecognitionFingerprint,
        sample: RecognitionSample,
        completion: @escaping (Result<RecognitionMatch, RecognitionError>) -> Void
    ) {
        guard let url = URL(string: endpoint), isConfigured else {
            completion(.failure(.providerUnavailable(displayName)))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Flow-iOS", forHTTPHeaderField: "User-Agent")

        // The peaks, not the audio: a fingerprint cannot be turned back into a recording.
        let body: [String: Any] = [
            "version": 1,
            "duration": fingerprint.duration,
            "sampleRate": fingerprint.sampleRate,
            "peaks": fingerprint.peaks.prefix(2000).map { [Int($0.hash), $0.time] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            completion(.failure(.malformedResponse))
            return
        }
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { payload, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    let nsError = error as NSError
                    if nsError.code == NSURLErrorNotConnectedToInternet || nsError.code == NSURLErrorCannotFindHost {
                        completion(.failure(.network("Recognition needs an internet connection.")))
                    } else if nsError.code == NSURLErrorTimedOut {
                        completion(.failure(.network("The recognition service took too long to answer.")))
                    } else {
                        completion(.failure(.network(error.localizedDescription)))
                    }
                    return
                }
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 404 {
                        completion(.failure(.noMatch))
                        return
                    }
                    if http.statusCode == 429 {
                        completion(.failure(.network("Recognition is busy. Try again in a moment.")))
                        return
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        completion(.failure(.network("The recognition service returned an error (" + String(http.statusCode) + ").")))
                        return
                    }
                }
                guard let payload = payload,
                      let root = (try? JSONSerialization.jsonObject(with: payload, options: [])) as? [String: Any] else {
                    completion(.failure(.malformedResponse))
                    return
                }
                if let matched = root["match"] as? [String: Any] {
                    completion(RemoteRecognitionProvider.result(from: matched, provider: self.displayName))
                    return
                }
                if let matched = root["track"] as? [String: Any] {
                    completion(RemoteRecognitionProvider.result(from: matched, provider: self.displayName))
                    return
                }
                if let title = root["title"] as? String, !title.isEmpty {
                    completion(RemoteRecognitionProvider.result(from: root, provider: self.displayName))
                    return
                }
                completion(.failure(.noMatch))
            }
        }.resume()
    }

    private static func result(from dictionary: [String: Any], provider: String) -> Result<RecognitionMatch, RecognitionError> {
        guard let title = dictionary["title"] as? String, !title.isEmpty else {
            return .failure(.noMatch)
        }
        let artist = (dictionary["artist"] as? String) ?? (dictionary["subtitle"] as? String) ?? ""
        let album = (dictionary["album"] as? String) ?? ""
        let artwork = (dictionary["artwork"] as? String)
            ?? (dictionary["artworkUrl"] as? String)
            ?? (dictionary["coverArt"] as? String)
            ?? ""
        let videoId = (dictionary["videoId"] as? String) ?? (dictionary["youtubeVideoId"] as? String) ?? ""
        let confidence = (dictionary["confidence"] as? NSNumber)?.doubleValue ?? 0.8
        return .success(RecognitionMatch(
            title: title,
            artist: artist,
            album: album,
            artworkUrl: artwork,
            youtubeVideoId: videoId,
            providerName: provider,
            confidence: min(max(confidence, 0.0), 1.0)
        ))
    }
}

// MARK: - Registry

/// The provider the viewer chose. A provider that is not configured is still returned, so the
/// screen can explain exactly what is missing instead of silently doing nothing.
final class RecognitionProviderRegistry {

    static let shared = RecognitionProviderRegistry()

    private static let selectedKey = "recognition.provider"

    private var providers: [RecognitionProvider] = []
    private let lock = NSLock()

    private init() {
        providers = [RemoteRecognitionProvider(), LocalCatalogRecognitionProvider()]
    }

    /// Registers (or replaces) a provider. A feature that plugs in its own matcher calls this.
    func register(_ provider: RecognitionProvider) {
        lock.lock()
        providers.removeAll { $0.identifier == provider.identifier }
        providers.append(provider)
        lock.unlock()
    }

    var all: [RecognitionProvider] {
        lock.lock()
        let copy = providers
        lock.unlock()
        return copy
    }

    /// The provider the viewer picked, or nil when none was ever chosen.
    var selected: RecognitionProvider? {
        let id = UserDefaults.standard.string(forKey: RecognitionProviderRegistry.selectedKey) ?? ""
        guard !id.isEmpty else { return nil }
        return all.first { $0.identifier == id }
    }

    var selectedIdentifier: String? {
        let id = UserDefaults.standard.string(forKey: RecognitionProviderRegistry.selectedKey) ?? ""
        return id.isEmpty ? nil : id
    }

    func select(identifier: String?) {
        if let identifier = identifier, !identifier.isEmpty {
            UserDefaults.standard.set(identifier, forKey: RecognitionProviderRegistry.selectedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: RecognitionProviderRegistry.selectedKey)
        }
    }
}

// MARK: - History

/// One recognised song, kept on the device so the history survives a relaunch. There is no
/// recognition table in `FlowDB`, and the history is not part of a sync, so it lives in its own
/// small JSON file.
struct RecognitionHistoryEntry {
    let id: String
    let title: String
    let artist: String
    let album: String
    let artworkUrl: String
    let youtubeVideoId: String
    let providerName: String
    let matchedAt: Date
}

final class RecognitionHistoryStore {

    static let shared = RecognitionHistoryStore()

    private let lock = NSLock()
    private var cached: [RecognitionHistoryEntry]?

    private var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("Flow", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
        return directory.appendingPathComponent("recognition-history.json")
    }

    func all() -> [RecognitionHistoryEntry] {
        lock.lock()
        if let cached = cached {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let loaded = load()
        lock.lock()
        cached = loaded
        lock.unlock()
        return loaded
    }

    func search(_ query: String) -> [RecognitionHistoryEntry] {
        let trimmed = query.trimmed
        let entries = all()
        guard !trimmed.isEmpty else { return entries }
        let lowered = trimmed.lowercased()
        return entries.filter {
            $0.title.lowercased().contains(lowered)
                || $0.artist.lowercased().contains(lowered)
                || $0.album.lowercased().contains(lowered)
        }
    }

    /// Adds a match, moving a repeat of the same song to the top rather than storing it twice.
    func save(_ match: RecognitionMatch) {
        let key = (match.title + "|" + match.artist).lowercased()
        var entries = all().filter { ($0.title + "|" + $0.artist).lowercased() != key }
        let entry = RecognitionHistoryEntry(
            id: UUID().uuidString,
            title: match.title,
            artist: match.artist,
            album: match.album,
            artworkUrl: match.artworkUrl,
            youtubeVideoId: match.youtubeVideoId,
            providerName: match.providerName,
            matchedAt: Date()
        )
        entries.insert(entry, at: 0)
        if entries.count > 300 {
            entries = Array(entries.prefix(300))
        }
        store(entries)
    }

    func delete(id: String) {
        store(all().filter { $0.id != id })
    }

    func clear() {
        store([])
    }

    private func store(_ entries: [RecognitionHistoryEntry]) {
        lock.lock()
        cached = entries
        lock.unlock()

        let payload: [String: Any] = [
            "version": 1,
            "entries": entries.map { entry in
                [
                    "id": entry.id,
                    "title": entry.title,
                    "artist": entry.artist,
                    "album": entry.album,
                    "artwork": entry.artworkUrl,
                    "videoId": entry.youtubeVideoId,
                    "provider": entry.providerName,
                    "matchedAt": entry.matchedAt.timeIntervalSince1970,
                ] as [String: Any]
            },
        ]
        guard let url = fileURL, let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private func load() -> [RecognitionHistoryEntry] {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              let raw = root["entries"] as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { item in
            guard let title = item["title"] as? String, !title.isEmpty else { return nil }
            let stamp = (item["matchedAt"] as? NSNumber)?.doubleValue ?? 0.0
            return RecognitionHistoryEntry(
                id: (item["id"] as? String) ?? UUID().uuidString,
                title: title,
                artist: (item["artist"] as? String) ?? "",
                album: (item["album"] as? String) ?? "",
                artworkUrl: (item["artwork"] as? String) ?? "",
                youtubeVideoId: (item["videoId"] as? String) ?? "",
                providerName: (item["provider"] as? String) ?? "",
                matchedAt: Date(timeIntervalSince1970: stamp)
            )
        }
    }
}

// MARK: - Capture

/// Records a short mono sample from the microphone and reports the level while it does, so the
/// screen can show that Flow is actually hearing something.
final class RecognitionAudioCapture {

    /// Called with the RMS level, 0...1, on the main queue.
    var onLevel: ((Float) -> Void)?
    /// Called when the recording has finished, with the sample or the reason it failed.
    var onFinish: ((Result<RecognitionSample, RecognitionError>) -> Void)?

    /// How long a sample is. Long enough for a fingerprint, short enough to feel instant.
    static let sampleDuration: TimeInterval = 6.0

    private let engine = AVAudioEngine()
    private var collected: [Float] = []
    private var sampleRate: Double = 44100.0
    private var isRunning = false
    private var hasFinished = false
    private var stopWorkItem: DispatchWorkItem?
    /// Guards `collected`: the tap appends on the audio thread while the main thread reads it when
    /// the recording stops.
    private let bufferLock = NSLock()

    var isCapturing: Bool {
        return isRunning
    }

    /// Requests the microphone and starts recording. The completion runs on the main queue.
    func start() {
        guard !isRunning else { return }
        hasFinished = false
        collected.removeAll(keepingCapacity: true)

        let session = AVAudioSession.sharedInstance()
        session.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard granted else {
                    self.finish(.failure(.permissionDenied))
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            finish(.failure(.engineFailed(error.localizedDescription)))
            return
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0.0, format.channelCount > 0 else {
            finish(.failure(.noInput))
            return
        }
        sampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            finish(.failure(.engineFailed(error.localizedDescription)))
            return
        }
        isRunning = true

        let work = DispatchWorkItem { [weak self] in
            self?.stop()
        }
        stopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + RecognitionAudioCapture.sampleDuration, execute: work)
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channels = Int(buffer.format.channelCount)

        var mono = [Float](repeating: 0.0, count: frames)
        for channel in 0..<channels {
            let pointer = channelData[channel]
            for index in 0..<frames {
                mono[index] += pointer[index]
            }
        }
        let divisor = Float(max(channels, 1))
        for index in 0..<frames {
            mono[index] /= divisor
        }

        bufferLock.lock()
        collected.append(contentsOf: mono)
        bufferLock.unlock()

        var sum: Float = 0.0
        vDSP_svesq(mono, 1, &sum, vDSP_Length(frames))
        let rms = sqrt(sum / Float(frames))
        // A -50 dB floor and a -6 dB ceiling map to 0...1; the meter reads like a level meter.
        let decibels = 20.0 * log10(max(rms, 0.00001))
        let normalised = min(max((decibels + 50.0) / 44.0, 0.0), 1.0)
        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(normalised)
        }
    }

    /// Stops early and finishes with what was recorded so far.
    func stop() {
        guard isRunning else { return }
        stopWorkItem?.cancel()
        stopWorkItem = nil
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)

        bufferLock.lock()
        let samples = collected
        collected.removeAll(keepingCapacity: false)
        bufferLock.unlock()

        finish(.success(RecognitionSample(samples: samples, sampleRate: sampleRate)))
    }

    /// Stops without producing a result, e.g. when the screen goes away.
    func cancel() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        bufferLock.lock()
        collected.removeAll(keepingCapacity: false)
        bufferLock.unlock()
    }

    private func finish(_ result: Result<RecognitionSample, RecognitionError>) {
        guard !hasFinished else { return }
        hasFinished = true
        stopWorkItem?.cancel()
        stopWorkItem = nil
        onFinish?(result)
    }
}

// MARK: - Level meter

/// The listening indicator: a ring of bars whose height follows the microphone, drawn with
/// `CAShapeLayer` so it moves at the audio rate without rebuilding views.
final class RecognitionLevelMeter: UIView {

    private let barsLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private let pulseLayer = CAShapeLayer()
    private var levels: [CGFloat] = []
    private let barCount = 32

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        levels = [CGFloat](repeating: 0.06, count: barCount)

        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.lineWidth = 2.0
        layer.addSublayer(ringLayer)

        pulseLayer.fillColor = UIColor.clear.cgColor
        pulseLayer.lineWidth = 2.0
        pulseLayer.opacity = 0.0
        layer.addSublayer(pulseLayer)

        barsLayer.fillColor = UIColor.clear.cgColor
        barsLayer.lineWidth = 3.0
        barsLayer.lineCap = .round
        layer.addSublayer(barsLayer)
        applyTheme()
    }

    /// Adds one level reading. Values are 0...1.
    func push(level: Float) {
        let value = CGFloat(min(max(level, 0.0), 1.0))
        levels.removeFirst()
        levels.append(max(value, 0.05))
        redraw()
    }

    func reset() {
        levels = [CGFloat](repeating: 0.06, count: barCount)
        redraw()
    }

    /// Starts the slow outward pulse that says "listening".
    func startPulsing() {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.7
        animation.toValue = 0.0
        animation.duration = 1.4
        animation.repeatCount = .infinity
        pulseLayer.add(animation, forKey: "pulse")

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.75
        scale.toValue = 1.0
        scale.duration = 1.4
        scale.repeatCount = .infinity
        pulseLayer.add(scale, forKey: "pulseScale")
    }

    func stopPulsing() {
        pulseLayer.removeAllAnimations()
        pulseLayer.opacity = 0.0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        redraw()
    }

    private func redraw() {
        let side = min(bounds.width, bounds.height)
        guard side > 0.0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let ringRadius = side / 2.0 - 2.0
        ringLayer.path = UIBezierPath(ovalIn: CGRect(
            x: center.x - ringRadius,
            y: center.y - ringRadius,
            width: ringRadius * 2.0,
            height: ringRadius * 2.0
        )).cgPath
        pulseLayer.path = ringLayer.path
        pulseLayer.frame = bounds

        let barRadius = ringRadius * 0.72
        let path = UIBezierPath()
        for index in 0..<barCount {
            let angle = (CGFloat(index) / CGFloat(barCount)) * CGFloat.pi * 2.0 - CGFloat.pi / 2.0
            let level = levels[index]
            let inner = barRadius - 4.0 - level * 14.0
            let outer = barRadius + 4.0 + level * 14.0
            let start = CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner)
            let end = CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer)
            path.move(to: start)
            path.addLine(to: end)
        }
        barsLayer.path = path.cgPath
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        ringLayer.strokeColor = scheme.outlineVariant.cgColor
        pulseLayer.strokeColor = scheme.primary.cgColor
        barsLayer.strokeColor = scheme.primary.cgColor
    }
}

// MARK: - History cell

/// One recognised song in the history list.
final class RecognitionHistoryCell: UITableViewCell {

    static let reuseIdentifier = "RecognitionHistoryCell"

    private let artwork = AsyncImageView.make(contentMode: .scaleAspectFill, cornerRadius: FlowShapes.thumbnail)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let timeLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .default
        let selected = UIView()
        selected.backgroundColor = FlowTheme.shared.scheme.surfaceContainerHigh
        selectedBackgroundView = selected

        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = FlowShapes.thumbnail
        contentView.addSubview(artwork)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 1
        contentView.addSubview(titleLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 1
        contentView.addSubview(detailLabel)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = FlowTypography.labelSmall
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        contentView.addSubview(timeLabel)

        NSLayoutConstraint.activate([
            artwork.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            artwork.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            artwork.widthAnchor.constraint(equalToConstant: 48.0),
            artwork.heightAnchor.constraint(equalToConstant: 48.0),

            titleLabel.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: FlowSpacing.lg),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -FlowSpacing.md),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -FlowSpacing.md),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2.0),
            detailLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.lg),

            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            timeLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 68.0),
        ])
        applyTheme()
    }

    func configure(entry: RecognitionHistoryEntry) {
        titleLabel.text = entry.title
        let parts = [entry.artist, entry.album].filter { !$0.isEmpty }
        detailLabel.text = parts.isEmpty ? (entry.providerName.isEmpty ? "Recognised song" : entry.providerName) : parts.joined(separator: " · ")
        timeLabel.text = Formatters.relativeDate(entry.matchedAt)
        if entry.artworkUrl.isEmpty {
            artwork.clearImage()
        } else {
            artwork.setImage(url: entry.artworkUrl)
        }
        applyTheme()
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
        timeLabel.textColor = scheme.onSurfaceVariant
        artwork.backgroundColor = scheme.surfaceContainerHighest
        (selectedBackgroundView as? UIView)?.backgroundColor = scheme.surfaceContainerHigh
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artwork.clearImage()
    }
}

// MARK: - Screen

/// The recognition screen: a big listening button, a level meter that proves the microphone is
/// hearing something, the match it found, and the songs it has recognised before.
///
/// The screen owns the audio capture and the state machine. The matching itself is delegated to
/// whichever `RecognitionProvider` the viewer configured; when none is configured the screen says
/// so and offers the configuration sheet instead of pretending to listen.
final class RecognitionViewController: UIViewController {

    // MARK: - Navigation

    /// Called when the viewer wants to play the recognised song.
    var onOpenVideo: ((String) -> Void)?
    /// Called when the viewer wants to search for the recognised song.
    var onSearch: ((String) -> Void)?

    // MARK: - State

    private enum State {
        case ready
        case listening
        case processing
        case success(RecognitionMatch)
        case failed(String)
    }

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let meter = RecognitionLevelMeter()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let listenButton = FlowButton.make("Listen", style: .filled, icon: .mic)
    private let providerLabel = UILabel()
    private let configureButton = FlowButton.make("Configure", style: .text, icon: .settings)
    private let resultCard = FlowCard.make(elevation: .high)
    private let resultArtwork = AsyncImageView.make(contentMode: .scaleAspectFill, cornerRadius: FlowShapes.medium)
    private let resultTitle = UILabel()
    private let resultArtist = UILabel()
    private let resultAlbum = UILabel()
    private let resultActions = UIStackView()
    private let playButton = FlowButton.make("Play", style: .filled, icon: .play)
    private let searchButton = FlowButton.make("Search", style: .outlined, icon: .search)
    private let historyHeader = FlowSectionHeader.make(title: "Recognition history")
    private let searchBar = RecognitionSearchBar()
    private let historyTable = UITableView(frame: .zero, style: .plain)
    private let historyEmpty = UILabel()
    private var historyHeight: NSLayoutConstraint?

    private let capture = RecognitionAudioCapture()
    private var state: State = .ready
    private var history: [RecognitionHistoryEntry] = []
    private var query: String = ""
    private var themeToken: ObservationToken?

    deinit {
        themeToken?.cancelObservation()
        capture.cancel()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Recognise"
        view.backgroundColor = FlowTheme.shared.background
        buildLayout()
        bindCapture()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        applyTheme()
        reloadHistory()
        refreshProviderLine()
        setState(.ready)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        refreshProviderLine()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if case .listening = state {
            cancelListening()
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return FlowTheme.shared.isDark ? .lightContent : .default
    }

    // MARK: - Layout

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag
        view.addSubview(scrollView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = FlowSpacing.lg
        contentStack.alignment = .fill
        scrollView.addSubview(contentStack)

        let listenSection = UIView()
        listenSection.translatesAutoresizingMaskIntoConstraints = false
        listenSection.addSubview(meter)
        listenSection.addSubview(statusLabel)
        listenSection.addSubview(detailLabel)
        listenSection.addSubview(listenButton)

        meter.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = FlowTypography.headlineSmall
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.bodyMedium
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 3
        listenButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            meter.centerXAnchor.constraint(equalTo: listenSection.centerXAnchor),
            meter.topAnchor.constraint(equalTo: listenSection.topAnchor, constant: FlowSpacing.lg),
            meter.widthAnchor.constraint(equalToConstant: 168.0),
            meter.heightAnchor.constraint(equalToConstant: 168.0),

            statusLabel.leadingAnchor.constraint(equalTo: listenSection.leadingAnchor, constant: FlowSpacing.xl),
            statusLabel.trailingAnchor.constraint(equalTo: listenSection.trailingAnchor, constant: -FlowSpacing.xl),
            statusLabel.topAnchor.constraint(equalTo: meter.bottomAnchor, constant: FlowSpacing.lg),

            detailLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: FlowSpacing.xs),

            listenButton.centerXAnchor.constraint(equalTo: listenSection.centerXAnchor),
            listenButton.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: FlowSpacing.lg),
            listenButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 168.0),
            listenButton.heightAnchor.constraint(equalToConstant: 48.0),
            listenButton.bottomAnchor.constraint(equalTo: listenSection.bottomAnchor, constant: -FlowSpacing.md),
        ])
        contentStack.addArrangedSubview(listenSection)

        let providerRow = UIStackView(arrangedSubviews: [providerLabel, configureButton])
        providerRow.axis = .horizontal
        providerRow.alignment = .center
        providerRow.spacing = FlowSpacing.md
        providerLabel.font = FlowTypography.bodySmall
        providerLabel.numberOfLines = 2
        providerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configureButton.setContentHuggingPriority(.required, for: .horizontal)
        configureButton.onTap = { [weak self] in
            self?.presentConfiguration()
        }
        contentStack.addArrangedSubview(providerRow)

        buildResultCard()
        contentStack.addArrangedSubview(resultCard)

        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.onChange = { [weak self] text in
            guard let self = self else { return }
            self.query = text
            self.reloadHistory()
        }
        contentStack.addArrangedSubview(searchBar)

        contentStack.addArrangedSubview(historyHeader)
        historyHeader.setActionTitle("Clear")
        historyHeader.onAction = { [weak self] in
            self?.confirmClearHistory()
        }

        historyTable.translatesAutoresizingMaskIntoConstraints = false
        historyTable.backgroundColor = .clear
        historyTable.separatorStyle = .none
        historyTable.rowHeight = UITableView.automaticDimension
        historyTable.estimatedRowHeight = 68.0
        historyTable.isScrollEnabled = false
        historyTable.dataSource = self
        historyTable.delegate = self
        historyTable.register(RecognitionHistoryCell.self, forCellReuseIdentifier: RecognitionHistoryCell.reuseIdentifier)
        let tableHeight = historyTable.heightAnchor.constraint(equalToConstant: 0.0)
        tableHeight.priority = UILayoutPriority(999.0)
        tableHeight.isActive = true
        historyHeight = tableHeight
        contentStack.addArrangedSubview(historyTable)

        historyEmpty.translatesAutoresizingMaskIntoConstraints = false
        historyEmpty.font = FlowTypography.bodyMedium
        historyEmpty.textAlignment = .center
        historyEmpty.numberOfLines = 2
        historyEmpty.text = "Recognised songs will appear here"
        contentStack.addArrangedSubview(historyEmpty)

        listenButton.onTap = { [weak self] in
            self?.handleListen()
        }
        playButton.onTap = { [weak self] in
            self?.playCurrentMatch()
        }
        searchButton.onTap = { [weak self] in
            self?.searchCurrentMatch()
        }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: FlowSpacing.screenMargin),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: FlowSpacing.md),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -FlowSpacing.xxl),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -FlowSpacing.screenMargin * 2.0),
        ])
    }

    private func buildResultCard() {
        resultCard.isHidden = true
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = FlowSpacing.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        resultCard.contentView.addSubview(stack)

        resultArtwork.translatesAutoresizingMaskIntoConstraints = false
        resultArtwork.clipsToBounds = true
        resultArtwork.layer.cornerRadius = FlowShapes.medium
        resultArtwork.heightAnchor.constraint(equalToConstant: 160.0).isActive = true

        resultTitle.font = FlowTypography.titleLarge
        resultTitle.numberOfLines = 2
        resultArtist.font = FlowTypography.bodyLarge
        resultArtist.numberOfLines = 1
        resultAlbum.font = FlowTypography.bodySmall
        resultAlbum.numberOfLines = 1

        resultActions.axis = .horizontal
        resultActions.spacing = FlowSpacing.md
        resultActions.distribution = .fillEqually
        resultActions.addArrangedSubview(playButton)
        resultActions.addArrangedSubview(searchButton)

        stack.addArrangedSubview(resultArtwork)
        stack.addArrangedSubview(resultTitle)
        stack.addArrangedSubview(resultArtist)
        stack.addArrangedSubview(resultAlbum)
        stack.setCustomSpacing(FlowSpacing.md, after: resultAlbum)
        stack.addArrangedSubview(resultActions)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: resultCard.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: resultCard.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: resultCard.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: resultCard.contentView.bottomAnchor),
        ])
    }

    // MARK: - Capture

    private func bindCapture() {
        capture.onLevel = { [weak self] level in
            self?.meter.push(level: level)
        }
        capture.onFinish = { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let sample):
                self.handle(sample: sample)
            case .failure(let error):
                self.fail(error)
            }
        }
    }

    private func handleListen() {
        if case .listening = state {
            capture.stop()
            return
        }
        guard let provider = RecognitionProviderRegistry.shared.selected else {
            presentConfiguration()
            return
        }
        guard provider.isConfigured else {
            setState(.failed(provider.configurationHint))
            presentConfiguration()
            return
        }
        meter.reset()
        meter.startPulsing()
        setState(.listening)
        capture.start()
    }

    private func cancelListening() {
        capture.cancel()
        meter.stopPulsing()
        meter.reset()
        setState(.ready)
    }

    private func handle(sample: RecognitionSample) {
        meter.stopPulsing()
        guard sample.duration > 0.5 else {
            fail(.engineFailed("The recording was too short to analyse."))
            return
        }
        guard sample.peak > 0.004 else {
            fail(.tooQuiet)
            return
        }
        guard let provider = RecognitionProviderRegistry.shared.selected else {
            fail(.noProvider)
            return
        }
        setState(.processing)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fingerprint = FingerprintBuilder.build(samples: sample.samples, sampleRate: sample.sampleRate)
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard !fingerprint.isEmpty else {
                    self.fail(.tooQuiet)
                    return
                }
                provider.recognize(fingerprint: fingerprint, sample: sample) { [weak self] result in
                    guard let self = self else { return }
                    switch result {
                    case .success(let match):
                        RecognitionHistoryStore.shared.save(match)
                        self.reloadHistory()
                        self.setState(.success(match))
                    case .failure(let error):
                        self.fail(error)
                    }
                }
            }
        }
    }

    private func fail(_ error: RecognitionError) {
        meter.stopPulsing()
        setState(.failed(error.message))
    }

    // MARK: - State

    private func setState(_ next: State) {
        state = next
        switch next {
        case .ready:
            statusLabel.text = "Tap listen"
            detailLabel.text = "Flow listens for a few seconds and matches the song on this device."
            listenButton.configure(title: "Listen", style: .filled, icon: .mic)
            listenButton.isEnabled = true
            resultCard.isHidden = true
        case .listening:
            statusLabel.text = "Listening…"
            detailLabel.text = "Hold your phone near the music."
            listenButton.configure(title: "Stop", style: .tonal, icon: .pause)
            listenButton.isEnabled = true
            resultCard.isHidden = true
        case .processing:
            statusLabel.text = "Matching…"
            detailLabel.text = "Comparing the fingerprint with your provider."
            listenButton.configure(title: "Matching", style: .filled, icon: .mic)
            listenButton.isEnabled = false
            resultCard.isHidden = true
        case .success(let match):
            statusLabel.text = "Found it"
            detailLabel.text = "Matched by " + match.providerName + "."
            listenButton.configure(title: "Listen again", style: .filled, icon: .mic)
            listenButton.isEnabled = true
            show(match: match)
        case .failed(let message):
            statusLabel.text = "Not recognised"
            detailLabel.text = message
            listenButton.configure(title: "Try again", style: .filled, icon: .mic)
            listenButton.isEnabled = true
            resultCard.isHidden = true
        }
        listenButton.applyTheme()
        UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
    }

    private func show(match: RecognitionMatch) {
        resultCard.isHidden = false
        resultTitle.text = match.title
        resultArtist.text = match.artist.isEmpty ? "Unknown artist" : match.artist
        resultAlbum.text = match.album
        resultAlbum.isHidden = match.album.isEmpty
        if match.artworkUrl.isEmpty {
            resultArtwork.clearImage()
        } else {
            resultArtwork.setImage(url: match.artworkUrl)
        }
        playButton.isEnabled = !match.youtubeVideoId.isEmpty
        playButton.applyTheme()
    }

    private var currentMatch: RecognitionMatch? {
        if case .success(let match) = state { return match }
        return nil
    }

    private func playCurrentMatch() {
        guard let match = currentMatch, !match.youtubeVideoId.isEmpty else { return }
        if let open = onOpenVideo {
            open(match.youtubeVideoId)
            return
        }
        Router.shared.openWatch(videoId: match.youtubeVideoId)
    }

    private func searchCurrentMatch() {
        guard let match = currentMatch else { return }
        let text = [match.title, match.artist].filter { !$0.isEmpty }.joined(separator: " ")
        if let search = onSearch {
            search(text)
            return
        }
        Router.shared.openSearch(query: text)
    }

    // MARK: - Provider

    private func refreshProviderLine() {
        guard let provider = RecognitionProviderRegistry.shared.selected else {
            providerLabel.text = "No provider configured. Choose how Flow should match songs."
            configureButton.configure(title: "Set up", style: .text, icon: .settings)
            return
        }
        if provider.isConfigured {
            providerLabel.text = "Matching with " + provider.displayName + "."
            configureButton.configure(title: "Change", style: .text, icon: .settings)
        } else {
            providerLabel.text = provider.displayName + " needs setting up. " + provider.configurationHint
            configureButton.configure(title: "Set up", style: .text, icon: .settings)
        }
        configureButton.applyTheme()
    }

    private func presentConfiguration() {
        let content = RecognitionProviderConfigContent()
        let sheet = FlowSheet(content: content, title: "Recognition provider", detent: .large, showsGrabber: true)
        content.onDone = { [weak self, weak sheet] in
            sheet?.dismissSheet()
            self?.refreshProviderLine()
            self?.setState(.ready)
        }
        sheet.present(from: self)
    }

    // MARK: - History

    private func reloadHistory() {
        history = RecognitionHistoryStore.shared.search(query)
        historyTable.reloadData()
        let hasAny = RecognitionHistoryStore.shared.all().count > 0
        historyEmpty.isHidden = !history.isEmpty
        historyTable.isHidden = history.isEmpty
        historyHeader.setActionTitle(hasAny ? "Clear" : nil)
        if hasAny && history.isEmpty {
            historyEmpty.text = "No recognised songs match that search"
        } else {
            historyEmpty.text = "Recognised songs will appear here"
        }
        updateTableHeight()
    }

    /// The history table sits inside the page's scroll view, so it takes exactly the height of its
    /// rows instead of scrolling itself.
    private func updateTableHeight() {
        historyTable.layoutIfNeeded()
        historyHeight?.constant = historyTable.contentSize.height
    }

    private func confirmClearHistory() {
        let alert = UIAlertController(
            title: "Clear history?",
            message: "This removes all recognised songs. This cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive, handler: { [weak self] _ in
            RecognitionHistoryStore.shared.clear()
            self?.reloadHistory()
        }))
        present(alert, animated: true, completion: nil)
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        scrollView.backgroundColor = .clear
        statusLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
        providerLabel.textColor = scheme.onSurfaceVariant
        historyEmpty.textColor = scheme.onSurfaceVariant
        meter.applyTheme()
        listenButton.applyTheme()
        configureButton.applyTheme()
        playButton.applyTheme()
        searchButton.applyTheme()
        resultCard.applyTheme()
        resultTitle.textColor = scheme.onSurface
        resultArtist.textColor = scheme.onSurfaceVariant
        resultAlbum.textColor = scheme.onSurfaceVariant
        resultArtwork.backgroundColor = scheme.surfaceContainerHighest
        historyHeader.applyTheme()
        searchBar.applyTheme()
        historyTable.reloadData()
    }
}

// MARK: - Data source

extension RecognitionViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return history.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: RecognitionHistoryCell.reuseIdentifier, for: indexPath)
        if let historyCell = cell as? RecognitionHistoryCell, let entry = history.element(at: indexPath.row) {
            historyCell.configure(entry: entry)
        }
        return cell
    }
}

// MARK: - Delegate

extension RecognitionViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let entry = history.element(at: indexPath.row) else { return }
        if !entry.youtubeVideoId.isEmpty {
            if let open = onOpenVideo {
                open(entry.youtubeVideoId)
            } else {
                Router.shared.openWatch(videoId: entry.youtubeVideoId)
            }
            return
        }
        let text = [entry.title, entry.artist].filter { !$0.isEmpty }.joined(separator: " ")
        if let search = onSearch {
            search(text)
        } else {
            Router.shared.openSearch(query: text)
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let entry = history.element(at: indexPath.row) else { return nil }
        let remove = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            RecognitionHistoryStore.shared.delete(id: entry.id)
            self?.reloadHistory()
            completion(true)
        }
        remove.backgroundColor = FlowTheme.shared.scheme.error
        return UISwipeActionsConfiguration(actions: [remove])
    }
}

// MARK: - Search bar

/// The history search field.
final class RecognitionSearchBar: UIView, UITextFieldDelegate {

    var onChange: ((String) -> Void)?

    private let container = UIView()
    private let field = UITextField()
    private let icon = FlowIconView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 20.0
        addSubview(container)

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.icon = .search
        icon.iconSize = 18.0
        icon.widthAnchor.constraint(equalToConstant: 18.0).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18.0).isActive = true
        container.addSubview(icon)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = FlowTypography.bodyMedium
        field.returnKeyType = .search
        field.clearButtonMode = .whileEditing
        field.autocorrectionType = .no
        field.delegate = self
        field.addTarget(self, action: #selector(handleChange), for: .editingChanged)
        container.addSubview(field)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 40.0),

            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: FlowSpacing.lg),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: FlowSpacing.md),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -FlowSpacing.lg),
            field.topAnchor.constraint(equalTo: container.topAnchor),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        applyTheme()
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        container.backgroundColor = scheme.surfaceContainerHigh
        icon.iconColor = scheme.onSurfaceVariant
        field.textColor = scheme.onSurface
        field.attributedPlaceholder = NSAttributedString(
            string: "Search recognised songs",
            attributes: [.foregroundColor: scheme.onSurfaceVariant]
        )
    }

    @objc private func handleChange() {
        onChange?(field.text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

// MARK: - Provider configuration

/// The sheet that chooses the provider and fills in what it needs. Every option explains what it
/// does and where the data goes, because the difference between on-device and a network service is
/// the viewer's decision, not the app's.
final class RecognitionProviderConfigContent: UIView, UITextFieldDelegate {

    var onDone: (() -> Void)?

    private let stack = UIStackView()
    private let providerChips = FlowChipRow()
    private let endpointLabel = UILabel()
    private let endpointField = UITextField()
    private let endpointContainer = UIView()
    private let importButton = FlowButton.make("Import fingerprint catalog", style: .outlined, icon: .importIcon)
    private let catalogLabel = UILabel()
    private let doneButton = FlowButton.make("Done", style: .filled)
    private let explanation = UILabel()

    private var providers: [RecognitionProvider] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        providers = RecognitionProviderRegistry.shared.all

        stack.axis = .vertical
        stack.spacing = FlowSpacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let intro = UILabel()
        intro.font = FlowTypography.bodyMedium
        intro.numberOfLines = 0
        intro.text = "Flow matches the song with whichever provider you choose. Audio is never uploaded; only a fingerprint of the sound is compared."
        stack.addArrangedSubview(intro)

        providerChips.setTitles(providers.map { $0.displayName }, selectedIndex: selectedIndex())
        providerChips.onSelect = { [weak self] index in
            guard let self = self, let provider = self.providers.element(at: index) else { return }
            RecognitionProviderRegistry.shared.select(identifier: provider.identifier)
            self.refresh()
        }
        stack.addArrangedSubview(providerChips)

        explanation.font = FlowTypography.bodySmall
        explanation.numberOfLines = 0
        stack.addArrangedSubview(explanation)

        endpointLabel.font = FlowTypography.titleSmall
        endpointLabel.text = "Service address"
        stack.addArrangedSubview(endpointLabel)

        endpointContainer.layer.cornerRadius = FlowShapes.small
        endpointContainer.translatesAutoresizingMaskIntoConstraints = false
        endpointField.translatesAutoresizingMaskIntoConstraints = false
        endpointField.font = FlowTypography.bodyMedium
        endpointField.placeholder = "https://example.local/recognise"
        endpointField.keyboardType = .URL
        endpointField.autocapitalizationType = .none
        endpointField.autocorrectionType = .no
        endpointField.delegate = self
        endpointField.addTarget(self, action: #selector(endpointChanged), for: .editingChanged)
        endpointContainer.addSubview(endpointField)
        endpointContainer.heightAnchor.constraint(equalToConstant: 44.0).isActive = true
        stack.addArrangedSubview(endpointContainer)

        catalogLabel.font = FlowTypography.bodySmall
        catalogLabel.numberOfLines = 0
        stack.addArrangedSubview(catalogLabel)

        importButton.onTap = { [weak self] in
            self?.importCatalog()
        }
        stack.addArrangedSubview(importButton)

        doneButton.onTap = { [weak self] in
            self?.endpointField.resignFirstResponder()
            self?.onDone?()
        }
        stack.addArrangedSubview(doneButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xl),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.xl),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.md),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -FlowSpacing.md),

            endpointField.leadingAnchor.constraint(equalTo: endpointContainer.leadingAnchor, constant: FlowSpacing.md),
            endpointField.trailingAnchor.constraint(equalTo: endpointContainer.trailingAnchor, constant: -FlowSpacing.md),
            endpointField.topAnchor.constraint(equalTo: endpointContainer.topAnchor),
            endpointField.bottomAnchor.constraint(equalTo: endpointContainer.bottomAnchor),
        ])
        applyTheme()
        refresh()
    }

    private func selectedIndex() -> Int {
        guard let id = RecognitionProviderRegistry.shared.selectedIdentifier else { return 0 }
        return providers.firstIndex { $0.identifier == id } ?? 0
    }

    private func refresh() {
        let provider = RecognitionProviderRegistry.shared.selected
        let remote = provider is RemoteRecognitionProvider
        endpointLabel.isHidden = !remote
        endpointContainer.isHidden = !remote
        importButton.isHidden = remote
        catalogLabel.isHidden = remote

        if let remoteProvider = provider as? RemoteRecognitionProvider {
            endpointField.text = remoteProvider.endpoint
            explanation.text = "The fingerprint is posted to the address you enter. Use a service you run or trust."
        } else {
            explanation.text = "Matching happens entirely on this device against a catalog you imported."
            let count = RecognitionCatalogStore.shared.count
            catalogLabel.text = count == 0
                ? "No catalog imported yet."
                : (count == 1 ? "1 song in the catalog." : String(count) + " songs in the catalog.")
        }
        if provider == nil {
            explanation.text = "Pick a provider to start recognising songs."
        }
        applyTheme()
    }

    @objc private func endpointChanged() {
        guard let remote = RecognitionProviderRegistry.shared.selected as? RemoteRecognitionProvider else { return }
        remote.endpoint = endpointField.text ?? ""
    }

    /// The controller that owns this sheet, found through the responder chain: a view inside a
    /// sheet has no presentation context of its own.
    private var hostController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }

    private func importCatalog() {
        guard let host = hostController else { return }
        let picker = UIDocumentPickerViewController(documentTypes: ["public.json", "public.data"], in: .import)
        picker.delegate = self
        picker.modalPresentationStyle = .formSheet
        host.flowTopMost.present(picker, animated: true, completion: nil)
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        stack.arrangedSubviews.forEach { view in
            (view as? UILabel)?.textColor = scheme.onSurfaceVariant
        }
        endpointLabel.textColor = scheme.onSurface
        endpointContainer.backgroundColor = scheme.surfaceContainerHigh
        endpointField.textColor = scheme.onSurface
        endpointField.attributedPlaceholder = NSAttributedString(
            string: "https://example.local/recognise",
            attributes: [.foregroundColor: scheme.onSurfaceVariant]
        )
        providerChips.applyTheme()
        importButton.applyTheme()
        doneButton.applyTheme()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

extension RecognitionProviderConfigContent: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else {
            FlowSnackbar.showError("That file could not be read")
            return
        }
        let count = RecognitionCatalogStore.shared.importCatalog(data: data)
        if count == 0 {
            FlowSnackbar.showError("No songs were found in that catalog")
        } else {
            FlowSnackbar.show(count == 1 ? "1 song imported" : String(count) + " songs imported")
            RecognitionProviderRegistry.shared.select(identifier: LocalCatalogRecognitionProvider().identifier)
        }
        refresh()
    }
}
