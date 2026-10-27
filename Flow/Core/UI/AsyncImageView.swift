import UIKit

/// A `UIImageView` that loads its image from a URL through `ImageLoader` and cancels cleanly when
/// reused by a scrolling cell.
///
/// The view keeps the URL it is currently showing, so a recycled cell that is configured twice
/// before the first download finishes does not end up with the wrong picture.
final class AsyncImageView: UIImageView {

    /// The URL whose image is requested or shown.
    private(set) var imageURL: String?

    /// A tint drawn behind the image while it loads. Set from the palette by the owner.
    var placeholderColor: UIColor? {
        didSet { updatePlaceholder() }
    }

    /// When true the image is faded in once it arrives. Off for cells that are reconfigured often.
    var fadesIn: Bool = true

    private let placeholderView = UIView()
    private var targetSize: CGSize?

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
        clipsToBounds = true
        contentMode = .scaleAspectFill
        backgroundColor = .clear
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.isUserInteractionEnabled = false
        insertSubview(placeholderView, at: 0)
        NSLayoutConstraint.activate([
            placeholderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholderView.topAnchor.constraint(equalTo: topAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updatePlaceholder()
    }

    /// Requests `url` and shows it. Passing nil or an empty string clears the view.
    func setImage(url: String?, placeholder: UIColor? = nil) {
        let target = url ?? ""
        if let placeholder = placeholder {
            placeholderColor = placeholder
        }
        if target == imageURL, image != nil {
            return
        }
        if target.isEmpty {
            cancelCurrentRequest()
            imageURL = nil
            image = nil
            updatePlaceholder()
            return
        }

        imageURL = target
        image = nil
        updatePlaceholder()

        if let cached = ImageLoader.shared.cachedImage(for: target) {
            apply(cached, for: target)
            return
        }

        if let size = targetSize, size.width > 0, size.height > 0 {
            ImageLoader.shared.load(target, targetSize: size) { [weak self] loaded in
                self?.apply(loaded, for: target)
            }
        } else {
            ImageLoader.shared.load(target) { [weak self] loaded in
                self?.apply(loaded, for: target)
            }
        }
    }

    /// Loads and decodes the image no larger than `size`, which keeps a long list of thumbnails
    /// from holding full-resolution bitmaps.
    func setImage(url: String?, targetSize size: CGSize) {
        targetSize = size
        setImage(url: url)
    }

    /// Clears the image without starting a request.
    func clearImage() {
        cancelCurrentRequest()
        imageURL = nil
        image = nil
        updatePlaceholder()
    }

    /// Repaints the placeholder in the current palette.
    func applyTheme() {
        if placeholderColor == nil {
            placeholderView.backgroundColor = FlowTheme.shared.scheme.surfaceContainerHigh
        } else {
            updatePlaceholder()
        }
    }

    private func apply(_ loaded: UIImage?, for url: String) {
        guard imageURL == url else { return }
        guard let loaded = loaded else {
            updatePlaceholder()
            return
        }
        if fadesIn {
            image = loaded
            alpha = 0.0
            updatePlaceholder()
            FlowMotion.animate({
                self.alpha = 1.0
            }, completion: nil)
        } else {
            image = loaded
            updatePlaceholder()
        }
    }

    private func cancelCurrentRequest() {
        // `ImageLoader` coalesces requests and has no per-view handle to cancel; dropping the URL
        // is what stops a late callback from painting the wrong picture.
        imageURL = nil
    }

    private func updatePlaceholder() {
        placeholderView.isHidden = image != nil
        if let color = placeholderColor {
            placeholderView.backgroundColor = color
        } else if placeholderView.backgroundColor == nil {
            placeholderView.backgroundColor = FlowTheme.shared.scheme.surfaceContainerHigh
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if targetSize == nil, bounds.width > 0, bounds.height > 0 {
            targetSize = bounds.size
        }
    }

    /// A convenience initialiser for views built in code.
    static func make(contentMode: UIView.ContentMode = .scaleAspectFill, cornerRadius: CGFloat = 0.0) -> AsyncImageView {
        let view = AsyncImageView()
        view.contentMode = contentMode
        if cornerRadius > 0.0 {
            view.applyCornerRadius(cornerRadius)
        }
        view.applyTheme()
        return view
    }
}
