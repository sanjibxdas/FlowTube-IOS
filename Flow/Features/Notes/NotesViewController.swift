import UIKit

// MARK: - Timestamps in note text

/// Finds the times a note mentions — "12:34", "1:02:03" — so the detail pane can offer a jump for
/// each one. The Android app turns them into links in the text; a row per time is the same
/// affordance with a full tap target.
enum NoteTimestamps {

    struct Moment {
        let text: String
        let seconds: TimeInterval
        let range: Range<String.Index>
    }

    /// Every time in `text`, in the order it appears, without duplicates.
    static func moments(in text: String) -> [Moment] {
        var found: [Moment] = []
        var seen: Set<Int> = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isNumber else {
                index = text.index(after: index)
                continue
            }
            let start = index
            var cursor = index
            var digits = ""
            while cursor < text.endIndex, text[cursor].isNumber {
                digits.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            // A time needs a colon immediately after the first run of digits.
            guard cursor < text.endIndex, text[cursor] == ":" else {
                index = cursor
                continue
            }
            cursor = text.index(after: cursor)
            var secondDigits = ""
            while cursor < text.endIndex, text[cursor].isNumber, secondDigits.count < 2 {
                secondDigits.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            guard secondDigits.count == 2, let secondsPart = Int(secondDigits) else {
                index = cursor
                continue
            }
            var total = 0
            if cursor < text.endIndex, text[cursor] == ":" {
                // h:mm:ss — the first run of digits was the hours.
                guard let hours = Int(digits) else {
                    index = cursor
                    continue
                }
                cursor = text.index(after: cursor)
                var minuteDigits = ""
                while cursor < text.endIndex, text[cursor].isNumber, minuteDigits.count < 2 {
                    minuteDigits.append(text[cursor])
                    cursor = text.index(after: cursor)
                }
                guard minuteDigits.count == 2, let minutes = Int(minuteDigits) else {
                    index = cursor
                    continue
                }
                total = hours * 3600 + minutes * 60 + secondsPart
            } else {
                guard let minutes = Int(digits) else {
                    index = cursor
                    continue
                }
                total = minutes * 60 + secondsPart
            }
            let range = start..<cursor
            if !seen.contains(total) {
                seen.insert(total)
                found.append(Moment(text: String(text[range]), seconds: TimeInterval(total), range: range))
            }
            index = cursor
        }
        return found
    }
}

// MARK: - Custom order

/// The order the viewer dragged the notes into. `NoteStore` sorts by edit time and has no position
/// column, so the custom order lives in the defaults as a list of note ids; a note that is not in
/// the list yet follows the notes that are, newest edit first.
enum NotesOrderStore {

    private static let key = "notes.customOrder"
    private static let lock = NSLock()

    static func load() -> [Int64] {
        lock.lock()
        let raw = UserDefaults.standard.stringArray(forKey: key) ?? []
        lock.unlock()
        return raw.compactMap { Int64($0) }
    }

    static func save(_ ids: [Int64]) {
        lock.lock()
        UserDefaults.standard.set(ids.map { String($0) }, forKey: key)
        lock.unlock()
    }

    static func remove(_ id: Int64) {
        var ids = load()
        ids.removeAll { $0 == id }
        save(ids)
    }

    /// Applies the saved order to `notes`, keeping any note the order does not mention at the end.
    static func apply(to notes: [VideoNote]) -> [VideoNote] {
        let order = load()
        guard !order.isEmpty else { return notes }
        var rank: [Int64: Int] = [:]
        for (index, id) in order.enumerated() {
            rank[id] = index
        }
        let placed = notes.filter { rank[$0.id] != nil }
        let unplaced = notes.filter { rank[$0.id] == nil }
        let sorted = placed.sorted { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) }
        return sorted + unplaced
    }
}

// MARK: - Filter and sort

enum NotesFilter: Int, CaseIterable {
    case all
    case videos
    case channels

    var title: String {
        switch self {
        case .all: return "All"
        case .videos: return "Videos"
        case .channels: return "Channels"
        }
    }
}

enum NotesSort: Int, CaseIterable {
    case recent
    case oldest
    case title
    case custom

    var title: String {
        switch self {
        case .recent: return "Recently edited"
        case .oldest: return "Oldest first"
        case .title: return "Title"
        case .custom: return "Custom order"
        }
    }
}

// MARK: - Note cell

/// One row of the notes list: the thumbnail of what the note is about, its title and channel, the
/// first line of the note and, when the note is anchored to a time, that time as a badge.
final class NoteCell: UITableViewCell {

    static let reuseIdentifier = "NoteCell"

    private let thumbnail = AsyncImageView.make(contentMode: .scaleAspectFill, cornerRadius: FlowShapes.thumbnail)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let timeBadge = PaddedLabel()
    private let checkView = FlowIconView()

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
        thumbnail.clipsToBounds = true
        thumbnail.backgroundColor = FlowTheme.shared.scheme.surfaceContainerHigh

        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 1
        subtitleLabel.font = FlowTypography.bodySmall
        subtitleLabel.numberOfLines = 1
        bodyLabel.font = FlowTypography.bodyMedium
        bodyLabel.numberOfLines = 2

