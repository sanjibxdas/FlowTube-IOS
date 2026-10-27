import Foundation

/// The player's sleep timer.
///
/// Android's version is a `Handler`-based countdown with two modes: a fixed number of minutes, or
/// "end of the current item". Both are kept here, with a `DispatchSourceTimer` doing the counting so
/// the timer survives a run loop change and does not drift.
///
/// The timer never pauses anything itself. It reports expiry through `onExpire` and lets
/// `PlaybackService` decide whether to pause, stop or shut down, which keeps the timer testable and
/// keeps the app's exit policy in one place.
final class SleepTimer {

    /// Why the timer fired, so the caller can show the right message.
    enum Expiry {
        /// The chosen number of minutes elapsed.
        case minutes
        /// The current track or video ended.
        case endOfMedia
    }

    /// How long the timer runs.
    enum Mode: Equatable {
        case minutes(Int)
        case endOfMedia
    }

    static let shared = SleepTimer()

    /// The minute choices the sheet offers, matching the Android app.
    static let minuteChoices: [Int] = [5, 10, 15, 20, 30, 45, 60, 90, 120]

    /// The mode in effect, or nil when the timer is off.
    private(set) var mode: Mode?

    /// When the timer will fire, for a minute-based timer.
    private(set) var fireDate: Date?

    /// Whether the app should close when the timer fires rather than just pausing.
    var closesAppOnExpiry = false

    /// Called on the main queue when the timer fires. The timer has already been cancelled.
    var onExpire: ((Expiry) -> Void)?

    /// Called on the main queue whenever the remaining time changes by a second, for a countdown
    /// label. The argument is the remaining seconds, or nil when the timer is off.
    var onTick: ((TimeInterval?) -> Void)?

    private var source: DispatchSourceTimer?
    private let lock = NSLock()

    private init() {}

    // MARK: - State

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mode != nil
    }

    /// The seconds left, or nil when the timer is off or waiting for the end of the item.
    var remaining: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let fireDate = fireDate else { return nil }
        return max(fireDate.timeIntervalSinceNow, 0.0)
    }

    /// A short description for the player's timer button and the sheet's status line:
    /// "Stops in 12:34", "End of current song", or nil when off.
    var statusText: String? {
        lock.lock()
        let activeMode = mode
        let date = fireDate
        lock.unlock()
        guard let activeMode = activeMode else { return nil }
        switch activeMode {
        case .endOfMedia:
            return "End of current item"
        case .minutes:
            guard let date = date else { return "Sleep timer active" }
            let seconds = max(date.timeIntervalSinceNow, 0.0)
            return "Stops in " + Formatters.playbackTime(seconds)
        }
    }

    // MARK: - Starting

    /// Starts a minute-based timer. Starting again replaces the old one.
    func start(minutes: Int, closesApp: Bool = false) {
        let clamped = min(max(minutes, 1), 24 * 60)
        cancel(notify: false)
        lock.lock()
        mode = .minutes(clamped)
        fireDate = Date().addingTimeInterval(TimeInterval(clamped * 60))
        closesAppOnExpiry = closesApp
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + TimeInterval(clamped * 60), repeating: .never)
        timer.setEventHandler { [weak self] in
            self?.fire(.minutes)
        }
        timer.resume()
        lock.lock()
        source = timer
        lock.unlock()

        startTicking()
        onTick?(TimeInterval(clamped * 60))
    }

    /// Arms the timer to fire when the current item ends.
    func startEndOfMedia(closesApp: Bool = false) {
        cancel(notify: false)
        lock.lock()
        mode = .endOfMedia
        fireDate = nil
        closesAppOnExpiry = closesApp
        lock.unlock()
        onTick?(nil)
    }

    /// Called by the player when the current item reaches its end.
    func mediaDidEnd() {
        lock.lock()
        let isWaiting = mode == .endOfMedia
        lock.unlock()
        guard isWaiting else { return }
        fire(.endOfMedia)
    }

    /// Cancels the timer without firing it.
    func cancel() {
        cancel(notify: true)
    }

    private func cancel(notify: Bool) {
        lock.lock()
        let timer = source
        source = nil
        let wasActive = mode != nil
        mode = nil
        fireDate = nil
        lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
        if notify && wasActive {
            onTick?(nil)
        }
    }

    // MARK: - Firing

    private func fire(_ expiry: Expiry) {
        lock.lock()
        guard mode != nil else {
            lock.unlock()
            return
        }
        let timer = source
        source = nil
        mode = nil
        fireDate = nil
        lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
        onTick?(nil)
        onExpire?(expiry)
    }

    // MARK: - Ticking

    /// A one-second heartbeat so a countdown label stays current. It stops itself once the timer
    /// is cancelled, so no work happens while the timer is off.
    private func startTicking() {
        let ticker = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        ticker.schedule(deadline: .now() + 1.0, repeating: 1.0)
        ticker.setEventHandler { [weak self, weak ticker] in
            guard let self = self else {
                ticker?.cancel()
                return
            }
            self.lock.lock()
            let active = self.mode != nil
            let date = self.fireDate
            self.lock.unlock()
            guard active, let date = date else {
                ticker?.cancel()
                return
            }
            self.onTick?(max(date.timeIntervalSinceNow, 0.0))
        }
        ticker.resume()
    }
}
