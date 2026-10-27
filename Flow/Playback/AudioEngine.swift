import Foundation
import AVFoundation
import AudioToolbox
import MediaToolbox

/// The kind of filter a band applies, matching the Android `EqFilterType`.
enum EqFilterType: String, CaseIterable {
    case peak
    case lowShelf
    case highShelf
    case lowPass
    case highPass

    var displayName: String {
        switch self {
        case .peak: return "Peak"
        case .lowShelf: return "Low shelf"
        case .highShelf: return "High shelf"
        case .lowPass: return "Low pass"
        case .highPass: return "High pass"
        }
    }
}

/// One equalizer band.
struct EqBand: Equatable {

    var frequency: Double
    var gain: Double
    var q: Double
    var type: EqFilterType
    var enabled: Bool

    init(
        frequency: Double,
        gain: Double = 0.0,
        q: Double = AudioEngine.defaultQ,
        type: EqFilterType = .peak,
        enabled: Bool = true
    ) {
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.type = type
        self.enabled = enabled
    }

    /// The band clamped to the ranges the engine accepts.
    var sanitised: EqBand {
        return EqBand(
            frequency: min(max(frequency, AudioEngine.minimumFrequency), AudioEngine.maximumFrequency),
            gain: min(max(gain, -AudioEngine.maximumGain), AudioEngine.maximumGain),
            q: min(max(q, AudioEngine.minimumQ), AudioEngine.maximumQ),
            type: type,
            enabled: enabled
        )
    }
}

/// A named set of band gains.
struct EqPreset: Equatable {

    let id: String
    let name: String
    /// The gains for the five bands, in the order the equalizer screen shows them.
    let gains: [Double]
    /// The preamp, in decibels.
    let preamp: Double

    init(id: String, name: String, gains: [Double], preamp: Double = 0.0) {
        self.id = id
        self.name = name
        self.gains = gains
        self.preamp = preamp
    }
}

/// The five-band equalizer.
///
/// Android's equalizer is an ExoPlayer `AudioProcessor` inserted between the decoder and the audio
/// sink. iOS has no such insertion point for `AVPlayer`, but it does have `MTAudioProcessingTap`,
/// which runs on the item's decoded audio on the render thread. That is the equivalent, and this
/// class is built on it: `audioMix(for:)` returns an `AVAudioMix` whose tap runs a cascade of RBJ
/// biquads — the same coefficient formulas `AVAudioUnitEQ` uses — for each channel.
///
/// Settings live here rather than in the tap so the equalizer screen can edit them while playback
/// runs: the tap reads the current coefficients under a lock on every buffer, so a slider move is
/// audible immediately without rebuilding the item.
final class AudioEngine {

    static let shared = AudioEngine()

    // MARK: - Limits

    static let minimumFrequency: Double = 20.0
    static let maximumFrequency: Double = 20_000.0
    static let maximumGain: Double = 24.0
    static let minimumQ: Double = 0.1
    static let maximumQ: Double = 20.0
    static let maximumPreamp: Double = 24.0
    /// The Q a peaking band uses by default, and the one the Android graphic EQ uses.
    static let defaultQ: Double = 1.41
    /// The Butterworth Q a shelf uses so it sums flat with its neighbours.
    static let shelfQ: Double = 0.707

    /// The five frequencies the equalizer screen shows.
    static let bandFrequencies: [Double] = [60.0, 230.0, 910.0, 3_600.0, 14_000.0]

    // MARK: - State

    private let lock = NSLock()
    private var storedBands: [EqBand]
    private var storedEnabled: Bool
    private var storedPreamp: Double
    private var storedPresetId: String
    /// The live coefficient sets, one per channel, rebuilt whenever the settings change.
    private var filters: [[BiquadFilter]] = []

    /// Called on the main queue whenever the settings change.
    var onChange: (() -> Void)?

    private init() {
        storedBands = AudioEngine.defaultBands()
        storedEnabled = false
        storedPreamp = 0.0
        storedPresetId = AudioEngine.flatPresetId
        restore()
    }

