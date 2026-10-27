import AVFoundation
import UIKit

/// A file the viewer imported into Flow, with the metadata the list needs.
struct LocalMediaItem {

    /// The file on disk.
    let url: URL
    /// The folder it sits in, relative to the import root. Empty for a file at the root.
    let folder: String
    /// The name without its extension.
    let displayName: String
    let kind: LocalMediaKind
    let byteSize: Int64
    let addedAt: Date
    let duration: TimeInterval
    let isPortrait: Bool

    /// A stable id for history and playback. The path is hashed so the id survives a relaunch but
    /// changes when the file is replaced.
    var identifier: String {
        return "local:" + String(url.path.stableHash, radix: 16)
    }

    /// The short side of the frame, used for the quality filter.
    var shortSide: CGFloat
}

/// Whether a local file is a video or a song.
enum LocalMediaKind: Int {
    case video
    case music

    var title: String {
        switch self {
        case .video: return "Videos"
        case .music: return "Music"
        }
    }
}

/// The folder of imported files.
///
/// iOS has no `MediaStore`: an app sees only the files it owns or the ones the viewer hands it
/// through the document picker. Importing copies a picked file into this directory, after which it
/// behaves like the Android screen's local media — it can be browsed by folder, played, filtered and
/// deleted.
enum LocalMediaLibrary {

    /// The root every import is copied into.
    static var directory: URL {
        let documents = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: documents).appendingPathComponent("Flow/LocalMedia", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        }
        return root
    }

    /// The extensions the screen treats as media. Everything else is left alone.
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "3gp", "mkv", "webm", "avi"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "caf"]

    /// The document types the picker offers.
    static let importTypes: [String] = ["public.movie", "public.audio", "public.video"]

    /// Copies `source` into the library, keeping its name and adding a suffix when that name is
    /// taken. Returns the destination, or nil when the file could not be read.
    @discardableResult
    static func importFile(from source: URL) -> URL? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let name = source.lastPathComponent
        guard !name.isEmpty else { return nil }
        let destination = uniqueDestination(for: name)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// A path in the library that does not exist yet, derived from `name`.
    static func uniqueDestination(for name: String) -> URL {
        let root = directory
        var candidate = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = root.appendingPathComponent(nextName)
            index += 1
        }
        return candidate
    }

    /// Every media file in the library, newest first.
    static func scan() -> [LocalMediaItem] {
        let manager = FileManager.default
        let root = directory
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: nil
        ) else {
            return []
        }

        var items: [LocalMediaItem] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            let kind: LocalMediaKind
            if videoExtensions.contains(ext) {
                kind = .video
            } else if audioExtensions.contains(ext) {
                kind = .music
            } else {
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            let folder = relativeFolder(of: url, root: root)
            let size = Int64(values.fileSize ?? 0)
            let added = values.creationDate ?? values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            let metadata = LocalMediaLibrary.metadata(for: url, kind: kind)
            items.append(LocalMediaItem(
                url: url,
                folder: folder,
                displayName: url.deletingPathExtension().lastPathComponent,
                kind: kind,
                byteSize: size,
                addedAt: added,
                duration: metadata.duration,
                isPortrait: metadata.isPortrait,
                shortSide: metadata.shortSide
            ))
        }
        return items.sorted { $0.addedAt > $1.addedAt }
    }

    /// The folder a file sits in, relative to the root. A file at the root returns "".
    static func relativeFolder(of url: URL, root: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        let rootPath = root.path
        guard parent.hasPrefix(rootPath) else { return "" }
        var relative = String(parent.dropFirst(rootPath.count))
        if relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative
    }

    /// Reads a file's duration and frame shape. A file AVFoundation cannot open still lists, with a
    /// zero duration, so the viewer can delete it.
    static func metadata(for url: URL, kind: LocalMediaKind) -> (duration: TimeInterval, isPortrait: Bool, shortSide: CGFloat) {
        let asset = AVURLAsset(url: url)
        let duration = asset.duration.seconds
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0.0
        guard kind == .video,
              let track = asset.tracks(withMediaType: .video).first else {
            return (safeDuration, false, 0.0)
        }
        let size = track.naturalSize.applying(track.preferredTransform)
        let width = abs(size.width)
        let height = abs(size.height)
        return (safeDuration, height > width, min(width, height))
    }

    /// Deletes a file. Returns whether it is gone afterwards.
    static func delete(_ item: LocalMediaItem) -> Bool {
        do {
            try FileManager.default.removeItem(at: item.url)
            return true
        } catch {
            return false
        }
    }
}

