import UIKit

/// The equalizer sheet.
///
/// Five bands with adjustable gain and Q, a preamp, and the built-in presets. Every change is
/// written to `AudioEngine` as it happens and pushed into the playing item's audio mix, so a slider
/// move is audible while the finger is still on it rather than after a commit.
///
/// The curve at the top is drawn from the band gains on a logarithmic frequency axis — the same
/// shape the audio takes. It is a reading aid, not a second source of truth.
final class EqualizerViewController: PlaybackSheetController {

    // MARK: - Dependencies

    private let engine = AudioEngine.shared
    private let service: PlaybackService
    private let bag = ObservationBag()

    // MARK: - Views

    private let titleLabel = UILabel()
    private let closeButton = FlowIconButton()
    private let enabledSwitch = UISwitch()
    private let curveView = EqCurveView()
    private let presetChips = FlowChipRow()
    private let resetButton = FlowButton.make("Reset", style: .text, icon: .sync)
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let preampRow = EqSliderRow(
        title: "Preamp",
        range: -Float(AudioEngine.maximumPreamp)...Float(AudioEngine.maximumPreamp)
    )
    private var bandRows: [EqBandRowView] = []
    private let footerLabel = UILabel()

    // MARK: - State

    /// Guards against the engine's change notification rebuilding the controls that caused it.
    private var isApplying = false
    /// The engine's previous change handler, restored when the sheet goes away.
    private var previousOnChange: (() -> Void)?

    override var sheetHeightFraction: CGFloat {
        return 0.94
    }

    // MARK: - Init

    init(service: PlaybackService = .shared) {
        self.service = service
        super.init()
    }

    required init?(coder: NSCoder) {
        service = .shared
        super.init(coder: coder)
    }

    deinit {
        bag.cancelAll()
        engine.onChange = previousOnChange
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildHeader()
        buildScrollView()
        buildCurve()
        buildPresets()
        buildBands()
        buildPreamp()
        buildFooter()
        observe()
        applyTheme()
        reload()
    }

    // MARK: - Construction

    private func buildHeader() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleLarge
        titleLabel.text = "Equalizer"
        contentView.addSubview(titleLabel)

        closeButton.configure(icon: .close, color: FlowTheme.shared.onSurfaceVariant, size: 20.0)
        closeButton.accessibilityLabel = "Close"
        closeButton.addClosureActionForControl(for: .touchUpInside) { [weak self] in
            self?.dismissSheet()
        }
        contentView.addSubviewForAutoLayout(closeButton)