        timeBadge.font = FlowTypography.labelSmall
        timeBadge.layer.cornerRadius = FlowShapes.extraSmall
        timeBadge.layer.masksToBounds = true
        timeBadge.textInsets = UIEdgeInsets(top: 2.0, left: 6.0, bottom: 2.0, right: 6.0)
        timeBadge.setContentHuggingPriority(.required, for: .horizontal)
        timeBadge.translatesAutoresizingMaskIntoConstraints = false

        checkView.iconSize = 22.0
        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.widthAnchor.constraint(equalToConstant: 22.0).isActive = true
        checkView.heightAnchor.constraint(equalToConstant: 22.0).isActive = true
        checkView.isHidden = true

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, bodyLabel])
        textStack.axis = .vertical
        textStack.spacing = 2.0
        textStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(thumbnail)
        contentView.addSubview(textStack)
        contentView.addSubview(timeBadge)
        contentView.addSubview(checkView)

        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.xl),
            thumbnail.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),
            thumbnail.widthAnchor.constraint(equalToConstant: 72.0),
            thumbnail.heightAnchor.constraint(equalToConstant: 44.0),

            textStack.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: FlowSpacing.lg),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.md),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.md),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: timeBadge.leadingAnchor, constant: -FlowSpacing.md),

            timeBadge.trailingAnchor.constraint(equalTo: checkView.leadingAnchor, constant: -FlowSpacing.md),
            timeBadge.centerYAnchor.constraint(equalTo: thumbnail.centerYAnchor),

            checkView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.xl),
            checkView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 72.0),
        ])
        applyTheme()
    }

    func configure(note: VideoNote, isChannelNote: Bool, selecting: Bool, selected: Bool) {
        titleLabel.text = note.videoTitle.isEmpty
            ? (isChannelNote ? "Channel note" : "Video")
            : note.videoTitle
        subtitleLabel.text = note.channelName.isEmpty ? Formatters.relativeDate(note.updatedAt) : note.channelName
        subtitleLabel.isHidden = (subtitleLabel.text ?? "").isEmpty
        bodyLabel.text = note.body
        if isChannelNote || note.timestamp <= 0.0 {
            timeBadge.isHidden = true
        } else {
            timeBadge.isHidden = false
            timeBadge.text = Formatters.playbackTime(note.timestamp)
        }
        checkView.isHidden = !selecting
        checkView.icon = selected ? .check : .add
        checkView.iconColor = selected ? FlowTheme.shared.primary : FlowTheme.shared.onSurfaceVariant
        accessoryType = selecting ? .none : .disclosureIndicator
        if isChannelNote {
            thumbnail.clearImage()
        } else {
            thumbnail.setImage(url: "https://i.ytimg.com/vi/" + note.videoId + "/mqdefault.jpg")
        }
        applyTheme()
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        subtitleLabel.textColor = scheme.onSurfaceVariant
        bodyLabel.textColor = scheme.onSurface
        timeBadge.textColor = scheme.onPrimaryContainer
        timeBadge.backgroundColor = scheme.primaryContainer
        thumbnail.backgroundColor = scheme.surfaceContainerHigh
        (selectedBackgroundView as? UIView)?.backgroundColor = scheme.surfaceContainerHigh
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.clearImage()
        checkView.isHidden = true
        timeBadge.isHidden = true
    }
}

// MARK: - Note detail

/// One note read in full: what it is about, a row per time it mentions, and the text itself.
final class NoteDetailContent: UIView {

    var onPlay: ((TimeInterval) -> Void)?
    var onOpenChannel: ((String) -> Void)?
    var onEdit: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let momentsHeader = UILabel()
    private let momentsStack = UIStackView()
    private let thumbnail = AsyncImageView.make(contentMode: .scaleAspectFill, cornerRadius: FlowShapes.medium)

    private var note: VideoNote?
    private var isChannelNote = false

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
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        addSubview(scrollView)

        stack.axis = .vertical
        stack.spacing = FlowSpacing.lg
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.clipsToBounds = true
        thumbnail.heightAnchor.constraint(equalToConstant: 168.0).isActive = true

        titleLabel.font = FlowTypography.titleLarge
        titleLabel.numberOfLines = 0
        subtitleLabel.font = FlowTypography.bodyMedium
        subtitleLabel.numberOfLines = 1
        bodyLabel.font = FlowTypography.bodyLarge
        bodyLabel.numberOfLines = 0

        momentsHeader.font = FlowTypography.titleSmall
        momentsHeader.text = "Timestamps"

        momentsStack.axis = .vertical
        momentsStack.spacing = FlowSpacing.xs

        let actions = UIStackView()
        actions.axis = .horizontal
        actions.spacing = FlowSpacing.md
        actions.distribution = .fillEqually

        let playButton = FlowButton.make("Play from", style: .filled, icon: .play)
        playButton.onTap = { [weak self] in
            guard let self = self, let note = self.note else { return }
            self.onPlay?(note.timestamp)
        }
        let editButton = FlowButton.make("Edit", style: .tonal, icon: .edit)
        editButton.onTap = { [weak self] in
            self?.onEdit?()
        }
        actions.addArrangedSubview(playButton)
        actions.addArrangedSubview(editButton)