    /// The bands, in display order.
    var bands: [EqBand] {
        lock.lock()
        defer { lock.unlock() }
        return storedBands
    }

    /// Whether the equalizer is applied at all.
    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedEnabled
    }

    /// The preamp in decibels.
    var preamp: Double {
        lock.lock()
        defer { lock.unlock() }
        return storedPreamp
    }

    /// The selected preset's id, or `customPresetId` after a band is edited by hand.
    var presetId: String {
        lock.lock()
        defer { lock.unlock() }
        return storedPresetId
    }

    static let flatPresetId = "builtin:flat"
    static let customPresetId = "custom"

    // MARK: - Editing

    /// Enables or disables the equalizer.
    func setEnabled(_ enabled: Bool) {
        lock.lock()
        storedEnabled = enabled
        rebuildLocked()
        lock.unlock()
        PrefsStore.shared.set(enabled, for: .equalizerEnabled)
        notify()
    }

    /// Replaces every band at once, as a preset does.
    func setBands(_ bands: [EqBand], presetId: String? = nil) {
        lock.lock()
        storedBands = AudioEngine.normalised(bands)
        if let presetId = presetId {
            storedPresetId = presetId
        } else {
            storedPresetId = AudioEngine.customPresetId
        }
        rebuildLocked()
        lock.unlock()
        persist()
        notify()
    }

    /// Changes one band.
    func setBand(at index: Int, band: EqBand) {
        lock.lock()
        guard index >= 0, index < storedBands.count else {
            lock.unlock()
            return
        }
        storedBands[index] = band.sanitised
        storedPresetId = AudioEngine.customPresetId
        rebuildLocked()
        lock.unlock()
        persist()
        notify()
    }

    /// Changes one band's gain, which is what a slider in the equalizer screen does.
    func setGain(_ gain: Double, at index: Int) {
        lock.lock()
        guard index >= 0, index < storedBands.count else {
            lock.unlock()
            return
        }
        storedBands[index].gain = min(max(gain, -AudioEngine.maximumGain), AudioEngine.maximumGain)
        storedPresetId = AudioEngine.customPresetId
        rebuildLocked()
        lock.unlock()
        persist()
        notify()
    }

    /// Sets the preamp.
    func setPreamp(_ preamp: Double) {
        lock.lock()
        storedPreamp = min(max(preamp, -AudioEngine.maximumPreamp), AudioEngine.maximumPreamp)
        storedPresetId = AudioEngine.customPresetId
        rebuildLocked()
        lock.unlock()
        persist()
        notify()
    }

    /// Applies a preset.
    func apply(_ preset: EqPreset) {
        lock.lock()
        var bands = storedBands
        for index in bands.indices {
            let gain = preset.gains.element(at: index) ?? 0.0
            bands[index].gain = min(max(gain, -AudioEngine.maximumGain), AudioEngine.maximumGain)
        }
        storedBands = bands
        storedPreamp = min(max(preset.preamp, -AudioEngine.maximumPreamp), AudioEngine.maximumPreamp)
        storedPresetId = preset.id
        rebuildLocked()
        lock.unlock()
        persist()
        notify()
    }

    /// Restores the flat curve.
    func reset() {
        apply(EqPreset(id: AudioEngine.flatPresetId, name: "Flat", gains: [0, 0, 0, 0, 0]))
    }

    // MARK: - Audio mix

    /// Builds the audio mix that applies the equalizer to an item's audio.
    ///
    /// Returns nil when the equalizer is off, which leaves the item's audio untouched and costs
    /// nothing. The mix is built against the item's first audio track; an item with no audio track
    /// gets nil.
    func audioMix(for item: AVPlayerItem) -> AVAudioMix? {
        guard isEnabled else { return nil }
        guard let track = item.asset.tracks(withMediaType: .audio).first else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = makeTap()
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    /// Creates a processing tap that reads this engine's live settings.
    private func makeTap() -> MTAudioProcessingTap? {
        let context = Unmanaged.passRetained(TapContext(engine: self)).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: context,
            init: AudioEngine.tapInit,
            finalize: AudioEngine.tapFinalize,
            prepare: AudioEngine.tapPrepare,
            unprepare: AudioEngine.tapUnprepare,
            process: AudioEngine.tapProcess
        )
        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        guard status == noErr, let created = tap?.takeRetainedValue() else {
            // The context is only consumed by a successful create; releasing it here keeps the
            // retain balanced when the tap cannot be made.
            Unmanaged<TapContext>.fromOpaque(context).release()
            return nil
        }
        return created
    }

    // MARK: - Tap callbacks

    /// The box the tap callbacks see: the engine plus the per-channel filter state for one item.
    private final class TapContext {
        let engine: AudioEngine
        var sampleRate: Double = 44_100
        var channelCount: Int = 2
        var filters: [[BiquadFilter]] = []
        /// The settings revision the current cascade was built from.
        var appliedRevision: Int = -1

        init(engine: AudioEngine) {
            self.engine = engine
        }
    }

    private static let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
        tapStorageOut.pointee = clientInfo
    }

    private static let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
        let storage = MTAudioProcessingTapGetStorage(tap)
        Unmanaged<TapContext>.fromOpaque(storage).release()
    }

    private static let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
        let storage = MTAudioProcessingTapGetStorage(tap)
        let context = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()
        let description = format.pointee
        context.sampleRate = description.mSampleRate > 0 ? description.mSampleRate : 44_100
        context.channelCount = max(Int(description.mChannelsPerFrame), 1)
        context.filters = context.engine.makeFilters(
            sampleRate: context.sampleRate,
            channelCount: context.channelCount
        )
        context.appliedRevision = context.engine.currentRevision
    }

    private static let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
        let storage = MTAudioProcessingTapGetStorage(tap)
        let context = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()
        context.filters = []
    }

    private static let tapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferList, numberFramesOut, _ in
        let storage = MTAudioProcessingTapGetStorage(tap)
        let context = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()

        var flags = MTAudioProcessingTapFlags()
        var timeRange = CMTimeRange()
        let status = MTAudioProcessingTapGetSourceAudio(
            tap,
            numberFrames,
            bufferList,
            &flags,
            &timeRange,
            numberFramesOut
        )
        guard status == noErr else {
            numberFramesOut.pointee = 0
            return
        }

        // The settings can change between buffers; rebuilding here is what makes a slider move
        // audible without rebuilding the player item.
        context.engine.refreshFilters(&context.filters, appliedRevision: &context.appliedRevision)

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let frames = Int(numberFramesOut.pointee)
        guard frames > 0, !context.filters.isEmpty else { return }

        for (channel, buffer) in buffers.enumerated() {
            guard let data = buffer.mData else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard sampleCount > 0 else { continue }
            var filterSet = context.filters.element(at: channel) ?? context.filters[0]
            guard !filterSet.isEmpty else { continue }
            let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
            for index in 0..<sampleCount {
                var value = Double(samples[index])
                for filterIndex in filterSet.indices {
                    value = filterSet[filterIndex].process(value)
                }
                samples[index] = Float(value)
            }
            // The filter state is per channel; writing it back keeps the delay line continuous
            // across buffers.
            if channel < context.filters.count {
                context.filters[channel] = filterSet
            }
        }
    }

    // MARK: - Coefficients

    /// Builds a fresh filter cascade for one item.
    fileprivate func makeFilters(sampleRate: Double, channelCount: Int) -> [[BiquadFilter]] {
        lock.lock()
        let bands = storedBands
        let preamp = storedPreamp
        let enabled = storedEnabled
        lastSampleRate = sampleRate
        lastChannelCount = channelCount
        lock.unlock()
        return AudioEngine.cascade(
            bands: bands,
            preamp: preamp,
            enabled: enabled,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }

    /// Rebuilds a live cascade when the settings changed since the last buffer.
    fileprivate func refreshFilters(_ filters: inout [[BiquadFilter]], appliedRevision: inout Int) {
        lock.lock()
        let bands = storedBands
        let preamp = storedPreamp
        let enabled = storedEnabled
        let revision = coefficientRevision
        let sampleRate = lastSampleRate
        let channelCount = lastChannelCount
        lock.unlock()
        guard revision != appliedRevision else { return }
        appliedRevision = revision
        filters = AudioEngine.cascade(
            bands: bands,
            preamp: preamp,
            enabled: enabled,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }

    /// The settings revision, bumped on every edit so the tap knows when to rebuild.
    fileprivate var currentRevision: Int {
        lock.lock()
        defer { lock.unlock() }
        return coefficientRevision
    }

    private var coefficientRevision: Int = 0
    private var lastSampleRate: Double = 44_100
    private var lastChannelCount: Int = 2

    private static func cascade(
        bands: [EqBand],
        preamp: Double,
        enabled: Bool,
        sampleRate: Double,
        channelCount: Int
    ) -> [[BiquadFilter]] {
        guard enabled else { return [] }
        let active = bands.filter {
            $0.enabled && (abs($0.gain) > 0.01 || $0.type == .lowPass || $0.type == .highPass)
        }
        let preampGain = pow(10.0, preamp / 20.0)
        var result: [[BiquadFilter]] = []
        for _ in 0..<max(channelCount, 1) {
            var filters: [BiquadFilter] = []
            filters.append(BiquadFilter(kind: .gain, frequency: 0, gain: preampGain, q: 1, sampleRate: sampleRate))
            for band in active {
                filters.append(BiquadFilter(
                    kind: BiquadFilter.Kind(band.type),
                    frequency: band.frequency,
                    gain: band.gain,
                    q: band.q,
                    sampleRate: sampleRate
                ))
            }
            result.append(filters)
        }
        return result
    }

    // MARK: - Persistence

    private func rebuildLocked() {
        coefficientRevision += 1
    }

    private func persist() {
        lock.lock()
        let bands = storedBands
        let preamp = storedPreamp
        let preset = storedPresetId
        lock.unlock()
        let encoded = bands.map { band -> String in
            return "\(band.frequency):\(band.gain):\(band.q):\(band.type.rawValue):\(band.enabled ? 1 : 0)"
        }
        PrefsStore.shared.set(encoded, for: .equalizerBands)
        // The preset key carries the preamp after a bar, so one preference holds the whole curve
        // selection without adding a key the settings screen does not know about.
        PrefsStore.shared.set(preset + "|" + String(preamp), for: .equalizerPreset)
    }

    private func restore() {
        let prefs = PrefsStore.shared
        storedEnabled = prefs.bool(for: .equalizerEnabled, fallback: false)
        let storedSelection = prefs.string(for: .equalizerPreset) ?? AudioEngine.flatPresetId
        let selectionParts = storedSelection.components(separatedBy: "|")
        storedPresetId = selectionParts.first ?? AudioEngine.flatPresetId
        storedPreamp = Double(selectionParts.element(at: 1) ?? "") ?? 0.0
        storedPreamp = min(max(storedPreamp, -AudioEngine.maximumPreamp), AudioEngine.maximumPreamp)

        let encoded = prefs.stringArray(for: .equalizerBands)
        if !encoded.isEmpty {
            var restored: [EqBand] = []
            for entry in encoded {
                let parts = entry.components(separatedBy: ":")
                guard parts.count >= 5,
                      let frequency = Double(parts[0]),
                      let gain = Double(parts[1]),
                      let q = Double(parts[2]) else { continue }
                let type = EqFilterType(rawValue: parts[3]) ?? .peak
                restored.append(EqBand(
                    frequency: frequency,
                    gain: gain,
                    q: q,
                    type: type,
                    enabled: parts[4] == "1"
                ))
            }
            if restored.count == AudioEngine.bandFrequencies.count {
                storedBands = restored.map { $0.sanitised }
            } else {
                storedBands = AudioEngine.defaultBands()
            }
        } else {
            storedBands = AudioEngine.defaultBands()
        }

        // A preset that no longer exists in this build falls back to its gains being treated as a
        // custom curve, which is what the screen shows.
        if storedPresetId != AudioEngine.customPresetId,
           AudioEngine.presets.first(where: { $0.id == storedPresetId }) == nil,
           storedPresetId != AudioEngine.flatPresetId {
            storedPresetId = AudioEngine.customPresetId
        }
        rebuildLocked()
    }

    private func notify() {
        if Thread.isMainThread {
            onChange?()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onChange?()
            }
        }
    }

    // MARK: - Defaults and presets

    /// The flat curve the screen starts on.
    static func defaultBands() -> [EqBand] {
        return bandFrequencies.map { EqBand(frequency: $0, gain: 0.0, q: defaultQ, type: .peak) }
    }

    private static func normalised(_ bands: [EqBand]) -> [EqBand] {
        var result: [EqBand] = []
        for index in bandFrequencies.indices {
            if let band = bands.element(at: index) {
                result.append(band.sanitised)
            } else {
                result.append(EqBand(frequency: bandFrequencies[index]))
            }
        }
        return result
    }

    /// The presets the equalizer screen offers, in the order Android lists them.
    static let presets: [EqPreset] = [
        EqPreset(id: flatPresetId, name: "Flat", gains: [0, 0, 0, 0, 0]),
        EqPreset(id: "builtin:acoustic", name: "Acoustic", gains: [3.0, 1.0, 1.5, 2.5, 3.0]),
        EqPreset(id: "builtin:bass_boost", name: "Bass boost", gains: [8.0, 4.0, 0.5, 0.0, 0.0]),
        EqPreset(id: "builtin:classical", name: "Classical", gains: [3.0, 1.0, 0.0, 2.0, 3.0]),
        EqPreset(id: "builtin:electronic", name: "Electronic", gains: [6.0, 2.0, 0.0, 2.0, 4.5], preamp: -1.0),
        EqPreset(id: "builtin:heavy_metal", name: "Heavy metal", gains: [5.0, 2.0, -1.0, 3.0, 4.0], preamp: -1.0),
        EqPreset(id: "builtin:hip_hop", name: "Hip-hop", gains: [7.0, 3.0, -1.0, 2.0, 2.0], preamp: -1.0),
        EqPreset(id: "builtin:jazz", name: "Jazz", gains: [2.5, 1.0, 0.5, 1.5, 2.5]),
        EqPreset(id: "builtin:metal", name: "Metal", gains: [4.0, 2.5, 1.0, 3.0, 2.0]),
        EqPreset(id: "builtin:pop", name: "Pop", gains: [2.0, 1.0, 1.0, 2.0, 3.0]),
        EqPreset(id: "builtin:rnb", name: "R&B", gains: [5.0, 2.0, -1.0, 1.5, 2.0]),
        EqPreset(id: "builtin:rock", name: "Rock", gains: [4.5, 2.5, -1.0, 2.5, 4.0]),
        EqPreset(id: "builtin:vocal", name: "Vocal and podcast", gains: [-1.0, 1.0, 3.0, 2.0, 0.0]),
    ]

    /// The preset matching the current bands, or nil for a hand-edited curve.
    var matchingPreset: EqPreset? {
        let current = bands
        return AudioEngine.presets.first { preset in
            for index in current.indices {
                let target = preset.gains.element(at: index) ?? 0.0
                if abs(current[index].gain - target) > 0.05 { return false }
            }
            return true
        }
    }
}