        enabledSwitch.translatesAutoresizingMaskIntoConstraints = false
        enabledSwitch.accessibilityLabel = "Equalizer enabled"
        enabledSwitch.addTarget(self, action: #selector(enabledChanged), for: .valueChanged)
        contentView.addSubview(enabledSwitch)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.xl),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.xs),

            enabledSwitch.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -FlowSpacing.sm),
            enabledSwitch.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.md),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44.0),
            closeButton.heightAnchor.constraint(equalToConstant: 44.0),
        ])
    }

    private func buildScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag
        contentView.addSubview(scrollView)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = FlowSpacing.lg
        stack.alignment = .fill
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.md),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: FlowSpacing.xl),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -FlowSpacing.xl),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: FlowSpacing.xs),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -FlowSpacing.xxl),
        ])
    }

    private func buildCurve() {
        curveView.heightAnchor.constraint(equalToConstant: 132.0).isActive = true
        stack.addArrangedSubview(curveView)
    }

    private func buildPresets() {
        stack.addArrangedSubview(makeSectionHeader("Presets"))

        presetChips.setTitles(AudioEngine.presets.map { $0.name }, selectedIndex: selectedPresetIndex())
        presetChips.onSelect = { [weak self] index in
            guard let self = self, let preset = AudioEngine.presets.element(at: index) else { return }
            self.engine.apply(preset)
            self.service.refreshEqualizer()
            self.reload()
        }
        stack.addArrangedSubview(presetChips)
    }

    private func buildBands() {
        stack.addArrangedSubview(makeSectionHeader("Bands"))
        bandRows = []
        for (index, band) in engine.bands.enumerated() {
            let row = EqBandRowView(band: band)
            row.onGainChange = { [weak self] gain in
                guard let self = self, !self.isApplying else { return }
                self.engine.setGain(Double(gain), at: index)
                self.service.refreshEqualizer()
                self.refreshCurve()
            }
            row.onQChange = { [weak self] q in
                guard let self = self, !self.isApplying else { return }
                var updated = self.engine.bands.element(at: index) ?? band
                updated.q = Double(q)
                self.engine.setBand(at: index, band: updated)
                self.service.refreshEqualizer()
                self.refreshCurve()
            }
            row.onToggle = { [weak self] enabled in
                guard let self = self, !self.isApplying else { return }
                var updated = self.engine.bands.element(at: index) ?? band
                updated.enabled = enabled
                self.engine.setBand(at: index, band: updated)
                self.service.refreshEqualizer()
                self.refreshCurve()
            }
            bandRows.append(row)
            stack.addArrangedSubview(row)
        }
    }

    private func buildPreamp() {
        stack.addArrangedSubview(makeSectionHeader("Output"))

        preampRow.onChange = { [weak self] value in
            guard let self = self, !self.isApplying else { return }
            self.engine.setPreamp(Double(value))
            self.service.refreshEqualizer()
        }
        stack.addArrangedSubview(preampRow)

        resetButton.onTap = { [weak self] in
            guard let self = self else { return }
            self.engine.reset()
            self.service.refreshEqualizer()
            self.reload()
        }
        stack.addArrangedSubview(resetButton)
    }

    private func buildFooter() {
        footerLabel.font = FlowTypography.bodySmall
        footerLabel.numberOfLines = 0
        stack.addArrangedSubview(footerLabel)
    }

    private func makeSectionHeader(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = FlowTypography.labelLargeEmphasized
        label.text = text
        label.textColor = FlowTheme.shared.onSurfaceVariant
        return label
    }

    // MARK: - Observation

    private func observe() {
        // The engine has a single change handler. Take it over and chain to whatever was there, so
        // the sheet can be opened more than once without losing an earlier listener.
        previousOnChange = engine.onChange
        let previous = previousOnChange
        engine.onChange = { [weak self] in
            previous?()
            self?.reload()
        }
        bag.add(FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        })
    }

    /// Reads the engine back into the controls.
    private func reload() {
        isApplying = true
        defer { isApplying = false }

        enabledSwitch.isOn = engine.isEnabled

        let bands = engine.bands
        for (index, row) in bandRows.enumerated() {
            guard let band = bands.element(at: index) else { continue }
            row.update(band: band)
        }

        preampRow.value = Float(engine.preamp)
        let selected = selectedPresetIndex()
        for (index, chip) in presetChips.chips.enumerated() {
            chip.setSelected(index == selected)
        }

        curveView.setBands(bands, enabled: engine.isEnabled)

        if engine.presetId == AudioEngine.customPresetId {
            footerLabel.text = "Custom curve. Pick a preset to start again from a known shape."
        } else {
            footerLabel.text = "The equalizer runs on the player's decoded audio through a processing tap, "
                + "so it applies to every stream and every downloaded file."
        }
    }

    private func refreshCurve() {
        curveView.setBands(engine.bands, enabled: engine.isEnabled)
    }

    /// The index of the preset the engine is on, or −1 for a hand-made curve.
    private func selectedPresetIndex() -> Int {
        if let match = AudioEngine.presets.firstIndex(where: { $0.id == engine.presetId }) {
            return match
        }
        let bands = engine.bands
        let preamp = engine.preamp
        return AudioEngine.presets.firstIndex(where: { preset in
            guard abs(preset.preamp - preamp) < 0.05 else { return false }
            for (index, band) in bands.enumerated() {
                let target = preset.gains.element(at: index) ?? 0.0
                if abs(band.gain - target) > 0.05 { return false }
            }
            return true
        }) ?? -1
    }

    @objc private func enabledChanged() {
        guard !isApplying else { return }
        engine.setEnabled(enabledSwitch.isOn)
        service.refreshEqualizer()
        refreshCurve()
    }

    override func applyTheme() {
        super.applyTheme()
        let scheme = FlowTheme.shared.scheme
        titleLabel.textColor = scheme.onSurface
        closeButton.setIconColor(scheme.onSurfaceVariant)
        enabledSwitch.onTintColor = scheme.primary
        footerLabel.textColor = scheme.onSurfaceVariant
        resetButton.applyTheme()
        presetChips.applyTheme()
        for row in bandRows {
            row.applyTheme()
        }
        preampRow.applyTheme()
        curveView.applyTheme()
    }
}

// MARK: - Band row