/// Local media: the files the viewer imported, browsed by folder, filtered and played.
///
/// The Android screen reads the device's media store and asks for a runtime permission. iOS has
/// neither, so the screen owns its library: files arrive through the document picker, are copied into
/// the app's container, and are then scanned on every appearance. Everything else — the kind switch,
/// search, sort, length and quality filters, the portrait and unwatched toggles, folder grouping and
/// the selection toolbar — matches the Android screen.
final class LocalMediaViewController: UIViewController {

    // MARK: - Filters

    /// How the list is grouped.
    enum Grouping: Int {
        case all
        case folders

        var title: String {
            switch self {
            case .all: return "All"
            case .folders: return "Folders"
            }
        }
    }

    /// The order files are shown in.
    enum Sort: Int, CaseIterable {
        case dateAdded
        case name
        case length
        case size
        case recentlyPlayed

        var title: String {
            switch self {
            case .dateAdded: return "Date added"
            case .name: return "Name"
            case .length: return "Length"
            case .size: return "Size"
            case .recentlyPlayed: return "Recently played"
            }
        }
    }

    /// The length bands the filter offers.
    enum LengthFilter: Int, CaseIterable {
        case any
        case underFourMinutes
        case fourToTwenty
        case overTwenty

        var title: String {
            switch self {
            case .any: return "Any length"
            case .underFourMinutes: return "Under 4 min"
            case .fourToTwenty: return "4 to 20 min"
            case .overTwenty: return "Over 20 min"
            }
        }

        func matches(_ duration: TimeInterval) -> Bool {
            switch self {
            case .any: return true
            case .underFourMinutes: return duration > 0 && duration < 240.0
            case .fourToTwenty: return duration >= 240.0 && duration <= 1200.0
            case .overTwenty: return duration > 1200.0
            }
        }
    }

    /// The quality bands, by the frame's short side.
    enum QualityFilter: Int, CaseIterable {
        case any
        case sd
        case hd
        case fullHD
        case ultraHD

        var title: String {
            switch self {
            case .any: return "Any quality"
            case .sd: return "SD"
            case .hd: return "HD"
            case .fullHD: return "Full HD"
            case .ultraHD: return "4K"
            }
        }

        func matches(shortSide: CGFloat) -> Bool {
            switch self {
            case .any: return true
            case .sd: return shortSide > 0 && shortSide < 720.0
            case .hd: return shortSide >= 720.0 && shortSide < 1080.0
            case .fullHD: return shortSide >= 1080.0 && shortSide < 2160.0
            case .ultraHD: return shortSide >= 2160.0
            }
        }
    }

    /// One folder's worth of files.
    private struct FolderGroup {
        let folder: String
        let items: [LocalMediaItem]
    }

    // MARK: - Views

    private let kindControl = FlowSegmentedControl()
    private let searchField = LibrarySearchField(placeholder: "Search videos and music")
    private let filterRow = FlowChipRow()
    private let groupingRow = FlowChipRow()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let collectionView: UICollectionView
    private let gridLayout = UICollectionViewFlowLayout()
    private let emptyState = FlowEmptyState.make(kind: .custom(
        icon: .importIcon,
        title: "No videos found",
        message: "Videos and music stored on this device will appear here."
    ), actionTitle: "Import files")
    private let importButton = FlowIconButton.make(.add, color: .clear, size: 24.0, target: nil, action: nil)
    private let spinner = UIActivityIndicatorView(style: .gray)
    private let scanningLabel = UILabel()

    // MARK: - State

    private var allItems: [LocalMediaItem] = []
    private var items: [LocalMediaItem] = []
    private var groups: [FolderGroup] = []
    private var kind: LocalMediaKind = .video
    private var grouping: Grouping = .all
    private var sort: Sort = .dateAdded
    private var lengthFilter: LengthFilter = .any
    private var qualityFilter: QualityFilter = .any
    private var portraitOnly = false
    private var unwatchedOnly = false
    private var query = ""
    private var showsGrid = false
    private var isScanning = false
    private var hiddenFolders: Set<String> = []
    private var tokens: [ObservationToken] = []

    private static let hiddenFoldersKey = "library.hiddenLocalFolders"
    private static let gridKey = "library.localMediaAsGrid"

    // MARK: - Construction