/// One biquad section, or a plain gain.
///
/// The coefficients are the RBJ audio-EQ cookbook's, which is what `AVAudioUnitEQ` implements
/// internally. Keeping the formulas here means the tap's output matches what the same settings
/// would sound like through an `AVAudioUnitEQ` node.
struct BiquadFilter {

    enum Kind {
        case gain
        case peak
        case lowShelf
        case highShelf
        case lowPass
        case highPass

        /// Maps a band's stored filter type onto the kind the coefficients are built for.
        init(_ type: EqFilterType) {
            switch type {
            case .peak: self = .peak
            case .lowShelf: self = .lowShelf
            case .highShelf: self = .highShelf
            case .lowPass: self = .lowPass
            case .highPass: self = .highPass
            }
        }
    }

    private let b0: Double
    private let b1: Double
    private let b2: Double
    private let a1: Double
    private let a2: Double

    /// Per-channel delay line.
    private var x1: Double = 0
    private var x2: Double = 0
    private var y1: Double = 0
    private var y2: Double = 0

    init(kind: Kind, frequency: Double, gain: Double, q: Double, sampleRate: Double) {
        switch kind {
        case .gain:
            b0 = gain
            b1 = 0
            b2 = 0
            a1 = 0
            a2 = 0
        case .peak, .lowShelf, .highShelf, .lowPass, .highPass:
            let coefficients = BiquadFilter.coefficients(
                kind: kind,
                frequency: frequency,
                gain: gain,
                q: q,
                sampleRate: sampleRate
            )
            b0 = coefficients.b0
            b1 = coefficients.b1
            b2 = coefficients.b2
            a1 = coefficients.a1
            a2 = coefficients.a2
        }
    }