/// One band: its frequency, a gain slider, a Q slider, and a switch that bypasses it.
final class EqBandRowView: UIView {

    private let toggle = UISwitch()
    private let frequencyLabel = UILabel()
    private let gainLabel = UILabel()
    private let qLabel = UILabel()
    private let gainSlider = UISlider()
    private let qSlider = UISlider()

    /// Called with the new gain in decibels.
    var onGainChange: ((Float) -> Void)?
    /// Called with the new Q.
    var onQChange: ((Float) -> Void)?
    /// Called with the new enabled state.
    var onToggle: ((Bool) -> Void)?

    init(band: EqBand) {
        super.init(frame: .zero)
        build()
        update(band: band)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = FlowShapes.medium
        layer.masksToBounds = true

        frequencyLabel.translatesAutoresizingMaskIntoConstraints = false
        frequencyLabel.font = FlowTypography.titleSmallEmphasized
        addSubview(frequencyLabel)

        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.accessibilityLabel = "Band enabled"
        toggle.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
        addSubview(toggle)

        gainLabel.translatesAutoresizingMaskIntoConstraints = false
        gainLabel.font = FlowTypography.labelMedium
        gainLabel.textAlignment = .right
        addSubview(gainLabel)

        gainSlider.translatesAutoresizingMaskIntoConstraints = false
        gainSlider.minimumValue = -Float(AudioEngine.maximumGain)
        gainSlider.maximumValue = Float(AudioEngine.maximumGain)
        gainSlider.accessibilityLabel = "Gain"
        gainSlider.addTarget(self, action: #selector(gainChanged), for: .valueChanged)
        addSubview(gainSlider)

        qLabel.translatesAutoresizingMaskIntoConstraints = false
        qLabel.font = FlowTypography.labelSmall
        qLabel.textAlignment = .right
        addSubview(qLabel)

        qSlider.translatesAutoresizingMaskIntoConstraints = false
        qSlider.minimumValue = Float(AudioEngine.minimumQ)
        qSlider.maximumValue = Float(AudioEngine.maximumQ)
        qSlider.accessibilityLabel = "Bandwidth"
        qSlider.addTarget(self, action: #selector(qChanged), for: .valueChanged)
        addSubview(qSlider)

        NSLayoutConstraint.activate([
            frequencyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.lg),
            frequencyLabel.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.md),

            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.md),
            toggle.centerYAnchor.constraint(equalTo: frequencyLabel.centerYAnchor),

            gainLabel.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -FlowSpacing.sm),
            gainLabel.centerYAnchor.constraint(equalTo: frequencyLabel.centerYAnchor),
            gainLabel.widthAnchor.constraint(equalToConstant: 64.0),

            gainSlider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.lg),
            gainSlider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.lg),
            gainSlider.topAnchor.constraint(equalTo: frequencyLabel.bottomAnchor, constant: FlowSpacing.xs),

            qLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.lg),
            qLabel.centerYAnchor.constraint(equalTo: qSlider.centerYAnchor),
            qLabel.widthAnchor.constraint(equalToConstant: 64.0),

            qSlider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.lg),
            qSlider.trailingAnchor.constraint(equalTo: qLabel.leadingAnchor, constant: -FlowSpacing.md),
            qSlider.topAnchor.constraint(equalTo: gainSlider.bottomAnchor, constant: -FlowSpacing.xxs),
            qSlider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.md),
        ])
        applyTheme()
    }

    /// Sets the controls from a band without notifying the owner.
    func update(band: EqBand) {
        frequencyLabel.text = EqBandRowView.frequencyText(band.frequency)
        gainSlider.value = Float(band.gain)
        gainLabel.text = EqBandRowView.gainText(band.gain)
        qSlider.value = Float(band.q)
        qLabel.text = EqBandRowView.qText(band.q)
        toggle.isOn = band.enabled

        let alpha: CGFloat = band.enabled ? 1.0 : 0.45
        gainSlider.alpha = alpha
        qSlider.alpha = alpha
        gainLabel.alpha = alpha
        qLabel.alpha = alpha
        accessibilityLabel = "\(frequencyLabel.text ?? ""), \(gainLabel.text ?? "")"
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        backgroundColor = scheme.surfaceContainerHigh
        frequencyLabel.textColor = scheme.onSurface
        gainLabel.textColor = scheme.onSurfaceVariant
        qLabel.textColor = scheme.onSurfaceVariant
        gainSlider.minimumTrackTintColor = scheme.primary
        gainSlider.maximumTrackTintColor = scheme.outlineVariant
        qSlider.minimumTrackTintColor = scheme.secondary
        qSlider.maximumTrackTintColor = scheme.outlineVariant
        toggle.onTintColor = scheme.primary
    }

    @objc private func gainChanged() {
        gainLabel.text = EqBandRowView.gainText(Double(gainSlider.value))
        onGainChange?(gainSlider.value)
    }

    @objc private func qChanged() {
        qLabel.text = EqBandRowView.qText(Double(qSlider.value))
        onQChange?(qSlider.value)
    }

    @objc private func toggleChanged() {
        onToggle?(toggle.isOn)
    }

    /// "60 Hz", "1.4 kHz".
    static func frequencyText(_ frequency: Double) -> String {
        if frequency >= 1_000.0 {
            let kilo = frequency / 1_000.0
            if abs(kilo - kilo.rounded()) < 0.05 {
                return String(format: "%.0f kHz", kilo)
            }
            return String(format: "%.1f kHz", kilo)
        }
        return String(format: "%.0f Hz", frequency)
    }

    /// "+3.0 dB", "0.0 dB", "−4.5 dB".
    static func gainText(_ gain: Double) -> String {
        let sign = gain > 0.05 ? "+" : (gain < -0.05 ? "\u{2212}" : "")
        return String(format: "%@%.1f dB", sign, abs(gain))
    }

    /// "Q 1.41".
    static func qText(_ q: Double) -> String {
        return String(format: "Q %.2f", q)
    }
}

