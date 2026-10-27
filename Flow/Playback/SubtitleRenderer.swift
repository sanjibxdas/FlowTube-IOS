import UIKit

/// How subtitles are drawn, read from the user's preferences.
struct SubtitleStyle {

    /// A multiplier on the base caption size.
    var fontScale: CGFloat
    /// The caption text colour.
    var textColor: UIColor
    /// The opacity of the box drawn behind the text, 0...1.
    var backgroundOpacity: CGFloat

    /// The app's defaults, matching the subtitle settings screen.
    static var current: SubtitleStyle {
        let prefs = PrefsStore.shared
        let storedScale = prefs.double(for: .subtitleFontScale, fallback: 1.0)
        let storedOpacity = prefs.double(for: .subtitleBackgroundOpacity, fallback: 0.6)
        let storedColor = prefs.string(for: .subtitleTextColor) ?? "#FFFFFF"
        return SubtitleStyle(
            fontScale: CGFloat(min(max(storedScale, 0.6), 2.4)),
            textColor: UIColor(hexString: storedColor) ?? UIColor.white,
            backgroundOpacity: CGFloat(min(max(storedOpacity, 0.0), 1.0))
        )
    }

    /// The base caption point size before the user's scale is applied.
    static let baseFontSize: CGFloat = 17.0

    /// The scaled caption font.
    var font: UIFont {
        let size = SubtitleStyle.baseFontSize * fontScale
        return UIFont.systemFont(ofSize: size, weight: .semibold)
    }
}

/// A loaded subtitle track, ready to display.
final class SubtitleTrack {

    let languageCode: String
    let name: String
    let isAutomatic: Bool
    let file: SubtitleTrackFile
    let url: String

    init(languageCode: String, name: String, isAutomatic: Bool, file: SubtitleTrackFile, url: String) {
        self.languageCode = languageCode
        self.name = name
        self.isAutomatic = isAutomatic
        self.file = file
        self.url = url
    }

    /// The cue at a playback time, after the automatic-caption cleanup.
    func cue(at time: TimeInterval) -> SubtitleCue? {
        return file.cue(at: time)
    }
}

/// Loads caption tracks from YouTube.
///
/// A caption track is a plain URL that returns WebVTT (or XML, for the older `srv` format), so the
/// loader fetches the text through the same client as everything else and hands it to
/// `SubtitleParser`. Answers are cached by URL for the session, since a viewer who turns captions
/// off and on again should not pay for the same download twice.
final class SubtitleLoader {

    static let shared = SubtitleLoader()

    private let client: InnerTubeClient
    private let lock = NSLock()
    private var cache: [String: SubtitleTrackFile] = [:]
    private var inFlight: [String: [(Result<SubtitleTrackFile, FlowError>) -> Void]] = [:]

    init(client: InnerTubeClient = InnerTubeClient()) {
        self.client = client
    }

    /// Fetches and parses a track.
    func load(
        track: CaptionTrack,
        completion: @escaping (Result<SubtitleTrackFile, FlowError>) -> Void
    ) {
        guard let url = SubtitleLoader.captionURL(from: track.baseUrl) else {
            completion(.failure(.malformedResponse(detail: "Unusable caption URL")))
            return
        }
        lock.lock()
        if let cached = cache[url] {
            lock.unlock()
            completion(.success(cached))
            return
        }
        if var waiting = inFlight[url] {
            waiting.append(completion)
            inFlight[url] = waiting
            lock.unlock()
            return
        }
        inFlight[url] = [completion]
        lock.unlock()

        client.getText(urlString: url, headers: ["Accept": "text/vtt,text/plain,*/*"]) { [weak self] result in
            guard let self = self else { return }
            var parsed: Result<SubtitleTrackFile, FlowError>
            switch result {
            case .failure(let error):
                parsed = .failure(error)
            case .success(let text):
                if let file = SubtitleParser.parse(text) {
                    parsed = .success(file)
                } else {
                    parsed = .failure(.malformedResponse(detail: "The caption track had no readable cues."))
                }
            }
            self.lock.lock()
            let waiting = self.inFlight.removeValue(forKey: url) ?? []
            if case .success(let file) = parsed {
                self.cache[url] = file
            }
            self.lock.unlock()
            for callback in waiting {
                callback(parsed)
            }
        }
    }

    /// A track already fetched in this session.
    func cached(track: CaptionTrack) -> SubtitleTrackFile? {
        guard let url = SubtitleLoader.captionURL(from: track.baseUrl) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return cache[url]
    }

