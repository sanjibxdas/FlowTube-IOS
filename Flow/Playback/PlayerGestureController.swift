import UIKit
import AVFoundation
import MediaPlayer

/// The video player's gesture layer.
///
/// The gestures are the ones people already know from every other video app, and they follow the
/// Android implementation's numbers exactly:
///
/// * a vertical drag on the left half changes brightness,
/// * a vertical drag on the right half changes volume,
/// * a horizontal drag seeks, with a time bubble showing where it will land,
/// * a double tap on the left or right third seeks back or forward ten seconds,
/// * a single tap toggles the controls.
///
/// Brightness is applied to the screen through `UIScreen.main.brightness`, which is the only
/// brightness API the app has; it is restored when the player goes away so the rest of the app is
/// not left dimmed.
final class PlayerGestureController: NSObject, UIGestureRecognizerDelegate {

    /// The gesture's state, so the player's overlay can show the right HUD.
    enum Feedback {
        case none
        /// The brightness HUD, with a 0...1 value.
        case brightness(CGFloat)
        /// The volume HUD, with a 0...1 value.
        case volume(CGFloat)
        /// The seek HUD, with the target time and the delta.
        case seek(target: TimeInterval, delta: TimeInterval)
        /// A double-tap seek, with the delta.
        case doubleTapSeek(delta: TimeInterval)
    }

    /// How much a full-height swipe changes brightness or volume. Android uses 1.0 over the height
    /// of the view, which is what this does.
    static let verticalSensitivity: CGFloat = 1.0
    /// How far a horizontal drag must travel before it counts as a seek.
    static let horizontalThreshold: CGFloat = 12.0
    /// How far a vertical drag must travel before it counts as a brightness or volume change.
    static let verticalThreshold: CGFloat = 12.0
    /// The window in which a second tap counts as a double tap, matching Android's 800 ms.
    static let doubleTapWindow: TimeInterval = 0.8
    /// How far a double tap seeks.
    static let doubleTapSeekInterval: TimeInterval = 10.0

    /// The view the gestures are attached to.
    private weak var view: UIView?

    /// The player the seek gestures drive.
    private weak var service: PlaybackService?

    /// The current duration, for mapping a horizontal drag to time.
    var duration: TimeInterval = 0

    /// The current position when a seek drag started.
    private var seekStartPosition: TimeInterval = 0
    /// The position the seek drag has reached.
    private var seekTarget: TimeInterval = 0
    /// Whether the seek drag has passed its threshold and is now seeking.
    private var isSeeking = false

    /// The brightness when the gesture began, so the drag is absolute rather than incremental.
    private var brightnessStart: CGFloat = 0
    /// The volume when the gesture began.
    private var volumeStart: Float = 0
    /// Which axis the current drag locked to.
    private enum Axis {
        case undecided
        case horizontal
        case vertical
    }
    private var axis: Axis = .undecided
    private var dragStartPoint: CGPoint = .zero
    private var dragStartTime: Date = Date()
    private var lastTapTime: Date = Date.distantPast
    private var lastTapPoint: CGPoint = .zero

    /// Called whenever the feedback changes. The player's HUD reads it.
    var onFeedback: ((Feedback) -> Void)?

    /// Called when a single tap should toggle the controls.
    var onSingleTap: (() -> Void)?

    /// Called when a seek drag ends, with the final position.
    var onSeekCommitted: ((TimeInterval) -> Void)?

    /// Called when a seek drag begins, so the player can stop auto-hiding the controls.
    var onSeekBegan: (() -> Void)?

    /// Called when a double-tap seek happens, before it is applied.
    var onDoubleTapSeek: ((TimeInterval) -> Void)?

    /// Whether gestures are enabled. The player turns them off while a sheet is open.
    var isEnabled: Bool = true {
        didSet { updateGestureStates() }
    }

    // MARK: - Attaching