// MARK: - Slider row

/// A labelled slider, used for the preamp.
final class EqSliderRow: UIView {

    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let slider = UISlider()
    private let range: ClosedRange<Float>

    /// Called with the new value.
    var onChange: ((Float) -> Void)?

    var value: Float {
        get { return slider.value }
        set {
            slider.value = newValue
            valueLabel.text = EqBandRowView.gainText(Double(newValue))
        }
    }

    init(title: String, range: ClosedRange<Float>) {
        self.range = range
        super.init(frame: .zero)
        build(title: title)
    }

    required init?(coder: NSCoder) {
        range = -Float(AudioEngine.maximumPreamp)...Float(AudioEngine.maximumPreamp)
        super.init(coder: coder)
        build(title: "")
    }

    private func build(title: String) {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = FlowShapes.medium
        layer.masksToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.bodyLarge
        titleLabel.text = title
        addSubview(titleLabel)

        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = FlowTypography.labelMedium
        valueLabel.textAlignment = .right
        addSubview(valueLabel)

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumValue = range.lowerBound
        slider.maximumValue = range.upperBound
        slider.addTarget(self, action: #selector(changed), for: .valueChanged)
        slider.accessibilityLabel = title
        addSubview(slider)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.lg),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.md),

            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.lg),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 72.0),

            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.lg),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.lg),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: FlowSpacing.xs),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FlowSpacing.lg),
        ])
        applyTheme()
        value = 0.0
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        backgroundColor = scheme.surfaceContainerHigh
        titleLabel.textColor = scheme.onSurface
        valueLabel.textColor = scheme.onSurfaceVariant
        slider.minimumTrackTintColor = scheme.primary
        slider.maximumTrackTintColor = scheme.outlineVariant
    }

    @objc private func changed() {
        valueLabel.text = EqBandRowView.gainText(Double(slider.value))
        onChange?(slider.value)
    }
}

// MARK: - Curve

/// The response curve: the band gains joined on a logarithmic frequency axis, with a zero line and
/// a faint grid. It redraws when the bands change and dims when the equalizer is off.
final class EqCurveView: UIView {

    private var bands: [EqBand] = []
    private var isEnabled = true
    private let gridLayer = CAShapeLayer()
    private let zeroLayer = CAShapeLayer()
    private let curveLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()

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
        layer.cornerRadius = FlowShapes.medium
        layer.masksToBounds = true