    /// Forgets every cached track.
    func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// YouTube's caption URLs are sometimes protocol-relative and often carry a `fmt` parameter that
    /// asks for the old XML format. Asking for `vtt` explicitly is what makes them parseable here.
    static func captionURL(from baseUrl: String) -> String? {
        guard !baseUrl.isEmpty else { return nil }
        var text = baseUrl
        if text.hasPrefix("//") {
            text = "https:" + text
        }
        guard var components = URLComponents(string: text) else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "fmt" }
        items.append(URLQueryItem(name: "fmt", value: "vtt"))
        components.queryItems = items
        return components.url?.absoluteString
    }
}

/// The subtitle overlay drawn over the video.
///
/// The player feeds it the current playback time on every tick; the renderer looks up the cue and
/// only rebuilds its labels when the cue actually changes, so a 60 Hz tick does not cause 60 text
/// layouts a second. Text is drawn on a translucent box that follows the user's colour and opacity
/// settings, and the whole overlay fades rather than popping when captions appear and disappear.
final class SubtitleRenderer: UIView {

    /// The track being shown, or nil when captions are off.
    private(set) var track: SubtitleTrack?

    /// A user-set delay in seconds. Positive delays the captions, which is what "captions are
    /// ahead of the audio" needs.
    var delay: TimeInterval = 0.0

    /// The style captions are drawn in.
    var style: SubtitleStyle = .current {
        didSet { applyStyle() }
    }

    /// The cue currently on screen, if any.
    private(set) var visibleCue: SubtitleCue?

    private let box = UIView()
    private let stack = UIStackView()
    private var labels: [UILabel] = []
    private var currentText: String = ""

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
        isUserInteractionEnabled = false
        backgroundColor = .clear

        box.translatesAutoresizingMaskIntoConstraints = false
        box.layer.cornerRadius = FlowShapes.small
        box.layer.masksToBounds = true
        box.alpha = 0.0
        addSubview(box)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2.0
        box.addSubview(stack)

        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: FlowSpacing.xl),
            box.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -FlowSpacing.xl),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.xxl),
            box.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.92),

            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: FlowSpacing.md),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -FlowSpacing.md),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: FlowSpacing.xs),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -FlowSpacing.xs),
        ])
        applyStyle()
    }

    // MARK: - Content

    /// Shows `track`, replacing whatever was on screen. Passing nil turns captions off.
    func setTrack(_ track: SubtitleTrack?) {
        self.track = track
        visibleCue = nil
        showText("", animated: false)
    }

    /// Updates the overlay for a playback position. Cheap when the cue has not changed.
    func update(time: TimeInterval) {
        guard let track = track else { return }
        let adjusted = max(time - delay, 0.0)
        guard let cue = track.cue(at: adjusted) else {
            if visibleCue != nil {
                visibleCue = nil
                showText("", animated: true)
            }
            return
        }
        if let current = visibleCue, current == cue { return }
        visibleCue = cue
        showText(cue.text, animated: true)
    }

    /// Shows static text in the current style, for the subtitle settings preview. The player never
    /// calls this: it exists so the settings screen can show the real renderer rather than a copy
    /// of it that could drift.
    func showPreviewText(_ text: String) {
        visibleCue = nil
        showText(text, animated: false)
    }

    /// Removes the caption from screen without forgetting the track.
    func clearVisibleCue() {
        visibleCue = nil
        showText("", animated: false)
    }

    private func showText(_ text: String, animated: Bool) {
        guard text != currentText else { return }
        currentText = text
        rebuildLabels(for: text)
        let target: CGFloat = text.isEmpty ? 0.0 : 1.0
        if animated {
            FlowMotion.animate {
                self.box.alpha = target
            }
        } else {
            box.alpha = target
        }
    }

    private func rebuildLabels(for text: String) {
        for label in labels {
            stack.removeArrangedSubview(label)
            label.removeFromSuperview()
        }
        labels = []
        guard !text.isEmpty else { return }
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = style.font
            label.textColor = style.textColor
            label.textAlignment = .center
            label.numberOfLines = 0
            label.text = line
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.55
            label.layer.shadowRadius = 2.0
            label.layer.shadowOffset = CGSize(width: 0, height: 1)
            labels.append(label)
            stack.addArrangedSubview(label)
        }
    }

    // MARK: - Style

    /// Repaints the overlay in the current palette and the user's caption style.
    func applyStyle() {
        style = SubtitleStyle(
            fontScale: style.fontScale,
            textColor: style.textColor,
            backgroundOpacity: style.backgroundOpacity
        )
        box.backgroundColor = UIColor.black.withAlphaComponent(style.backgroundOpacity)
        for label in labels {
            label.font = style.font
            label.textColor = style.textColor
        }
    }

    /// Re-reads the caption style from preferences.
    func reloadStyleFromPreferences() {
        style = SubtitleStyle.current
    }
}