        let secondary = UIStackView()
        secondary.axis = .horizontal
        secondary.spacing = FlowSpacing.md
        secondary.distribution = .fillEqually
        let copyButton = FlowButton.make("Copy text", style: .outlined, icon: .notes)
        copyButton.onTap = { [weak self] in
            self?.onCopy?()
        }
        let deleteButton = FlowButton.make("Delete", style: .destructive, icon: .trash)
        deleteButton.onTap = { [weak self] in
            self?.onDelete?()
        }
        secondary.addArrangedSubview(copyButton)
        secondary.addArrangedSubview(deleteButton)

        stack.addArrangedSubview(thumbnail)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(actions)
        stack.addArrangedSubview(secondary)
        stack.addArrangedSubview(bodyLabel)
        stack.addArrangedSubview(momentsHeader)
        stack.addArrangedSubview(momentsStack)
        stack.setCustomSpacing(FlowSpacing.xl, after: bodyLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: FlowSpacing.xl),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -FlowSpacing.xl),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: FlowSpacing.md),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -FlowSpacing.xxl),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -FlowSpacing.xl * 2.0),
        ])
        applyTheme()
    }

    func configure(note: VideoNote) {
        self.note = note
        isChannelNote = !note.videoId.looksLikeVideoID
        titleLabel.text = note.videoTitle.isEmpty
            ? (isChannelNote ? "Channel note" : "Video")
            : note.videoTitle
        subtitleLabel.text = note.channelName
        subtitleLabel.isHidden = note.channelName.isEmpty
        bodyLabel.text = note.body
        if isChannelNote {
            thumbnail.clearImage()
            thumbnail.isHidden = true
        } else {
            thumbnail.isHidden = false
            thumbnail.setImage(url: "https://i.ytimg.com/vi/" + note.videoId + "/hqdefault.jpg")
        }

        for view in momentsStack.arrangedSubviews {
            momentsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let moments = isChannelNote ? [] : NoteTimestamps.moments(in: note.body)
        momentsHeader.isHidden = moments.isEmpty
        momentsStack.isHidden = moments.isEmpty
        for moment in moments {
            let row = UIButton(type: .custom)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.contentHorizontalAlignment = .left
            row.titleLabel?.font = FlowTypography.bodyMedium
            row.setTitle("Play from " + moment.text, for: .normal)
            row.setTitleColor(FlowTheme.shared.primary, for: .normal)
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 36.0).isActive = true
            row.addClosureAction(for: .touchUpInside) { [weak self] in
                self?.onPlay?(moment.seconds)
            }
            momentsStack.addArrangedSubview(row)
        }
        applyTheme()
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        subtitleLabel.textColor = scheme.onSurfaceVariant
        bodyLabel.textColor = scheme.onSurface
        momentsHeader.textColor = scheme.onSurfaceVariant
        thumbnail.backgroundColor = scheme.surfaceContainerHigh
        for view in momentsStack.arrangedSubviews {
            (view as? UIButton)?.setTitleColor(scheme.primary, for: .normal)
        }
    }
}

// MARK: - Note editor

/// The sheet that writes a note. The target defaults to whatever is playing, so a note taken while
/// watching is one tap from saved; the timestamp field is prefilled with the playback position.
final class NoteEditorContent: UIView, UITextViewDelegate {

    var onSave: ((String, String, TimeInterval) -> Void)?
    var onCancel: (() -> Void)?

    private let targetField = UITextField()
    private let targetContainer = UIView()
    private let timeField = UITextField()
    private let timeContainer = UIView()
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let saveButton = FlowButton.make("Save", style: .filled)
    private let cancelButton = FlowButton.make("Cancel", style: .text)
    private let insertTimeButton = FlowButton.make("Insert time", style: .outlined, icon: .clock)

    private var initialTimestamp: TimeInterval = 0.0
    private var buttonsBottom: NSLayoutConstraint?
    private var keyboardObservers: [NSObjectProtocol] = []

    deinit {
        for observer in keyboardObservers {
            NotificationCenter.default.removeObserver(observer)
        }
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

        targetContainer.layer.cornerRadius = FlowShapes.small
        targetContainer.translatesAutoresizingMaskIntoConstraints = false
        targetField.translatesAutoresizingMaskIntoConstraints = false
        targetField.font = FlowTypography.bodyMedium
        targetField.placeholder = "Video or channel id"
        targetField.autocorrectionType = .no
        targetField.autocapitalizationType = .none
        targetContainer.addSubview(targetField)

        timeContainer.layer.cornerRadius = FlowShapes.small
        timeContainer.translatesAutoresizingMaskIntoConstraints = false
        timeField.translatesAutoresizingMaskIntoConstraints = false
        timeField.font = FlowTypography.bodyMedium
        timeField.placeholder = "0:00"
        timeField.keyboardType = .numbersAndPunctuation
        timeContainer.addSubview(timeField)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = FlowTypography.bodyLarge
        textView.delegate = self
        textView.textContainerInset = UIEdgeInsets(top: FlowSpacing.md, left: FlowSpacing.md, bottom: FlowSpacing.md, right: FlowSpacing.md)
        textView.layer.cornerRadius = FlowShapes.small
        textView.alwaysBounceVertical = true

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = FlowTypography.bodyLarge
        placeholderLabel.text = "Write a note for yourself…"
        placeholderLabel.numberOfLines = 1

        insertTimeButton.onTap = { [weak self] in
            self?.insertCurrentTime()
        }
        saveButton.onTap = { [weak self] in
            self?.save()
        }
        cancelButton.onTap = { [weak self] in
            self?.onCancel?()
        }

        let targetRow = UIStackView(arrangedSubviews: [targetContainer, timeContainer])
        targetRow.axis = .horizontal
        targetRow.spacing = FlowSpacing.md
        targetRow.distribution = .fillEqually
        targetRow.translatesAutoresizingMaskIntoConstraints = false

        let buttons = UIStackView(arrangedSubviews: [cancelButton, saveButton])
        buttons.axis = .horizontal
        buttons.spacing = FlowSpacing.md
        buttons.distribution = .fillEqually
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubview(targetRow)
        addSubview(textView)
        addSubview(placeholderLabel)
        addSubview(insertTimeButton)
        addSubview(buttons)

        NSLayoutConstraint.activate([
            targetRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xl),
            targetRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.xl),
            targetRow.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.md),
            targetRow.heightAnchor.constraint(equalToConstant: 44.0),