    init() {
        gridLayout.minimumLineSpacing = FlowSpacing.lg
        gridLayout.minimumInteritemSpacing = FlowSpacing.lg
        gridLayout.sectionInset = UIEdgeInsets(
            top: FlowSpacing.md,
            left: FlowSpacing.screenMargin,
            bottom: FlowSpacing.xxl,
            right: FlowSpacing.screenMargin
        )
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: gridLayout)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        gridLayout.minimumLineSpacing = FlowSpacing.lg
        gridLayout.minimumInteritemSpacing = FlowSpacing.lg
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: gridLayout)
        super.init(coder: coder)
    }

    deinit {
        for token in tokens {
            token.cancelObservation()
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Local media"
        view.backgroundColor = FlowTheme.shared.background
        hiddenFolders = Set(UserDefaults.standard.stringArray(forKey: LocalMediaViewController.hiddenFoldersKey) ?? [])
        showsGrid = UserDefaults.standard.bool(forKey: LocalMediaViewController.gridKey)
        buildViews()
        observeStores()
        applyTheme()
        scan()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        scan()
    }

    // MARK: - Build

    private func buildViews() {
        kindControl.setTitles([LocalMediaKind.video.title, LocalMediaKind.music.title], selectedIndex: 0)
        kindControl.onSelect = { [weak self] index in
            guard let self = self, let selected = LocalMediaKind(rawValue: index) else { return }
            self.kind = selected
            self.applyFilters()
        }

        searchField.onChange = { [weak self] text in
            self?.query = text
            self?.applyFilters()
        }

        importButton.accessibilityLabel = "Import files"
        importButton.addTarget(self, action: #selector(presentImporter), for: .touchUpInside)
        importButton.widthAnchor.constraint(equalToConstant: 44.0).isActive = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: importButton)

        filterRow.onSelect = { [weak self] index in
            guard let self = self else { return }
            // The row holds the sort, the length band, the quality band and the two toggles.
            switch index {
            case 0: self.presentSortMenu()
            case 1: self.presentLengthMenu()
            case 2: self.presentQualityMenu()
            case 3:
                self.portraitOnly.toggle()
                self.applyFilters()
            case 4:
                self.unwatchedOnly.toggle()
                self.applyFilters()
            default:
                break
            }
        }

        groupingRow.onSelect = { [weak self] index in
            guard let self = self, let selected = Grouping(rawValue: index) else { return }
            self.grouping = selected
            self.applyFilters()
        }

        let searchRow = UIStackView(arrangedSubviews: [searchField, importButton])
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchRow.axis = .horizontal
        searchRow.spacing = FlowSpacing.xs
        searchRow.alignment = .center

        let header = UIStackView(arrangedSubviews: [kindControl, searchRow, filterRow, groupingRow])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.axis = .vertical
        header.spacing = FlowSpacing.xs
        view.addSubview(header)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = 76.0
        tableView.sectionHeaderHeight = 40.0
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(LocalMediaRowCell.self, forCellReuseIdentifier: LocalMediaRowCell.reuseIdentifier)
        tableView.register(
            LocalMediaFolderHeader.self,
            forHeaderFooterViewReuseIdentifier: LocalMediaFolderHeader.reuseIdentifier
        )
        view.addSubview(tableView)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(LocalMediaGridCell.self, forCellWithReuseIdentifier: LocalMediaGridCell.reuseIdentifier)
        collectionView.isHidden = true
        view.addSubview(collectionView)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        emptyState.onAction = { [weak self] in
            self?.presentImporter()
        }
        view.addSubview(emptyState)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        scanningLabel.translatesAutoresizingMaskIntoConstraints = false
        scanningLabel.font = FlowTypography.bodyMedium
        scanningLabel.text = "Scanning your device…"
        scanningLabel.textAlignment = .center
        scanningLabel.isHidden = true
        view.addSubview(scanningLabel)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FlowSpacing.screenMargin),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.md),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: FlowSpacing.md),
            kindControl.widthAnchor.constraint(equalToConstant: 240.0),

            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: FlowSpacing.sm),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: FlowSpacing.sm),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: header.bottomAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            scanningLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scanningLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: FlowSpacing.md),
        ])
    }

    private func observeStores() {
        tokens.append(FlowEventBus.shared.on("history") { [weak self] _ in
            guard let self = self else { return }
            // A play updates the watched state, which the unwatched filter and the "New" badge read.
            DispatchQueue.main.async { self.applyFilters() }
        })
        tokens.append(FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        })
    }

    // MARK: - Scanning

    /// Reads the library directory off the main thread; a large folder of videos would otherwise
    /// stall the first frame.
    private func scan() {
        guard !isScanning else { return }
        isScanning = true
        spinner.startAnimating()
        scanningLabel.isHidden = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = LocalMediaLibrary.scan()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isScanning = false
                self.spinner.stopAnimating()
                self.scanningLabel.isHidden = true
                self.allItems = found
                self.applyFilters()
            }
        }
    }

    // MARK: - Filtering

    private func applyFilters() {
        let trimmed = query.trimmed.lowercased()
        var filtered = allItems.filter { item in
            guard item.kind == kind else { return false }
            guard !hiddenFolders.contains(item.folder) else { return false }
            guard lengthFilter.matches(item.duration) else { return false }
            guard qualityFilter.matches(shortSide: item.shortSide) || item.kind == .music else { return false }
            if portraitOnly && !item.isPortrait { return false }
            if unwatchedOnly && isWatched(item) { return false }
            guard !trimmed.isEmpty else { return true }
            return item.displayName.lowercased().contains(trimmed)
                || item.folder.lowercased().contains(trimmed)
        }

        switch sort {
        case .dateAdded:
            filtered.sort { $0.addedAt > $1.addedAt }
        case .name:
            filtered.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .length:
            filtered.sort { $0.duration > $1.duration }
        case .size:
            filtered.sort { $0.byteSize > $1.byteSize }
        case .recentlyPlayed:
            filtered.sort { left, right in
                let leftDate = HistoryStore.shared.cachedEntries.first { $0.videoId == left.identifier }?.watchedAt
                let rightDate = HistoryStore.shared.cachedEntries.first { $0.videoId == right.identifier }?.watchedAt
                switch (leftDate, rightDate) {
                case let (leftValue?, rightValue?):
                    return leftValue > rightValue
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return left.addedAt > right.addedAt
                }
            }
        }
        items = filtered

        if grouping == .folders {
            var order: [String] = []
            var buckets: [String: [LocalMediaItem]] = [:]
            for item in filtered {
                if buckets[item.folder] == nil {
                    order.append(item.folder)
                    buckets[item.folder] = []
                }
                buckets[item.folder]?.append(item)
            }
            groups = order.map { FolderGroup(folder: $0, items: buckets[$0] ?? []) }
        } else {
            groups = filtered.isEmpty ? [] : [FolderGroup(folder: "", items: filtered)]
        }

        rebuildFilterChips()
        tableView.reloadData()
        collectionView.reloadData()
        updateEmptyState()
    }

    private func rebuildFilterChips() {
        let sortTitle = sort == .dateAdded ? "Sort" : sort.title
        let lengthTitle = lengthFilter == .any ? "Length" : lengthFilter.title
        let qualityTitle = qualityFilter == .any ? "Quality" : qualityFilter.title
        filterRow.setTitles([sortTitle, lengthTitle, qualityTitle, "Portrait", "Unwatched"], selectedIndex: -1)
        for (index, chip) in filterRow.chips.enumerated() {
            let active: Bool
            switch index {
            case 0: active = sort != .dateAdded
            case 1: active = lengthFilter != .any
            case 2: active = qualityFilter != .any
            case 3: active = portraitOnly
            case 4: active = unwatchedOnly
            default: active = false
            }
            chip.setSelected(active, animated: false)
        }
        groupingRow.setTitles([Grouping.all.title, Grouping.folders.title], selectedIndex: grouping.rawValue)
    }

    private func updateEmptyState() {
        let hasAnything = !allItems.isEmpty
        let hasResults = !items.isEmpty
        emptyState.isHidden = hasResults
        tableView.isHidden = !hasResults || showsGrid
        collectionView.isHidden = !hasResults || !showsGrid
        if hasAnything && !hasResults {
            emptyState.configure(
                kind: .custom(
                    icon: .search,
                    title: "No \(kind == .video ? "videos" : "music") found",
                    message: "Try a different search or filter."
                ),
                actionTitle: nil
            )
        } else {
            emptyState.configure(
                kind: .custom(
                    icon: .importIcon,
                    title: "No \(kind == .video ? "videos" : "music") found",
                    message: "Videos and music stored on this device will appear here."
                ),
                actionTitle: "Import files"
            )
        }
    }

    // MARK: - Theme

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        tableView.backgroundColor = scheme.background
        collectionView.backgroundColor = scheme.background
        kindControl.applyTheme()
        searchField.applyTheme()
        filterRow.applyTheme()
        groupingRow.applyTheme()
        emptyState.applyTheme()
        importButton.setIconColor(scheme.onSurface)
        scanningLabel.textColor = scheme.onSurfaceVariant
        for cell in tableView.visibleCells {
            (cell as? LocalMediaRowCell)?.applyTheme()
        }
        for cell in collectionView.visibleCells {
            (cell as? LocalMediaGridCell)?.applyTheme()
        }
    }

    // MARK: - Menus

    private func presentSortMenu() {
        let actions = Sort.allCases.map { option in
            FlowActionSheetContent.Action(title: option.title, icon: .sort) { [weak self] in
                self?.sort = option
                self?.applyFilters()
            }
        }
        LibraryMenu.present(from: self, title: "Sort by", actions: actions)
    }

    private func presentLengthMenu() {
        let actions = LengthFilter.allCases.map { option in
            FlowActionSheetContent.Action(title: option.title, icon: .clock) { [weak self] in
                self?.lengthFilter = option
                self?.applyFilters()
            }
        }
        LibraryMenu.present(from: self, title: "Length", actions: actions)
    }

    private func presentQualityMenu() {
        let actions = QualityFilter.allCases.map { option in
            FlowActionSheetContent.Action(title: option.title, icon: .fullscreen) { [weak self] in
                self?.qualityFilter = option
                self?.applyFilters()
            }
        }
        LibraryMenu.present(from: self, title: "Quality", actions: actions)
    }

    /// The long-press menu for one file, matching the Android screen's local file menu.
    private func presentFileMenu(_ item: LocalMediaItem) {
        var actions: [FlowActionSheetContent.Action] = [
            FlowActionSheetContent.Action(title: "Play next", icon: .next) { [weak self] in
                FlowApp.shared.playback.playNext(self?.queueItem(for: item) ?? LocalMediaViewController.placeholderItem(for: item))
            },
            FlowActionSheetContent.Action(title: "Add to queue", icon: .queue) { [weak self] in
                FlowApp.shared.playback.enqueue(self?.queueItem(for: item) ?? LocalMediaViewController.placeholderItem(for: item))
                FlowSnackbar.show("Added to queue")
            },
            FlowActionSheetContent.Action(title: "Share", icon: .share) { [weak self] in
                self?.share(item)
            },
            FlowActionSheetContent.Action(title: "Details", icon: .notes) { [weak self] in
                self?.showDetails(item)
            },
        ]
        if !item.folder.isEmpty {
            actions.append(FlowActionSheetContent.Action(title: "Hide this folder", icon: .close) { [weak self] in
                self?.hideFolder(item.folder)
            })
        }
        actions.append(FlowActionSheetContent.Action(title: "Delete", icon: .trash, isDestructive: true) { [weak self] in
            self?.confirmDelete([item])
        })
        LibraryMenu.present(from: self, title: item.displayName, actions: actions)
    }

    // MARK: - Actions

    @objc private func presentImporter() {
        let picker = UIDocumentPickerViewController(documentTypes: LocalMediaLibrary.importTypes, in: .import)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true, completion: nil)
    }

    private func queueItem(for item: LocalMediaItem) -> PlaybackQueueItem {
        return PlaybackQueueItem(
            videoId: item.identifier,
            title: item.displayName,
            channelName: item.folder.isEmpty ? "On this device" : item.folder,
            duration: item.duration,
            isMusic: item.kind == .music,
            localFileURL: item.url
        )
    }

    /// A queue entry for a file whose kind is not known yet, used by Play next before the item is
    /// resolved. It carries the path, so it plays exactly like the resolved one.
    private static func placeholderItem(for item: LocalMediaItem) -> PlaybackQueueItem {
        return PlaybackQueueItem(
            videoId: item.identifier,
            title: item.displayName,
            channelName: item.folder.isEmpty ? "On this device" : item.folder,
            duration: item.duration,
            isMusic: item.kind == .music,
            localFileURL: item.url
        )
    }

    private func play(_ item: LocalMediaItem) {
        let queue = items.map { queueItem(for: $0) }
        let index = items.firstIndex { $0.url == item.url } ?? 0
        FlowApp.shared.playback.play(
            items: queue,
            startIndex: index,
            title: item.folder.isEmpty ? "Local media" : item.folder,
            autoplay: true
        )
        if item.kind == .music {
            Router.shared.present(MusicPlayerViewController(service: FlowApp.shared.playback), from: self)
        } else {
            let player = LocalMediaPlayerViewController(item: item)
            player.modalPresentationStyle = .fullScreen
            present(player, animated: true, completion: nil)
        }
    }

    private func share(_ item: LocalMediaItem) {
        let activity = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = view
        activity.popoverPresentationController?.sourceRect = CGRect(
            x: view.bounds.midX,
            y: view.bounds.midY,
            width: 1.0,
            height: 1.0
        )
        present(activity, animated: true, completion: nil)
    }

    private func showDetails(_ item: LocalMediaItem) {
        var lines: [String] = []
        lines.append("Name: \(item.url.lastPathComponent)")
        if !item.folder.isEmpty {
            lines.append("Folder: \(item.folder)")
        }
        lines.append("Size: \(Formatters.fileSize(item.byteSize))")
        if item.duration > 0 {
            lines.append("Length: \(Formatters.longDuration(item.duration))")
        }
        lines.append("Added: \(Formatters.absoluteDate(item.addedAt))")
        if item.shortSide > 0 {
            lines.append("Quality: \(Int(item.shortSide))p")
        }
        let alert = UIAlertController(title: item.displayName, message: lines.joined(separator: "\n"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Done", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }

    private func hideFolder(_ folder: String) {
        hiddenFolders.insert(folder)
        UserDefaults.standard.set(Array(hiddenFolders), forKey: LocalMediaViewController.hiddenFoldersKey)
        applyFilters()
        FlowSnackbar.show("Hid \(folder)", actionTitle: "Undo") { [weak self] in
            self?.hiddenFolders.remove(folder)
            UserDefaults.standard.set(Array(self?.hiddenFolders ?? []), forKey: LocalMediaViewController.hiddenFoldersKey)
            self?.applyFilters()
        }
    }

    private func confirmDelete(_ toDelete: [LocalMediaItem]) {
        guard !toDelete.isEmpty else { return }
        let title = toDelete.count == 1 ? "Delete file?" : "Delete \(toDelete.count) files?"
        let message = toDelete.count == 1
            ? "\(toDelete[0].displayName) will be removed from this device."
            : "These files will be removed from this device."
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            var removed = 0
            for item in toDelete where LocalMediaLibrary.delete(item) {
                removed += 1
            }
            if removed < toDelete.count {
                FlowSnackbar.showError("Couldn't delete that file")
            } else {
                FlowSnackbar.show(toDelete.count == 1 ? "File deleted" : "\(removed) files deleted")
            }
            self?.scan()
        })
        present(alert, animated: true, completion: nil)
    }

    private func setGrid(_ grid: Bool) {
        guard showsGrid != grid else { return }
        showsGrid = grid
        UserDefaults.standard.set(grid, forKey: LocalMediaViewController.gridKey)
        updateEmptyState()
    }

    // MARK: - Watch state

    /// Whether a file has been watched to the end.
    private func isWatched(_ item: LocalMediaItem) -> Bool {
        guard let entry = HistoryStore.shared.cachedEntries.first(where: { $0.videoId == item.identifier }) else {
            return false
        }
        return entry.isFinished
    }

    /// Whether a file was added in the last week and has not been played.
    private func isNew(_ item: LocalMediaItem) -> Bool {
        guard !HistoryStore.shared.contains(videoId: item.identifier) else { return false }
        return Date().timeIntervalSince(item.addedAt) < 7.0 * 24.0 * 60.0 * 60.0
    }
}