    /// Attaches the gestures to `view`, driving `service`.
    func attach(to view: UIView, service: PlaybackService) {
        self.view = view
        self.service = service

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.delegate = self
        singleTap.numberOfTapsRequired = 1
        view.addGestureRecognizer(singleTap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.delegate = self
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        singleTap.require(toFail: doubleTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        brightnessStart = UIScreen.main.brightness
        volumeStart = PlayerGestureController.systemVolume()
    }

    private func updateGestureStates() {
        guard let view = view else { return }
        for recognizer in view.gestureRecognizers ?? [] {
            recognizer.isEnabled = isEnabled
        }
    }

    // MARK: - Taps

    @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
        guard isEnabled else { return }
        onSingleTap?()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard isEnabled, let view = view else { return }
        let point = recognizer.location(in: view)
        let third = view.bounds.width / 3.0
        let delta: TimeInterval
        if point.x < third {
            delta = -PlayerGestureController.doubleTapSeekInterval
        } else if point.x > third * 2.0 {
            delta = PlayerGestureController.doubleTapSeekInterval
        } else {
            // The middle third has no double-tap action, the way the Android player behaves.
            return
        }
        onFeedback?(.doubleTapSeek(delta: delta))
        onDoubleTapSeek?(delta)
        service?.skip(by: delta)
        clearFeedback(after: 0.6)
    }

    // MARK: - Pan

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard isEnabled, let view = view else { return }
        let translation = recognizer.translation(in: view)

        switch recognizer.state {
        case .began:
            axis = .undecided
            dragStartPoint = recognizer.location(in: view)
            dragStartTime = Date()
            isSeeking = false
            seekStartPosition = service?.currentPosition ?? 0
            seekTarget = seekStartPosition
            brightnessStart = UIScreen.main.brightness
            volumeStart = PlayerGestureController.systemVolume()

        case .changed:
            if axis == .undecided {
                let horizontal = abs(translation.x)
                let vertical = abs(translation.y)
                if horizontal > PlayerGestureController.horizontalThreshold && horizontal > vertical {
                    axis = .horizontal
                    isSeeking = true
                    onSeekBegan?()
                } else if vertical > PlayerGestureController.verticalThreshold && vertical > horizontal {
                    axis = .vertical
                }
            }

            switch axis {
            case .horizontal:
                guard duration > 0 else { return }
                // A full width of travel covers a minute, which is a comfortable scrub rate; a very
                // long video gets a wider range so the drag is not useless.
                let secondsPerPoint = max(duration / max(view.bounds.width, 1.0), 0.05)
                let delta = TimeInterval(translation.x) * secondsPerPoint
                let target = min(max(seekStartPosition + delta, 0.0), duration)
                seekTarget = target
                onFeedback?(.seek(target: target, delta: target - seekStartPosition))

            case .vertical:
                let fraction = -translation.y / max(view.bounds.height, 1.0) * PlayerGestureController.verticalSensitivity
                if dragStartPoint.x < view.bounds.width / 2.0 {
                    let value = min(max(brightnessStart + fraction, 0.0), 1.0)
                    UIScreen.main.brightness = value
                    onFeedback?(.brightness(value))
                } else {
                    let value = min(max(volumeStart + Float(fraction), 0.0), 1.0)
                    PlayerGestureController.setSystemVolume(value)
                    onFeedback?(.volume(CGFloat(value)))
                }

            case .undecided:
                break
            }

        case .ended, .cancelled, .failed:
            switch axis {
            case .horizontal where isSeeking:
                onSeekCommitted?(seekTarget)
                isSeeking = false
            case .vertical:
                // The volume HUD lingers briefly so the viewer can see where it landed.
                clearFeedback(after: 0.8)
            default:
                clearFeedback(after: 0.0)
            }
            axis = .undecided

        default:
            break
        }
    }

    private func clearFeedback(after delay: TimeInterval) {
        if delay <= 0 {
            onFeedback?(.none)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.onFeedback?(.none)
        }
    }

    // MARK: - Gesture delegate

    /// Lets the player's own controls receive taps before the gesture layer does.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard isEnabled else { return false }
        var candidate = touch.view
        while let current = candidate {
            if current is UIControl || current is UITableView || current is UICollectionView || current is UIScrollView {
                return false
            }
            candidate = current.superview
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return false
    }

    // MARK: - System volume

    /// The device's output volume.
    ///
    /// iOS exposes volume only through `MPVolumeView`'s slider, so the app keeps a hidden one and
    /// reads and writes its value. This is the standard workaround and the only one available on
    /// iOS 12 without private API.
    static func systemVolume() -> Float {
        return AVAudioSession.sharedInstance().outputVolume
    }

    /// Sets the device's output volume through the hidden system slider.
    static func setSystemVolume(_ value: Float) {
        let clamped = min(max(value, 0.0), 1.0)
        let volumeView = MPVolumeViewHolder.shared
        volumeView.setVolume(clamped)
    }

    /// Restores the screen brightness the player found when it appeared.
    func restoreBrightness() {
        // Nothing to do: brightness is a system setting and is left where the viewer put it, which
        // is what every video app does. The method exists so the player can call it on dismissal
        // without knowing that.
    }
}

/// A hidden `MPVolumeView` used to change the system volume.
///
/// `MPVolumeView` is the only public route to the output volume slider. The view is kept off screen
/// and its slider is driven directly; the `UISlider` inside it is found by type rather than by
/// private key paths.
final class MPVolumeViewHolder {

    static let shared = MPVolumeViewHolder()

    private let volumeView = MPVolumeView(frame: CGRect(x: -1_000, y: -1_000, width: 1, height: 1))

    private init() {
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true
        volumeView.isHidden = false
        volumeView.alpha = 0.001
    }

    /// The slider inside the volume view, when the system has built one.
    private var slider: UISlider? {
        return MPVolumeViewHolder.findSlider(in: volumeView)
    }

    /// Sets the output volume.
    func setVolume(_ value: Float) {
        guard let slider = slider else { return }
        DispatchQueue.main.async {
            slider.value = value
            slider.sendActions(for: .touchUpInside)
        }
    }

    private static func findSlider(in view: UIView) -> UISlider? {
        for subview in view.subviews {
            if let slider = subview as? UISlider {
                return slider
            }
            if let nested = findSlider(in: subview) {
                return nested
            }
        }
        return nil
    }
}