            targetField.leadingAnchor.constraint(equalTo: targetContainer.leadingAnchor, constant: FlowSpacing.md),
            targetField.trailingAnchor.constraint(equalTo: targetContainer.trailingAnchor, constant: -FlowSpacing.md),
            targetField.topAnchor.constraint(equalTo: targetContainer.topAnchor),
            targetField.bottomAnchor.constraint(equalTo: targetContainer.bottomAnchor),

            timeField.leadingAnchor.constraint(equalTo: timeContainer.leadingAnchor, constant: FlowSpacing.md),
            timeField.trailingAnchor.constraint(equalTo: timeContainer.trailingAnchor, constant: -FlowSpacing.md),
            timeField.topAnchor.constraint(equalTo: timeContainer.topAnchor),
            timeField.bottomAnchor.constraint(equalTo: timeContainer.bottomAnchor),

            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xl),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.xl),
            textView.topAnchor.constraint(equalTo: targetRow.bottomAnchor, constant: FlowSpacing.md),
            textView.bottomAnchor.constraint(equalTo: insertTimeButton.topAnchor, constant: -FlowSpacing.md),

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: FlowSpacing.md + 4.0),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: FlowSpacing.md),

            insertTimeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xl),
            insertTimeButton.heightAnchor.constraint(equalToConstant: 40.0),

            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xl),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.xl),
            buttons.topAnchor.constraint(equalTo: insertTimeButton.bottomAnchor, constant: FlowSpacing.md),
            buttons.heightAnchor.constraint(equalToConstant: 48.0),
        ])
        let bottom = buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.md)
        bottom.priority = UILayoutPriority(999.0)
        bottom.isActive = true
        buttonsBottom = bottom
        observeKeyboard()
        applyTheme()
    }

    /// Keeps the buttons above the keyboard: the sheet's own height does not change when the
    /// keyboard appears, so the editor lifts its bottom edge by the overlap instead.
    private func observeKeyboard() {
        let center = NotificationCenter.default
        keyboardObservers.append(center.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self, let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            guard self.window != nil else { return }
            let converted = self.convert(frame, from: nil)
            let overlap = max(0.0, self.bounds.maxY - converted.minY)
            self.buttonsBottom?.constant = -(overlap + FlowSpacing.md)
            let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? FlowMotion.standard
            UIView.animate(withDuration: duration, animations: {
                self.superview?.layoutIfNeeded()
            })
        })
        keyboardObservers.append(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.buttonsBottom?.constant = -FlowSpacing.md
            UIView.animate(withDuration: FlowMotion.standard, animations: {
                self.superview?.layoutIfNeeded()
            })
        })
    }

    /// Fills the editor. `body` is empty for a new note.
    func configure(body: String, targetId: String, timestamp: TimeInterval) {
        initialTimestamp = timestamp
        textView.text = body
        targetField.text = targetId
        timeField.text = Formatters.playbackTime(timestamp)
        placeholderLabel.isHidden = !body.isEmpty
    }

    func focus() {
        textView.becomeFirstResponder()
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        targetContainer.backgroundColor = scheme.surfaceContainerHigh
        timeContainer.backgroundColor = scheme.surfaceContainerHigh
        targetField.textColor = scheme.onSurface
        targetField.attributedPlaceholder = NSAttributedString(
            string: "Video or channel id",
            attributes: [.foregroundColor: scheme.onSurfaceVariant]
        )
        timeField.textColor = scheme.onSurface
        timeField.attributedPlaceholder = NSAttributedString(
            string: "0:00",
            attributes: [.foregroundColor: scheme.onSurfaceVariant]
        )
        textView.backgroundColor = scheme.surfaceContainerHigh
        textView.textColor = scheme.onSurface
        placeholderLabel.textColor = scheme.onSurfaceVariant
        saveButton.applyTheme()
        cancelButton.applyTheme()
        insertTimeButton.applyTheme()
    }

    // MARK: - Editing

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
    }

    private func insertCurrentTime() {
        let position = FlowApp.shared.playback.currentPosition
        let text = Formatters.playbackTime(position)
        timeField.text = text
        let existing = textView.text ?? ""
        let separator = existing.isEmpty || existing.hasSuffix(" ") || existing.hasSuffix("\n") ? "" : " "
        textView.text = existing + separator + text + " "
        placeholderLabel.isHidden = true
    }

    /// Parses "m:ss" or "h:mm:ss" back to seconds; anything unreadable keeps the note's own time.
    private func parseTime(_ text: String) -> TimeInterval {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 1:
            return TimeInterval(parts[0])
        case 2:
            return TimeInterval(parts[0] * 60 + parts[1])
        case 3:
            return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
        default:
            return initialTimestamp
        }
    }

    private func save() {
        let body = (textView.text ?? "").trimmed
        guard !body.isEmpty else {
            FlowSnackbar.showError("Write something before saving")
            return
        }
        let target = (targetField.text ?? "").trimmed
        let timestamp = parseTime((timeField.text ?? "").trimmed)
        onSave?(target, body, timestamp)
    }
}