// MARK: - Document picker

extension LocalMediaViewController: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        var imported = 0
        for url in urls where LocalMediaLibrary.importFile(from: url) != nil {
            imported += 1
        }
        if imported == 0 {
            FlowSnackbar.showError("Couldn't import those files")
        } else {
            FlowSnackbar.show("Imported \(imported) file\(imported == 1 ? "" : "s")")
        }
        scan()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // Nothing was imported; the list stays as it was.
    }
}

// MARK: - Table data

extension LocalMediaViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        return groups.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return groups.element(at: section)?.items.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LocalMediaRowCell.reuseIdentifier, for: indexPath)
        guard let row = cell as? LocalMediaRowCell,
              let group = groups.element(at: indexPath.section),
              let item = group.items.element(at: indexPath.row) else {
            return cell
        }
        row.configure(with: item, isNew: isNew(item), isWatched: isWatched(item))
        row.onMore = { [weak self] in
            self?.presentFileMenu(item)
        }
        row.applyTheme()
        return row
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard grouping == .folders, let group = groups.element(at: section) else { return nil }
        guard let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: LocalMediaFolderHeader.reuseIdentifier
        ) as? LocalMediaFolderHeader else { return nil }
        header.configure(
            folder: group.folder.isEmpty ? "Imported files" : group.folder,
            count: group.items.count
        )
        header.applyTheme()
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return grouping == .folders ? 40.0 : 0.0
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let group = groups.element(at: indexPath.section),
              let item = group.items.element(at: indexPath.row) else { return }
        play(item)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let group = groups.element(at: indexPath.section),
              let item = group.items.element(at: indexPath.row) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            self?.confirmDelete([item])
            completion(true)
        }
        delete.backgroundColor = FlowTheme.shared.scheme.error
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

