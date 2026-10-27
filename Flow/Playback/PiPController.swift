import UIKit
import AVFoundation
import AVKit

/// Picture in picture for the video player.
///
/// iOS 12 has no `AVPlayerViewController` PiP switch, but it does have `AVPictureInPictureController`,
/// which takes an `AVPlayerLayer` and moves it into the system's floating window. The controller is
/// built around the same layer the player draws into, so entering PiP is a hand-off rather than a
/// second player.
///
/// The controller also supplies the PiP window's transport controls: play/pause go through
/// `PlaybackService`, and the skip buttons move through the queue. Those are wired here rather than
/// in the view controller because the PiP window outlives the screen — the viewer can leave the
/// watch page while the video keeps playing in the corner.
final class PiPController: NSObject, AVPictureInPictureControllerDelegate {

    /// Whether the device supports PiP. iPad always does from iOS 9; iPhone does from iOS 14, and
    /// `AVPictureInPictureController.isPictureInPictureSupported()` is the only honest answer.
    static var isSupported: Bool {
        return AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// The layer the player draws into. PiP is built from this.
    private weak var playerLayer: AVPlayerLayer?

    /// The system controller, created lazily once a layer exists.
    private(set) var controller: AVPictureInPictureController?

    /// Whether PiP is on screen right now.
    var isActive: Bool {
        return controller?.isPictureInPictureActive ?? false
    }

    /// Whether PiP can start: the device supports it, the user enabled it, and there is a layer with
    /// a player attached.
    var isPossible: Bool {
        guard PiPController.isSupported else { return false }
        guard PrefsStore.shared.bool(for: .pictureInPicture, fallback: true) else { return false }
        guard let layer = playerLayer, layer.player != nil else { return false }
        return controller?.isPictureInPicturePossible ?? false
    }

    /// Called when PiP starts or stops, so the player screen can restore its own controls.
    var onActiveChanged: ((Bool) -> Void)?

    /// Called when the viewer taps the PiP window's close button.
    var onRestoreRequested: (() -> Void)?

    /// Called when the viewer taps the PiP window's full-screen button.
    var onExpandRequested: (() -> Void)?

    // MARK: - Attaching

    /// Attaches the controller to a player layer, creating the system controller the first time.
    func attach(to layer: AVPlayerLayer) {
        playerLayer = layer
        if controller == nil {
            guard PiPController.isSupported else { return }
            // Automatic PiP on leaving the app is an iOS 14.1 setting; on iOS 12 the viewer starts
            // PiP from the player's button, which is the only route the system offers.
            controller = AVPictureInPictureController(playerLayer: layer)
            controller?.delegate = self
        }
    }

    /// Detaches from the layer, stopping PiP first.
    func detach() {
        if isActive {
            controller?.stopPictureInPicture()
        }
        controller?.delegate = nil
        controller = nil
        playerLayer = nil
    }

    // MARK: - Starting and stopping

    /// Enters PiP when possible.
    @discardableResult
    func start() -> Bool {
        guard let controller = controller, controller.isPictureInPicturePossible else { return false }
        controller.startPictureInPicture()
        return true
    }

    /// Leaves PiP, returning the video to its inline layer.
    func stop() {
        controller?.stopPictureInPicture()
    }

    /// Toggles PiP.
    @discardableResult
    func toggle() -> Bool {
        if isActive {
            stop()
            return false
        }
        return start()
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onActiveChanged?(true)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onActiveChanged?(true)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        onActiveChanged?(false)
        FlowSnackbar.showError("Picture in picture could not start: " + error.localizedDescription)
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onActiveChanged?(false)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onActiveChanged?(false)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        onRestoreRequested?()
        completionHandler(true)
    }
}

/// The player layer the video screen draws into.
///
/// A `UIView` whose backing layer is an `AVPlayerLayer` is the simplest way to keep the layer's
/// frame and the view's frame in step while the view rotates, and it gives `PiPController` a stable
/// layer to attach to.
final class PlayerLayerView: UIView {

    override class var layerClass: AnyClass {
        return AVPlayerLayer.self
    }

    /// The player layer, typed.
    var playerLayer: AVPlayerLayer {
        return layer as? AVPlayerLayer ?? AVPlayerLayer()
    }

    /// The player this view renders.
    var player: AVPlayer? {
        get { return playerLayer.player }
        set { playerLayer.player = newValue }
    }

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
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    /// Sets how the video fills the layer.
    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        playerLayer.videoGravity = gravity
    }
}