// MARK: - Notes

/// The notes library: every note the viewer has written, with a search field, a kind filter, four
/// sort orders including the order they dragged the notes into, multi-select for bulk delete and
/// share, and a tap that opens the note with a jump to each time it mentions.
final class NotesViewController: UIViewController {

    // MARK: - Navigation

    /// Called when the viewer wants to watch the video a note is about, from `position`.
    var onOpenVideo: ((String, TimeInterval) -> Void)?
    /// Called when the viewer wants to open the channel a note is about.
    var onOpenChannel: ((String) -> Void)?

    // MARK: - State

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let searchBar = NotesSearchBar()
    private let filterChips = FlowChipRow()
    private let sortButton = FlowIconButton()
    private let selectButton = FlowIconButton()
    private let addButton = FlowIconButton()
    private let emptyState = FlowEmptyState.make(kind: .noNotes)
    private let noMatchState = FlowEmptyState.make(
        kind: .custom(icon: .search, title: "No notes match", message: "Try other words or another filter")
    )
    private let selectionBar = UIView()
    private let selectionLabel = UILabel()
    private let deleteSelectedButton = FlowButton.make("Delete", style: .destructive, icon: .trash)
    private let shareSelectedButton = FlowButton.make("Share", style: .outlined, icon: .share)

    private var allNotes: [VideoNote] = []
    private var visibleNotes: [VideoNote] = []
    private var filter: NotesFilter = .all
    private var sort: NotesSort = .recent
    private var query: String = ""
    private var isSelecting = false
    private var selectedIds: Set<Int64> = []
    private var isReordering = false
    private var themeToken: ObservationToken?
    private var notesToken: ObservationToken?

    deinit {
        themeToken?.cancelObservation()
        notesToken?.cancelObservation()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FlowTheme.shared.background
        title = "Notes"
        buildChrome()
        buildTable()
        buildSelectionBar()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        notesToken = FlowEventBus.shared.on("notes") { [weak self] _ in
            DispatchQueue.main.async {
                self?.reload()
            }
        }
        applyTheme()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return FlowTheme.shared.isDark ? .lightContent : .default
    }

    // MARK: - Build