// MARK: - Grid data

extension LocalMediaViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: LocalMediaGridCell.reuseIdentifier,
            for: indexPath
        )
        guard let tile = cell as? LocalMediaGridCell, let item = items.element(at: indexPath.item) else {
            return cell
        }
        tile.configure(with: item, isNew: isNew(item))
        tile.applyTheme()
        return tile
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let available = collectionView.bounds.width
            - FlowSpacing.screenMargin * 2.0
            - FlowSpacing.lg
        let columns: CGFloat = available > 520.0 ? 3.0 : 2.0
        let width = floor((available - FlowSpacing.lg * (columns - 1.0)) / columns)
        return CGSize(width: max(width, 120.0), height: max(width, 120.0) * 0.75 + 52.0)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = items.element(at: indexPath.item) else { return }
        play(item)
    }
}

// MARK: - Row

/// One local file: a still or a music glyph, the name, its folder, length and size, and a state pill.
final class LocalMediaRowCell: UITableViewCell {

    static let reuseIdentifier = "LocalMediaRowCell"

    private let thumbnail = AsyncImageView.make(cornerRadius: FlowShapes.thumbnail)
    private let glyph = FlowIconView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let badge = FlowBadge.make("")
    private let moreButton = FlowIconButton.make(.more, color: .clear, size: 20.0, target: nil, action: nil)

