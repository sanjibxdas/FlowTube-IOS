import UIKit

// MARK: - Mood cell

/// One mood or genre button: a solid block in the category's stripe colour with its name centred.
/// The colour is YouTube's own, so the grid reads the way the Music app's explore page does.
final class MusicMoodCell: UICollectionViewCell {

    static let reuseIdentifier = "MusicMoodCell"

    private let titleLabel = UILabel()
    private var fillColor: UIColor = .clear

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        contentView.layer.cornerRadius = FlowShapes.small
        contentView.layer.masksToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmallEmphasized
        titleLabel.numberOfLines = 2
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.8
        contentView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.md),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.md),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        contentView.isAccessibilityElement = true
        contentView.accessibilityTraits = .button
    }

    /// Fills the button from a mood or genre.
    func configure(_ mood: MoodAndGenre) {
        titleLabel.text = mood.title
        fillColor = UIColor(argb: UInt32(truncatingIfNeeded: mood.stripeColor))
        contentView.backgroundColor = fillColor
        titleLabel.textColor = fillColor.readableContentColor
        contentView.accessibilityLabel = mood.title
    }

    override var isHighlighted: Bool {
        didSet {
            contentView.alpha = isHighlighted ? 0.7 : 1.0
        }
    }
}

// MARK: - Section header

/// The heading above one group of moods, e.g. "Moods" or "Genres".
final class MusicMoodHeaderView: UICollectionReusableView {

    static let reuseIdentifier = "MusicMoodHeaderView"

    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleLarge
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.screenMargin),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -FlowSpacing.screenMargin),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.md),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.lg),
        ])
    }

    /// Sets the heading.
    func configure(title: String) {
        titleLabel.text = title
        applyTheme()
    }

    /// Repaints the heading in the current palette.
    func applyTheme() {
        titleLabel.textColor = FlowTheme.shared.scheme.onSurface
    }
}

// MARK: - Moods and genres

/// The explore page: every mood and genre group YouTube Music returns, drawn as a grid of coloured
/// buttons.
///
/// The grid's column count follows the width — two on a phone, three on a large phone, four on an
/// iPad — which is the same rule the Android screen applies through `flowGridColumns`.
///
/// A mood's browse id is a browse endpoint of its own, not a playlist id, and the app's `YouTubeAPI`
/// does not expose a generic browse-by-id call. Tapping a category therefore runs a music search for
/// its name, which reaches the same catalogue through the endpoint the app does have.
final class MoodsAndGenresViewController: UIViewController {

    // MARK: - State

    private let api: YouTubeAPI
    private let collectionView: UICollectionView
    private let layout = UICollectionViewFlowLayout()
    private let spinner = UIActivityIndicatorView(style: .gray)
    private let emptyState = FlowEmptyState.make(kind: .custom(
        icon: .music,
        title: "No moods & genres available",
        message: "YouTube did not return any categories."
    ))
    private let errorState = FlowEmptyState.make(kind: .error, actionTitle: "Retry")

    private var groups: [MoodAndGenreGroup] = []
    private var isLoading = false
    private var themeToken: ObservationToken?

    // MARK: - Construction

    init(api: YouTubeAPI = YouTubeAPI()) {
        self.api = api
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = FlowSpacing.md
        layout.minimumInteritemSpacing = FlowSpacing.md
        layout.sectionInset = UIEdgeInsets(
            top: FlowSpacing.xs,
            left: FlowSpacing.screenMargin,
            bottom: FlowSpacing.xl,
            right: FlowSpacing.screenMargin
        )
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
        title = "Moods & Genres"
    }

    required init?(coder: NSCoder) {
        api = YouTubeAPI()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = FlowSpacing.md
        layout.minimumInteritemSpacing = FlowSpacing.md
        layout.sectionInset = UIEdgeInsets(
            top: FlowSpacing.xs,
            left: FlowSpacing.screenMargin,
            bottom: FlowSpacing.xl,
            right: FlowSpacing.screenMargin
        )
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(coder: coder)
        title = "Moods & Genres"
    }