    private func buildChrome() {
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.onChange = { [weak self] text in
            guard let self = self else { return }
            self.query = text
            self.applyFilter()
        }
        view.addSubview(searchBar)

        filterChips.translatesAutoresizingMaskIntoConstraints = false
        filterChips.setTitles(NotesFilter.allCases.map { $0.title }, selectedIndex: filter.rawValue)
        filterChips.onSelect = { [weak self] index in
            guard let self = self, let next = NotesFilter(rawValue: index) else { return }
            self.filter = next
            self.applyFilter()
        }
        view.addSubview(filterChips)

        sortButton.translatesAutoresizingMaskIntoConstraints = false
        sortButton.configure(icon: .sort, color: FlowTheme.shared.onSurface, size: 22.0)
        sortButton.accessibilityLabel = "Sort notes"
        sortButton.addTarget(self, action: #selector(handleSort), for: .touchUpInside)
        view.addSubview(sortButton)

        selectButton.translatesAutoresizingMaskIntoConstraints = false
        selectButton.configure(icon: .check, color: FlowTheme.shared.onSurface, size: 22.0)
        selectButton.accessibilityLabel = "Select notes"
        selectButton.addTarget(self, action: #selector(handleSelectMode), for: .touchUpInside)
        view.addSubview(selectButton)

        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.configure(icon: .add, color: FlowTheme.shared.onSurface, size: 24.0)
        addButton.accessibilityLabel = "Add note"
        addButton.addTarget(self, action: #selector(handleAdd), for: .touchUpInside)
        view.addSubview(addButton)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.onAction = { [weak self] in
            self?.handleAdd()
        }
        view.addSubview(emptyState)

        noMatchState.translatesAutoresizingMaskIntoConstraints = false
        noMatchState.isHidden = true
        view.addSubview(noMatchState)

        NSLayoutConstraint.activate([
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FlowSpacing.screenMargin),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.screenMargin),
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: FlowSpacing.md),
            searchBar.heightAnchor.constraint(equalToConstant: 44.0),

            filterChips.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filterChips.trailingAnchor.constraint(equalTo: sortButton.leadingAnchor, constant: -FlowSpacing.xs),
            filterChips.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: FlowSpacing.sm),
            filterChips.heightAnchor.constraint(equalToConstant: 40.0),

            sortButton.trailingAnchor.constraint(equalTo: selectButton.leadingAnchor, constant: -FlowSpacing.xs),
            sortButton.centerYAnchor.constraint(equalTo: filterChips.centerYAnchor),
            sortButton.widthAnchor.constraint(equalToConstant: 44.0),
            sortButton.heightAnchor.constraint(equalToConstant: 44.0),

            selectButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -FlowSpacing.xs),
            selectButton.centerYAnchor.constraint(equalTo: filterChips.centerYAnchor),
            selectButton.widthAnchor.constraint(equalToConstant: 44.0),
            selectButton.heightAnchor.constraint(equalToConstant: 44.0),

            addButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FlowSpacing.md),
            addButton.centerYAnchor.constraint(equalTo: filterChips.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 44.0),
            addButton.heightAnchor.constraint(equalToConstant: 44.0),

            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: filterChips.bottomAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            noMatchState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            noMatchState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            noMatchState.topAnchor.constraint(equalTo: filterChips.bottomAnchor),
            noMatchState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72.0
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(NoteCell.self, forCellReuseIdentifier: NoteCell.reuseIdentifier)
        tableView.allowsMultipleSelectionDuringEditing = true
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: filterChips.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildSelectionBar() {
        selectionBar.translatesAutoresizingMaskIntoConstraints = false
        selectionBar.isHidden = true
        view.addSubview(selectionBar)

        selectionLabel.font = FlowTypography.titleSmall
        selectionLabel.translatesAutoresizingMaskIntoConstraints = false
        selectionBar.addSubview(selectionLabel)

        shareSelectedButton.translatesAutoresizingMaskIntoConstraints = false
        shareSelectedButton.onTap = { [weak self] in
            self?.shareSelected()
        }
        selectionBar.addSubview(shareSelectedButton)

        deleteSelectedButton.translatesAutoresizingMaskIntoConstraints = false
        deleteSelectedButton.onTap = { [weak self] in
            self?.deleteSelected()
        }
        selectionBar.addSubview(deleteSelectedButton)

        NSLayoutConstraint.activate([
            selectionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selectionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            selectionBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            selectionBar.heightAnchor.constraint(equalToConstant: 64.0),

            selectionLabel.leadingAnchor.constraint(equalTo: selectionBar.leadingAnchor, constant: FlowSpacing.xl),
            selectionLabel.centerYAnchor.constraint(equalTo: selectionBar.centerYAnchor),

            shareSelectedButton.trailingAnchor.constraint(equalTo: deleteSelectedButton.leadingAnchor, constant: -FlowSpacing.md),
            shareSelectedButton.centerYAnchor.constraint(equalTo: selectionBar.centerYAnchor),
            shareSelectedButton.widthAnchor.constraint(equalToConstant: 120.0),
            shareSelectedButton.heightAnchor.constraint(equalToConstant: 44.0),

            deleteSelectedButton.trailingAnchor.constraint(equalTo: selectionBar.trailingAnchor, constant: -FlowSpacing.xl),
            deleteSelectedButton.centerYAnchor.constraint(equalTo: selectionBar.centerYAnchor),
            deleteSelectedButton.widthAnchor.constraint(equalToConstant: 120.0),
            deleteSelectedButton.heightAnchor.constraint(equalToConstant: 44.0),
        ])
    }

    // MARK: - Data

    private func reload() {
        allNotes = FlowApp.shared.noteStore.all()
        applyFilter()
    }

    private func applyFilter() {
        let trimmed = query.trimmed
        var notes = allNotes
        switch filter {
        case .all:
            break
        case .videos:
            notes = notes.filter { $0.videoId.looksLikeVideoID }
        case .channels:
            notes = notes.filter { !$0.videoId.looksLikeVideoID }
        }
        if !trimmed.isEmpty {
            let terms = trimmed.lowercased().split(separator: " ").map { String($0) }
            notes = notes.filter { note in
                let haystack = (note.body + " " + note.videoTitle + " " + note.channelName).lowercased()
                return terms.allSatisfy { haystack.contains($0) }
            }
        }
        switch sort {
        case .recent:
            notes.sort { $0.updatedAt > $1.updatedAt }
        case .oldest:
            notes.sort { $0.updatedAt < $1.updatedAt }
        case .title:
            notes.sort {
                let left = ($0.videoTitle.isEmpty ? $0.body : $0.videoTitle).lowercased()
                let right = ($1.videoTitle.isEmpty ? $1.body : $1.videoTitle).lowercased()
                return left < right
            }
        case .custom:
            notes = NotesOrderStore.apply(to: notes)
        }
        visibleNotes = notes
        tableView.reloadData()
        updateEmptyStates()
        updateSelectionBar()
    }

    private func updateEmptyStates() {
        let hasAny = !allNotes.isEmpty
        emptyState.isHidden = hasAny || !visibleNotes.isEmpty
        noMatchState.isHidden = !hasAny || !visibleNotes.isEmpty
        tableView.isHidden = visibleNotes.isEmpty
        if !hasAny {
            emptyState.configure(
                kind: .custom(
                    icon: .notes,
                    title: "No notes yet",
                    message: "Add one from a video's Note button or a channel's subscribe menu. Times like 12:34 become links."
                ),
                actionTitle: "Add note"
            )
        }
    }

    private func updateSelectionBar() {
        selectionBar.isHidden = !isSelecting
        selectionLabel.text = selectedIds.isEmpty
            ? "Select notes"
            : String(selectedIds.count) + " selected"
        shareSelectedButton.isEnabled = !selectedIds.isEmpty
        deleteSelectedButton.isEnabled = !selectedIds.isEmpty
        shareSelectedButton.applyTheme()
        deleteSelectedButton.applyTheme()
        tableView.contentInset.bottom = isSelecting ? 64.0 : 0.0
        tableView.scrollIndicatorInsets.bottom = isSelecting ? 64.0 : 0.0
    }