    /// Called when the overflow button is tapped.
    var onMore: (() -> Void)?

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

        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(thumbnail)

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.iconSize = 24.0
        glyph.isHidden = true
        contentView.addSubview(glyph)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 1
        contentView.addSubview(detailLabel)

        badge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(badge)

        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.addTarget(self, action: #selector(handleMore), for: .touchUpInside)
        moreButton.accessibilityLabel = "File actions"
        contentView.addSubview(moreButton)

        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            thumbnail.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 96.0),
            thumbnail.heightAnchor.constraint(equalToConstant: 54.0),

            glyph.centerXAnchor.constraint(equalTo: thumbnail.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: thumbnail.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 24.0),
            glyph.heightAnchor.constraint(equalToConstant: 24.0),

            titleLabel.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: FlowSpacing.lg),
            titleLabel.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -FlowSpacing.xs),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -FlowSpacing.md),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xxs),

            badge.leadingAnchor.constraint(greaterThanOrEqualTo: detailLabel.trailingAnchor, constant: FlowSpacing.md),
            badge.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -FlowSpacing.xs),
            badge.centerYAnchor.constraint(equalTo: detailLabel.centerYAnchor),

            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.sm),
            moreButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 40.0),
            moreButton.heightAnchor.constraint(equalToConstant: 40.0),
        ])
        applyTheme()
    }

    /// Sets the row's content.
    func configure(with item: LocalMediaItem, isNew: Bool, isWatched: Bool) {
        titleLabel.text = item.displayName
        var parts: [String] = []
        if !item.folder.isEmpty {
            parts.append(item.folder)
        }
        if item.duration > 0 {
            parts.append(Formatters.playbackTime(item.duration))
        }
        parts.append(Formatters.fileSize(item.byteSize))
        detailLabel.text = parts.joined(separator: " · ")

        if isNew {
            badge.setText("New")
            badge.isHidden = false
        } else if isWatched {
            badge.setText("Watched")
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }

        if item.kind == .music {
            thumbnail.isHidden = true
            glyph.isHidden = false
            glyph.icon = .music
        } else {
            thumbnail.isHidden = false
            glyph.isHidden = true
            thumbnail.setImage(url: nil, targetSize: CGSize(width: 192.0, height: 108.0))
            LocalMediaRowCell.loadThumbnail(for: item, into: thumbnail)
        }
        accessibilityLabel = "\(item.displayName), \(detailLabel.text ?? "")"
    }

    /// Asks AVFoundation for a still from the file's first seconds. A file that will not decode
    /// keeps the placeholder, so the row still reads as a video.
    private static func loadThumbnail(for item: LocalMediaItem, into view: AsyncImageView) {
        let asset = AVURLAsset(url: item.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 384.0, height: 216.0)
        let time = CMTime(seconds: min(max(item.duration * 0.1, 0.0), 5.0), preferredTimescale: 600)
        DispatchQueue.global(qos: .userInitiated).async {
            let image: UIImage?
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                image = UIImage(cgImage: cgImage)
            } else {
                image = nil
            }
            DispatchQueue.main.async {
                guard let image = image else { return }
                view.image = image
            }
        }
    }

    /// Repaints the row in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        thumbnail.applyTheme()
        thumbnail.backgroundColor = scheme.surfaceContainerHighest
        glyph.iconColor = scheme.onSurfaceVariant
        titleLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
        badge.applyTheme()
        moreButton.setIconColor(scheme.onSurfaceVariant)
        selectedBackgroundView?.backgroundColor = scheme.surfaceContainerHigh
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.clearImage()
        thumbnail.isHidden = false
        glyph.isHidden = true
        titleLabel.text = nil
        detailLabel.text = nil
        badge.isHidden = true
        onMore = nil
    }

    @objc private func handleMore() {
        onMore?()
    }
}