    /// Runs a sample through the section.
    mutating func process(_ input: Double) -> Double {
        let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return output
    }

    private static func coefficients(
        kind: Kind,
        frequency: Double,
        gain: Double,
        q: Double,
        sampleRate: Double
    ) -> (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        let nyquist = sampleRate / 2.0
        let clampedFrequency = min(max(frequency, 10.0), nyquist * 0.95)
        let w0 = 2.0 * Double.pi * clampedFrequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let safeQ = max(q, 0.05)
        let alpha = sinW0 / (2.0 * safeQ)
        let a = pow(10.0, gain / 40.0)

        var b0 = 1.0
        var b1 = 0.0
        var b2 = 0.0
        var a0 = 1.0
        var a1 = 0.0
        var a2 = 0.0

        switch kind {
        case .gain:
            return (gain, 0, 0, 0, 0)
        case .peak:
            b0 = 1.0 + alpha * a
            b1 = -2.0 * cosW0
            b2 = 1.0 - alpha * a
            a0 = 1.0 + alpha / a
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha / a
        case .lowShelf:
            let sqrtA = sqrt(a)
            b0 = a * ((a + 1.0) - (a - 1.0) * cosW0 + 2.0 * sqrtA * alpha)
            b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cosW0)
            b2 = a * ((a + 1.0) - (a - 1.0) * cosW0 - 2.0 * sqrtA * alpha)
            a0 = (a + 1.0) + (a - 1.0) * cosW0 + 2.0 * sqrtA * alpha
            a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cosW0)
            a2 = (a + 1.0) + (a - 1.0) * cosW0 - 2.0 * sqrtA * alpha
        case .highShelf:
            let sqrtA = sqrt(a)
            b0 = a * ((a + 1.0) + (a - 1.0) * cosW0 + 2.0 * sqrtA * alpha)
            b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cosW0)
            b2 = a * ((a + 1.0) + (a - 1.0) * cosW0 - 2.0 * sqrtA * alpha)
            a0 = (a + 1.0) - (a - 1.0) * cosW0 + 2.0 * sqrtA * alpha
            a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cosW0)
            a2 = (a + 1.0) - (a - 1.0) * cosW0 - 2.0 * sqrtA * alpha
        case .lowPass:
            b0 = (1.0 - cosW0) / 2.0
            b1 = 1.0 - cosW0
            b2 = (1.0 - cosW0) / 2.0
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha
        case .highPass:
            b0 = (1.0 + cosW0) / 2.0
            b1 = -(1.0 + cosW0)
            b2 = (1.0 + cosW0) / 2.0
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha
        }

        guard a0 != 0 else { return (1, 0, 0, 0, 0) }
        return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }
}