    // MARK: - Actions

    @objc private func handleAdd() {
        presentEditor(note: nil)
    }

    @objc private func handleSelectMode() {
        if isSelecting {
            exitSelectionMode()
            return
        }
        if isReordering {
            setReordering(false)
        }
        isSelecting = true
        selectedIds.removeAll()
        selectButton.setIcon(.close)
        selectButton.accessibilityLabel = "Done selecting"
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.setEditing(true, animated: true)
        tableView.reloadData()
        updateSelectionBar()
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedIds.removeAll()
        selectButton.setIcon(.check)
        selectButton.accessibilityLabel = "Select notes"
        tableView.setEditing(false, animated: true)
        tableView.reloadData()
        updateSelectionBar()
    }

    @objc private func handleSort() {
        let actions = NotesSort.allCases.map { option in
            FlowActionSheetContent.Action(
                title: option.title,
                icon: option == sort ? .check : nil
            ) { [weak self] in
                guard let self = self else { return }
                self.sort = option
                self.applyFilter()
                if option == .custom {
                    self.promptReorder()
                }
            }
        }
        let content = FlowActionSheetContent(actions: actions)
        let sheet = FlowSheet(content: content, title: "Sort notes", detent: .medium, showsGrabber: true)
        content.onActionSelected = { [weak sheet] in
            sheet?.dismissSheet()
        }
        sheet.present(from: self)
    }

    private func promptReorder() {
        guard !isReordering else { return }
        let alert = UIAlertController(
            title: "Reorder notes",
            message: "Drag the handles to put the notes in the order you want.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Reorder", style: .default, handler: { [weak self] _ in
            self?.setReordering(true)
        }))
        present(alert, animated: true, completion: nil)
    }

    private func setReordering(_ reordering: Bool) {
        isReordering = reordering
        if reordering {
            if isSelecting {
                exitSelectionMode()
            }
            sort = .custom
            applyFilter()
        }
        tableView.setEditing(reordering, animated: true)
        tableView.reloadData()
        if reordering {
            FlowSnackbar.show("Drag to reorder", actionTitle: "Done") { [weak self] in
                self?.setReordering(false)
            }
        }
    }

    private func presentEditor(note: VideoNote?) {
        let content = NoteEditorContent()
        let playing = FlowApp.shared.playback.queue.current
        let targetId = note?.videoId ?? playing?.videoId ?? ""
        let timestamp = note?.timestamp ?? FlowApp.shared.playback.currentPosition
        content.configure(body: note?.body ?? "", targetId: targetId, timestamp: timestamp)
        let sheet = FlowSheet(
            content: content,
            title: note == nil ? "Add note" : "Edit note",
            detent: .large,
            showsGrabber: true
        )
        content.onCancel = { [weak sheet] in
            sheet?.dismissSheet()
        }
        content.onSave = { [weak self, weak sheet] targetId, body, timestamp in
            guard let self = self else { return }
            let store = FlowApp.shared.noteStore
            if let existing = note {
                store.update(id: existing.id, body: body)
                store.move(id: existing.id, to: timestamp)
                FlowSnackbar.show("Note saved")
            } else {
                guard !targetId.isEmpty else {
                    FlowSnackbar.showError("Choose a video or channel first")
                    return
                }
                let title = targetId == playing?.videoId ? (playing?.title ?? "") : ""
                let channel = targetId == playing?.videoId ? (playing?.channelName ?? "") : ""
                let created = store.create(
                    videoId: targetId,
                    videoTitle: title,
                    channelName: channel,
                    body: body,
                    timestamp: timestamp
                )
                if created == 0 {
                    FlowSnackbar.showError("The note could not be saved")
                    return
                }
                FlowSnackbar.show("Note added")
            }
            sheet?.dismissSheet()
            self.reload()
        }
        sheet.present(from: self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            content.focus()
        }
    }

    private func openDetail(_ note: VideoNote) {
        let content = NoteDetailContent()
        content.configure(note: note)
        let sheet = FlowSheet(content: content, title: "Note", detent: .large, showsGrabber: true)
        content.onPlay = { [weak self, weak sheet] position in
            sheet?.dismissSheet()
            self?.play(note: note, from: position)
        }
        content.onEdit = { [weak self, weak sheet] in
            sheet?.dismissSheet()
            self?.presentEditor(note: note)
        }
        content.onCopy = {
            UIPasteboard.general.string = note.body
            FlowSnackbar.show("Note copied")
        }
        content.onDelete = { [weak self, weak sheet] in
            sheet?.dismissSheet()
            self?.delete(note: note)
        }
        sheet.present(from: self)
    }

    private func play(note: VideoNote, from position: TimeInterval) {
        guard note.videoId.looksLikeVideoID else {
            onOpenChannel?(note.videoId)
            return
        }
        if let open = onOpenVideo {
            open(note.videoId, position)
            return
        }
        let service = FlowApp.shared.playback
        if service.queue.current?.videoId == note.videoId {
            service.seek(to: position)
            service.play()
        } else {
            service.load(videoId: note.videoId, autoplay: true) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        service.seek(to: position)
                    case .failure(let error):
                        FlowSnackbar.showError(error.displayMessage)
                    }
                }
            }
        }
    }

    private func delete(note: VideoNote) {
        FlowApp.shared.noteStore.delete(id: note.id)
        NotesOrderStore.remove(note.id)
        FlowSnackbar.show("Note deleted", actionTitle: "Undo") { [weak self] in
            FlowApp.shared.noteStore.create(
                videoId: note.videoId,
                videoTitle: note.videoTitle,
                channelName: note.channelName,
                body: note.body,
                timestamp: note.timestamp
            )
            self?.reload()
        }
        reload()
    }

    private func deleteSelected() {
        guard !selectedIds.isEmpty else { return }
        let removed = allNotes.filter { selectedIds.contains($0.id) }
        for note in removed {
            FlowApp.shared.noteStore.delete(id: note.id)
            NotesOrderStore.remove(note.id)
        }
        let count = removed.count
        exitSelectionMode()
        FlowSnackbar.show(
            count == 1 ? "1 note deleted" : String(count) + " notes deleted",
            actionTitle: "Undo"
        ) { [weak self] in
            for note in removed {
                FlowApp.shared.noteStore.create(
                    videoId: note.videoId,
                    videoTitle: note.videoTitle,
                    channelName: note.channelName,
                    body: note.body,
                    timestamp: note.timestamp
                )
            }
            self?.reload()
        }
        reload()
    }

    private func shareSelected() {
        let notes = allNotes.filter { selectedIds.contains($0.id) }
        guard !notes.isEmpty else { return }
        let text = Self.shareText(for: notes)
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = view
        activity.popoverPresentationController?.sourceRect = CGRect(
            x: view.bounds.midX,
            y: view.bounds.midY,
            width: 1.0,
            height: 1.0
        )
        present(activity, animated: true, completion: nil)
    }

    /// The notes as plain text: each one's title and link, then the note itself.
    static func shareText(for notes: [VideoNote]) -> String {
        return notes.map { note in
            let link: String
            if note.videoId.looksLikeVideoID {
                link = "https://www.youtube.com/watch?v=" + note.videoId
            } else {
                link = "https://www.youtube.com/channel/" + note.videoId
            }
            let title = note.videoTitle.isEmpty ? "Note" : note.videoTitle
            return [title, link, note.body].joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        tableView.backgroundColor = .clear
        tableView.separatorColor = scheme.outlineVariant
        searchBar.applyTheme()
        filterChips.applyTheme()
        sortButton.setIconColor(scheme.onSurface)
        selectButton.setIconColor(scheme.onSurface)
        addButton.setIconColor(scheme.onSurface)
        selectionBar.backgroundColor = scheme.surfaceContainer
        selectionLabel.textColor = scheme.onSurface
        shareSelectedButton.applyTheme()
        deleteSelectedButton.applyTheme()
        emptyState.applyTheme()
        noMatchState.applyTheme()
        tableView.reloadData()
    }
}