// MARK: - Grid tile

/// One local file in grid mode: a still with the name and length underneath.
final class LocalMediaGridCell: UICollectionViewCell {

    static let reuseIdentifier = "LocalMediaGridCell"

    private let thumbnail = AsyncImageView.make(cornerRadius: FlowShapes.small)
    private let glyph = FlowIconView()
    private let durationLabel = PaddedLabel()
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
        contentView.backgroundColor = .clear

        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(thumbnail)

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.iconSize = 28.0
        glyph.isHidden = true
        contentView.addSubview(glyph)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = FlowTypography.labelSmall
        durationLabel.textInsets = UIEdgeInsets(top: 1, left: 4, bottom: 1, right: 4)
        durationLabel.layer.cornerRadius = FlowShapes.extraSmall
        durationLabel.layer.masksToBounds = true
        contentView.addSubview(durationLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.bodySmall
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumbnail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            thumbnail.topAnchor.constraint(equalTo: contentView.topAnchor),
            thumbnail.heightAnchor.constraint(equalTo: thumbnail.widthAnchor, multiplier: 0.75),

            glyph.centerXAnchor.constraint(equalTo: thumbnail.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: thumbnail.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 28.0),
            glyph.heightAnchor.constraint(equalToConstant: 28.0),

            durationLabel.trailingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: -FlowSpacing.xs),
            durationLabel.bottomAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: -FlowSpacing.xs),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: FlowSpacing.xs),
        ])
        applyTheme()
    }

    /// Sets the tile's content.
    func configure(with item: LocalMediaItem, isNew: Bool) {
        titleLabel.text = item.displayName
        durationLabel.text = Formatters.durationBadge(item.duration)
        durationLabel.isHidden = durationLabel.text == nil
        if item.kind == .music {
            thumbnail.isHidden = true
            glyph.isHidden = false
            glyph.icon = .music
        } else {
            thumbnail.isHidden = false
            glyph.isHidden = true
            thumbnail.setImage(url: nil, targetSize: CGSize(width: 320.0, height: 240.0))
        }
        accessibilityLabel = isNew ? "\(item.displayName), new" : item.displayName
    }

    /// Repaints the tile in the current palette.
    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        thumbnail.applyTheme()
        thumbnail.backgroundColor = scheme.surfaceContainerHighest
        glyph.iconColor = scheme.onSurfaceVariant
        durationLabel.textColor = .white
        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        titleLabel.textColor = scheme.onSurface
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.clearImage()
        thumbnail.isHidden = false
        glyph.isHidden = true
        titleLabel.text = nil
        durationLabel.text = nil
    }
}