    deinit {
        themeToken?.cancelObservation()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        buildCollection()
        buildOverlays()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        applyTheme()
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateItemSize()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return FlowTheme.shared.isDark ? .lightContent : .default
    }

    // MARK: - Build

    private func buildCollection() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: FlowSpacing.xxl, right: 0)
        collectionView.register(MusicMoodCell.self, forCellWithReuseIdentifier: MusicMoodCell.reuseIdentifier)
        collectionView.register(
            MusicMoodHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: MusicMoodHeaderView.reuseIdentifier
        )
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildOverlays() {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        view.addSubview(emptyState)

        errorState.translatesAutoresizingMaskIntoConstraints = false
        errorState.isHidden = true
        errorState.onAction = { [weak self] in self?.load(force: true) }
        view.addSubview(errorState)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: view.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            errorState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorState.topAnchor.constraint(equalTo: view.topAnchor),
            errorState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Two columns on a phone, three on a wide phone and four on an iPad, with the buttons at the
    /// Material mood button height.
    private func updateItemSize() {
        let width = collectionView.bounds.width
        guard width > 0.0 else { return }
        let columns: CGFloat
        if width >= 900.0 {
            columns = 4.0
        } else if width >= 600.0 {
            columns = 3.0
        } else {
            columns = 2.0
        }
        let available = width
            - FlowSpacing.screenMargin * 2.0
            - FlowSpacing.md * (columns - 1.0)
        let itemWidth = floor(available / columns)
        let size = CGSize(width: itemWidth, height: FlowSpacing.moodButtonHeight)
        guard layout.itemSize != size else { return }
        layout.itemSize = size
        layout.invalidateLayout()
    }

    // MARK: - Loading

    private func load(force: Bool = false) {
        if isLoading && !force { return }
        isLoading = true
        errorState.isHidden = true
        if groups.isEmpty {
            spinner.startAnimating()
        }

        api.moodsAndGenres { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoading = false
                self.spinner.stopAnimating()
                switch result {
                case .success(let groups):
                    self.groups = groups.filter { !$0.items.isEmpty }
                    self.emptyState.isHidden = !self.groups.isEmpty
                    self.collectionView.reloadData()
                case .failure(let error):
                    self.groups = []
                    self.collectionView.reloadData()
                    self.emptyState.isHidden = true
                    self.errorState.isHidden = false
                    self.errorState.configure(
                        kind: .custom(icon: .wifi, title: "Couldn't load moods & genres", message: error.displayMessage),
                        actionTitle: "Retry"
                    )
                }
            }
        }
    }

    // MARK: - Actions

    private func open(_ mood: MoodAndGenre) {
        MusicItemRouter.openSearch(query: mood.title, from: self)
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        spinner.color = scheme.onSurfaceVariant
        emptyState.applyTheme()
        errorState.applyTheme()
        collectionView.reloadData()
    }
}

// MARK: - Data source

extension MoodsAndGenresViewController: UICollectionViewDataSource {

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return groups.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return groups.element(at: section)?.items.count ?? 0
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: MusicMoodCell.reuseIdentifier,
            for: indexPath
        )
        guard let moodCell = cell as? MusicMoodCell,
              let mood = groups.element(at: indexPath.section)?.items.element(at: indexPath.item) else {
            return cell
        }
        moodCell.configure(mood)
        return moodCell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let view = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: MusicMoodHeaderView.reuseIdentifier,
            for: indexPath
        )
        guard let header = view as? MusicMoodHeaderView, let group = groups.element(at: indexPath.section) else {
            return view
        }
        header.configure(title: group.title)
        return header
    }
}

// MARK: - Delegate

extension MoodsAndGenresViewController: UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let mood = groups.element(at: indexPath.section)?.items.element(at: indexPath.item) else { return }
        open(mood)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> CGSize {
        return CGSize(width: collectionView.bounds.width, height: 56.0)
    }
}