        for shape in [gridLayer, zeroLayer, fillLayer, curveLayer] {
            shape.fillColor = UIColor.clear.cgColor
            layer.addSublayer(shape)
        }
        curveLayer.lineWidth = 2.5
        curveLayer.lineJoin = .round
        curveLayer.lineCap = .round
        zeroLayer.lineWidth = 1.0
        gridLayer.lineWidth = 1.0
        applyTheme()
    }

    /// Sets the curve's bands.
    func setBands(_ bands: [EqBand], enabled: Bool) {
        self.bands = bands
        isEnabled = enabled
        setNeedsLayout()
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        backgroundColor = scheme.surfaceContainerHigh
        gridLayer.strokeColor = scheme.outlineVariant.withAlpha(0.5).cgColor
        zeroLayer.strokeColor = scheme.outline.withAlpha(0.7).cgColor
        curveLayer.strokeColor = scheme.primary.cgColor
        fillLayer.fillColor = scheme.primary.withAlpha(0.16).cgColor
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0.0, bounds.height > 0.0 else { return }
        let plot = bounds.inset(by: UIEdgeInsets(top: 12.0, left: 12.0, bottom: 12.0, right: 12.0))

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        gridLayer.frame = bounds
        zeroLayer.frame = bounds
        curveLayer.frame = bounds
        fillLayer.frame = bounds

        let grid = UIBezierPath()
        for step in 0...4 {
            let x = plot.minX + plot.width * CGFloat(step) / 4.0
            grid.move(to: CGPoint(x: x, y: plot.minY))
            grid.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        gridLayer.path = grid.cgPath

        let zeroY = y(forGain: 0.0, in: plot)
        let zero = UIBezierPath()
        zero.move(to: CGPoint(x: plot.minX, y: zeroY))
        zero.addLine(to: CGPoint(x: plot.maxX, y: zeroY))
        zeroLayer.path = zero.cgPath

        let points = curvePoints(in: plot)
        guard let first = points.first else {
            curveLayer.path = nil
            fillLayer.path = nil
            CATransaction.commit()
            return
        }

        let curve = UIBezierPath()
        let fill = UIBezierPath()
        fill.move(to: CGPoint(x: first.x, y: zeroY))
        curve.move(to: first)
        fill.addLine(to: first)
        for point in points.dropFirst() {
            curve.addLine(to: point)
            fill.addLine(to: point)
        }
        if let last = points.last {
            fill.addLine(to: CGPoint(x: last.x, y: zeroY))
        }
        fill.close()

        curveLayer.path = curve.cgPath
        fillLayer.path = fill.cgPath
        curveLayer.opacity = isEnabled ? 1.0 : 0.35
        fillLayer.opacity = isEnabled ? 1.0 : 0.35
        CATransaction.commit()
    }

    /// The curve's samples: 48 points across the log axis, interpolated between the bands.
    private func curvePoints(in plot: CGRect) -> [CGPoint] {
        guard !bands.isEmpty else { return [] }
        let minimum = log10(AudioEngine.minimumFrequency)
        let maximum = log10(AudioEngine.maximumFrequency)
        let sampleCount = 48
        var points: [CGPoint] = []
        for step in 0...sampleCount {
            let fraction = Double(step) / Double(sampleCount)
            let frequency = pow(10.0, minimum + (maximum - minimum) * fraction)
            let gain = interpolatedGain(at: frequency)
            let x = plot.minX + plot.width * CGFloat(fraction)
            points.append(CGPoint(x: x, y: y(forGain: gain, in: plot)))
        }
        return points
    }

    /// The gain at `frequency`, read off the straight line between the two neighbouring bands on
    /// the log axis. A band that is switched off contributes nothing.
    private func interpolatedGain(at frequency: Double) -> Double {
        let sorted = bands.filter { $0.enabled }.sorted { $0.frequency < $1.frequency }
        guard let first = sorted.first, let last = sorted.last else { return 0.0 }
        if frequency <= first.frequency { return first.gain }
        if frequency >= last.frequency { return last.gain }
        for index in 0..<(sorted.count - 1) {
            let lower = sorted[index]
            let upper = sorted[index + 1]
            guard frequency >= lower.frequency, frequency <= upper.frequency else { continue }
            let span = log10(upper.frequency) - log10(lower.frequency)
            guard span > 0.0 else { return lower.gain }
            let position = (log10(frequency) - log10(lower.frequency)) / span
            return lower.gain + (upper.gain - lower.gain) * position
        }
        return 0.0
    }

    private func y(forGain gain: Double, in plot: CGRect) -> CGFloat {
        let clamped = min(max(gain, -AudioEngine.maximumGain), AudioEngine.maximumGain)
        let fraction = (AudioEngine.maximumGain - clamped) / (AudioEngine.maximumGain * 2.0)
        return plot.minY + plot.height * CGFloat(fraction)
    }
}