// MARK: - Data source

extension NotesViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return visibleNotes.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: NoteCell.reuseIdentifier, for: indexPath)
        guard let noteCell = cell as? NoteCell, let note = visibleNotes.element(at: indexPath.row) else {
            return cell
        }
        let isChannelNote = !note.videoId.looksLikeVideoID
        noteCell.configure(
            note: note,
            isChannelNote: isChannelNote,
            selecting: isSelecting,
            selected: selectedIds.contains(note.id)
        )
        return noteCell
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return isReordering
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard sourceIndexPath.row < visibleNotes.count else { return }
        var order = visibleNotes
        let moved = order.remove(at: sourceIndexPath.row)
        let target = min(destinationIndexPath.row, order.count)
        order.insert(moved, at: target)
        visibleNotes = order
        NotesOrderStore.save(order.map { $0.id })
        sort = .custom
    }

    func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, let note = visibleNotes.element(at: indexPath.row) else { return }
        delete(note: note)
    }
}

// MARK: - Delegate

extension NotesViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if isSelecting {
            guard let note = visibleNotes.element(at: indexPath.row) else { return }
            selectedIds.insert(note.id)
            tableView.reloadRows(at: [indexPath], with: .none)
            updateSelectionBar()
            return
        }
        if isReordering {
            tableView.deselectRow(at: indexPath, animated: true)
            return
        }
        tableView.deselectRow(at: indexPath, animated: true)
        guard let note = visibleNotes.element(at: indexPath.row) else { return }
        openDetail(note)
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard isSelecting, let note = visibleNotes.element(at: indexPath.row) else { return }
        selectedIds.remove(note.id)
        tableView.reloadRows(at: [indexPath], with: .none)
        updateSelectionBar()
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        return isSelecting ? .none : .delete
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        return false
    }

    func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        return proposedDestinationIndexPath
    }
}

// MARK: - Search bar

/// The notes search field: a rounded field with a magnifier and a clear button, matching the search
/// bar the other screens use rather than `UISearchController`'s unstylable field.
final class NotesSearchBar: UIView, UITextFieldDelegate {

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
        container.layer.cornerRadius = 22.0
        addSubview(container)

        icon.icon = .search
        icon.iconSize = 20.0
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20.0).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20.0).isActive = true
        container.addSubview(icon)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = FlowTypography.bodyLarge
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
            string: "Search notes",
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