// MARK: - Folder header

/// The heading above a folder's files: its name and how many it holds.
final class LocalMediaFolderHeader: UITableViewHeaderFooterView {

    static let reuseIdentifier = "LocalMediaFolderHeader"

    private let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        let background = UIView()
        background.backgroundColor = .clear
        backgroundView = background

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FlowTypography.titleSmallEmphasized
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.xs),
        ])
        applyTheme()
    }

    /// Sets the folder's heading.
    func configure(folder: String, count: Int) {
        label.text = "\(folder) · \(count)"
        accessibilityLabel = "\(folder), \(count) file\(count == 1 ? "" : "s")"
    }

    /// Repaints the heading in the current palette.
    func applyTheme() {
        label.textColor = FlowTheme.shared.scheme.onSurface
    }
}

// MARK: - Player

/// A minimal full-screen player for a local video file: the picture, a title bar and a play/pause
/// control. It plays through `PlaybackService`, so the mini player and the audio session stay in
/// step with the rest of the app.
final class LocalMediaPlayerViewController: UIViewController {

    private let item: LocalMediaItem
    private let titleLabel = UILabel()
    private let closeButton = FlowIconButton.make(.close, color: .white, size: 24.0, target: nil, action: nil)
    private let playButton = FlowIconButton.make(.pause, color: .white, size: 32.0, target: nil, action: nil)
    private var playerLayer: AVPlayerLayer?
    private var tokens: [ObservationToken] = []

    init(item: LocalMediaItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        item = LocalMediaItem(
            url: URL(fileURLWithPath: ""),
            folder: "",
            displayName: "",
            kind: .video,
            byteSize: 0,
            addedAt: Date(),
            duration: 0,
            isPortrait: false,
            shortSide: 0
        )
        super.init(coder: coder)
    }

    deinit {
        for token in tokens {
            token.cancelObservation()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let player = FlowApp.shared.playback.player
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        playerLayer = layer

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = item.displayName
        titleLabel.font = FlowTypography.titleMediumEmphasized
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        view.addSubview(titleLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.accessibilityLabel = "Close"
        view.addSubview(closeButton)

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        playButton.accessibilityLabel = "Pause"
        view.addSubview(playButton)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FlowSpacing.md),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: FlowSpacing.md),

            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: FlowSpacing.md),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.screenMargin),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            playButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -FlowSpacing.xxl),
        ])

        tokens.append(FlowApp.shared.playback.state.observeChanges { [weak self] snapshot in
            self?.playButton.setIcon(snapshot.isPlaying ? .pause : .play)
            self?.playButton.accessibilityLabel = snapshot.isPlaying ? "Pause" : "Play"
        })
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    @objc private func close() {
        FlowApp.shared.playback.pause()
        dismiss(animated: true, completion: nil)
    }

    @objc private func togglePlayback() {
        FlowApp.shared.playback.togglePlayPause()
    }
}
