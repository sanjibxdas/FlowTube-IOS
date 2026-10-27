import UIKit

/// What the theme preference points at: a built-in palette, the active custom theme, or `system`
/// to follow the device's light and dark setting.
///
/// Stored by name, so a name is never reused or renamed; retired palettes are mapped in
/// `fromStored`. `light` and `oled` are older spellings of Flow Default's light and AMOLED styles.
enum ThemeMode: String, CaseIterable {
    case system
    case `default`
    case monochrome
    case catppuccin
    case greenApple = "green_apple"
    case lavender
    case nord
    case tako
    case yinYang = "yin_yang"
    case strawberryDaiquiri = "strawberry_daiquiri"
    case kanagawa
    case tokyoNight = "tokyo_night"
    case rosePine = "rose_pine"
    case everforest
    case gruvbox
    case dracula
    case solarized
    case tide
    case sage
    case caffeine
    case claude
    case deepOcean = "deep_ocean"
    case gunmetal
    case cosmicVoid = "cosmic_void"
    case cyberpunk
    case royalGold = "royal_gold"
    case creamPaper = "cream_paper"
    case materialYou = "material_you"
    case custom
    case light
    case oled

    /// Palettes retired when the catalogue moved to Flow Desktop's, and the palette and style each
    /// one lands on. Stored preferences and old backups still carry these names.
    private static let retired: [String: (ThemeMode, ThemeVariant)] = [
        "FOREST_GREEN": (.everforest, .dark),
        "SUNSET_ORANGE": (.claude, .dark),
        "PURPLE_NEBULA": (.cosmicVoid, .dark),
        "MIDNIGHT_BLACK": (.tide, .amoled),
        "ROSE_GOLD": (.strawberryDaiquiri, .dark),
        "ARCTIC_ICE": (.tide, .dark),
        "CRIMSON_RED": (.default, .dark),
        "MINTY_FRESH": (.tide, .dark),
        "SOLAR_FLARE": (.gruvbox, .dark),
        "ESPRESSO": (.caffeine, .dark),
        "MINT_LIGHT": (.tide, .light),
        "ROSE_LIGHT": (.strawberryDaiquiri, .light),
        "SKY_LIGHT": (.nord, .light),
    ]

    /// Every retired name, for the backup reader.
    static var retiredNames: Set<String> {
        return Set(retired.keys)
    }

    /// The mode a stored name means today, or nil for a name that never existed.
    static func fromStored(_ raw: String?) -> ThemeMode? {
        guard let text = raw, !text.isBlank else { return nil }
        if let retiredMatch = retired[text] { return retiredMatch.0 }
        if let exact = ThemeMode(rawValue: text) { return exact }
        // Older builds stored the Kotlin enum name, e.g. "GREEN_APPLE" or "DARK".
        let lowered = text.lowercased()
        for mode in ThemeMode.allCases where mode.rawValue == lowered {
            return mode
        }
        let legacy: [String: ThemeMode] = [
            "dark": .default,
            "light": .light,
            "oled": .oled,
            "lavender_mist": .lavender,
            "nordic_horizon": .nord,
            "ocean_blue": .deepOcean,
            "cream_light": .creamPaper,
            "material_you": .materialYou,
        ]
        return legacy[lowered]
    }

    /// The style a stored name implies, used only when no style was stored alongside it.
    static func storedDefaultVariant(_ raw: String?) -> ThemeVariant? {
        if let text = raw, let retiredMatch = retired[text] { return retiredMatch.1 }
        return fromStored(raw)?.defaultVariant
    }

    /// The variant this mode shows when the user has not overridden it.
    var defaultVariant: ThemeVariant {
        switch self {
        case .light, .creamPaper:
            return .light
        case .oled:
            return .amoled
        default:
            return .dark
        }
    }

    /// The palette family a mode belongs to. The legacy spellings fold into Flow Default.
    var canonicalFamily: ThemeMode {
        switch self {
        case .light, .oled:
            return .default
        default:
            return self
        }
    }

    /// Resolves `system` against the device's current appearance.
    func resolved(isSystemDark: Bool, systemLightMode: ThemeMode = .default, systemDarkMode: ThemeMode = .default) -> ThemeMode {
        if self != .system { return canonicalFamily }
        let selected = isSystemDark ? systemDarkMode : systemLightMode
        if selected == .system { return .default }
        return selected.canonicalFamily
    }

    /// Whether this mode paints dark surfaces right now.
    func isEffectivelyDark(isSystemDark: Bool, variant: ThemeVariant? = nil) -> Bool {
        if self == .system { return isSystemDark }
        if let explicit = variant { return explicit != .light }
        switch resolved(isSystemDark: isSystemDark) {
        case .light, .creamPaper:
            return false
        case .system, .materialYou:
            return isSystemDark
        default:
            return true
        }
    }

    /// The name shown in the theme picker. One place, so a palette is never called two things.
    var displayName: String {
        switch self {
        case .system: return "System Default"
        case .default: return "Flow Default"
        case .materialYou: return "Material You"
        case .monochrome: return "Monochrome"
        case .catppuccin: return "Catppuccin"
        case .greenApple: return "Green Apple"
        case .lavender: return "Lavender"
        case .nord: return "Nord"
        case .tako: return "Tako"
        case .yinYang: return "Yin & Yang"
        case .strawberryDaiquiri: return "Strawberry Daiquiri"
        case .kanagawa: return "Kanagawa"
        case .tokyoNight: return "Tokyo Night"
        case .rosePine: return "Rosé Pine"
        case .everforest: return "Everforest"
        case .gruvbox: return "Gruvbox"
        case .dracula: return "Dracula"
        case .solarized: return "Solarized"
        case .tide: return "Tide"
        case .sage: return "Sage"
        case .caffeine: return "Caffeine"
        case .claude: return "Claude"
        case .deepOcean: return "Deep Ocean"
        case .gunmetal: return "Gunmetal"
        case .cosmicVoid: return "Cosmic Void"
        case .cyberpunk: return "Cyberpunk"
        case .royalGold: return "Royal Gold"
        case .creamPaper: return "Cream Paper"
        case .custom: return "Custom"
        case .light: return "Pure Light"
        case .oled: return "True Black"
        }
    }

    /// The one-line description shown under the name in the picker.
    var summary: String {
        switch self {
        case .system: return "Follows your device between light and dark."
        case .default: return "The original Flow palette with the YouTube red accent."
        case .materialYou: return "Colours drawn from your wallpaper on Android 12 and newer."
        case .monochrome: return "A neutral, distraction-free palette with maximum clarity."
        case .catppuccin: return "Soothing pastel Latte and Mocha-inspired colors."
        case .greenApple: return "Fresh green accents with soft organic surfaces."
        case .lavender: return "Calm violet tones with gentle contrast."
        case .nord: return "An arctic, north-bluish palette."
        case .tako: return "Mihon-inspired purple with warm companion tones."
        case .yinYang: return "Balanced black and white in its purest form."
        case .strawberryDaiquiri: return "A bright berry palette with soft cream surfaces."
        case .kanagawa: return "Inky blues and warm lotus tones inspired by Hokusai."
        case .tokyoNight: return "Calm blue-violet colors drawn from the night city."
        case .rosePine: return "Natural pine, rose, and gold-tinted neutrals."
        case .everforest: return "A soft, low-contrast forest palette."
        case .gruvbox: return "Warm, earthy retro colors."
        case .dracula: return "The classic high-contrast purple palette."
        case .solarized: return "A precision low-glare blue and cyan palette."
        case .tide: return "Deep slate surfaces with muted teal."
        case .sage: return "Muted forest green that stays calm and soft."
        case .caffeine: return "Coffee tones balanced with cream and espresso."
        case .claude: return "Warm clay accents on paper-like surfaces."
        case .deepOcean: return "Calm blues drawn from deep water."
        case .gunmetal: return "Industrial greys with a cool metal edge."
        case .cosmicVoid: return "Near-black depths with electric violet."
        case .cyberpunk: return "Neon magenta and cyan for a future city."
        case .royalGold: return "Rich, prestigious golds on deep darks."
        case .creamPaper: return "Warm paper tones for cosy daytime reading."
        case .custom: return "Your own palette, with every colour editable."
        case .light: return "Clean & minimal"
        case .oled: return "Pure OLED"
        }
    }

    /// The palettes offered in the picker, in display order: Flow Desktop's catalogue with Material
    /// You after Flow Default, then the palettes only Android has so far.
    static var catalog: [ThemeMode] {
        return [
            .default, .materialYou, .monochrome, .catppuccin, .greenApple, .lavender, .nord,
            .tako, .yinYang, .strawberryDaiquiri, .kanagawa, .tokyoNight, .rosePine, .everforest,
            .gruvbox, .dracula, .solarized, .tide, .sage, .caffeine, .claude, .deepOcean,
            .gunmetal, .cosmicVoid, .cyberpunk, .royalGold, .creamPaper,
        ]
    }

    /// Modes that are not palettes and are offered as separate choices.
    static var extras: [ThemeMode] {
        return [.system, .light, .oled, .custom]
    }
}

// MARK: - Scheme

/// The full Material 3 role set the app paints with. Roles the thirteen authored colours have no
/// counterpart for are derived exactly as the Android `toColorScheme` derives them.
struct FlowColorScheme {
    let primary: UIColor
    let onPrimary: UIColor
    let primaryContainer: UIColor
    let onPrimaryContainer: UIColor
    let inversePrimary: UIColor
    let secondary: UIColor
    let onSecondary: UIColor
    let secondaryContainer: UIColor
    let onSecondaryContainer: UIColor
    let tertiary: UIColor
    let onTertiary: UIColor
    let tertiaryContainer: UIColor
    let onTertiaryContainer: UIColor
    let background: UIColor
    let onBackground: UIColor
    let surface: UIColor
    let onSurface: UIColor
    let surfaceVariant: UIColor
    let onSurfaceVariant: UIColor
    let surfaceTint: UIColor
    let inverseSurface: UIColor
    let inverseOnSurface: UIColor
    let error: UIColor
    let onError: UIColor
    let errorContainer: UIColor
    let onErrorContainer: UIColor
    let outline: UIColor
    let outlineVariant: UIColor
    let scrim: UIColor
    let surfaceBright: UIColor
    let surfaceDim: UIColor
    let surfaceContainerLowest: UIColor
    let surfaceContainerLow: UIColor
    let surfaceContainer: UIColor
    let surfaceContainerHigh: UIColor
    let surfaceContainerHighest: UIColor

    /// The thirteen authored roles, for the theme picker's preview swatches.
    let colors: PaletteColors

    /// Whether this scheme paints dark surfaces.
    let isDark: Bool

    /// The variant it was resolved for.
    let variant: ThemeVariant
}

extension PaletteColors {
    /// Builds the complete scheme for these roles. Containers are the accent washed into the
    /// surface and carry the surface's own text colour, so they keep the palette's contrast; the
    /// strong outline sits between the muted text and the divider colour so borders stay visible.
    func toColorScheme(variant: ThemeVariant) -> FlowColorScheme {
        let dark = variant != .light
        let ground = surface.opaqueOver(background.opaqueOver(dark ? UIColor.black : UIColor.white))
        let strongOutline = onSurfaceVariant.mixed(with: outline, amount: 0.6)
        let inversePrimary = primary.opaqueOver(ground).adjustedForContrast(against: onSurface.opaqueOver(ground), ratio: 4.5)
        return FlowColorScheme(
            primary: primary,
            onPrimary: onPrimary,
            primaryContainer: primary.mixed(with: surface, amount: dark ? 0.30 : 0.18),
            onPrimaryContainer: onSurface,
            inversePrimary: inversePrimary,
            secondary: secondary,
            onSecondary: secondary.opaqueOver(ground).readableContentColor,
            secondaryContainer: secondary.mixed(with: surface, amount: dark ? 0.26 : 0.16),
            onSecondaryContainer: onSurface,
            tertiary: secondary,
            onTertiary: secondary.opaqueOver(ground).readableContentColor,
            tertiaryContainer: secondary.mixed(with: surface, amount: dark ? 0.20 : 0.12),
            onTertiaryContainer: onSurface,
            background: background,
            onBackground: onSurface,
            surface: surface,
            onSurface: onSurface,
            surfaceVariant: surfaceContainerHighest,
            onSurfaceVariant: onSurfaceVariant,
            surfaceTint: primary,
            inverseSurface: onSurface,
            inverseOnSurface: surface,
            error: error,
            onError: error.opaqueOver(ground).readableContentColor,
            errorContainer: error.mixed(with: surface, amount: dark ? 0.24 : 0.14),
            onErrorContainer: onSurface,
            outline: strongOutline,
            outlineVariant: outline,
            scrim: UIColor.black,
            surfaceBright: dark ? surfaceContainerHighest : background,
            surfaceDim: dark ? background : surfaceContainerHigh,
            surfaceContainerLowest: background,
            surfaceContainerLow: surfaceContainerLow,
            surfaceContainer: surfaceContainer,
            surfaceContainerHigh: surfaceContainerHigh,
            surfaceContainerHighest: surfaceContainerHighest,
            colors: self,
            isDark: dark,
            variant: variant
        )
    }
}

// MARK: - Theme

/// The app's live theme. One instance lives on `FlowApp.shared`; every view reads colours from it
/// and listens for `flowThemeDidChange` so a palette switch repaints the whole app.
final class FlowTheme {

    static let shared = FlowTheme()

    /// The palette the user picked. `system` follows the device.
    private(set) var mode: ThemeMode = .default

    /// The style the user picked for that palette.
    private(set) var variant: ThemeVariant = .dark

    /// The user's custom palette, when `mode` is `.custom`.
    private(set) var customColors: PaletteColors?

    /// Whether the device is currently in dark mode, as far as the app is concerned.
    private(set) var systemIsDark: Bool = true

    /// The resolved scheme every view paints with.
    private(set) var scheme: FlowColorScheme

    /// The font family choice, applied by `FlowTypography`.
    private(set) var fontChoice: FlowFontChoice = .system

    private init() {
        scheme = FlowPalettes.default.colors(for: .dark).toColorScheme(variant: .dark)
    }

    // MARK: Resolution

    /// The palette and variant in effect right now, after resolving `system`.
    var effectiveSlot: (mode: ThemeMode, variant: ThemeVariant) {
        if mode == .system {
            return (.default, systemIsDark ? .dark : .light)
        }
        return (mode.canonicalFamily, variant)
    }

    /// Recomputes the scheme from the current inputs and broadcasts the change.
    func refresh(notify: Bool = true) {
        let slot = effectiveSlot
        let colors: PaletteColors
        if slot.mode == .custom, let custom = customColors {
            colors = custom
        } else {
            colors = FlowPalettes.pair(for: slot.mode).colors(for: slot.variant)
        }
        scheme = colors.toColorScheme(variant: slot.variant)
        if notify {
            FlowEventBus.shared.broadcast("theme", notification: .flowThemeDidChange, payload: scheme)
        }
    }

    /// Applies a palette choice.
    func apply(mode newMode: ThemeMode) {
        mode = newMode
        variant = newMode.defaultVariant
        refresh()
    }

    /// Applies a palette and an explicit light/dark/AMOLED style.
    func apply(mode newMode: ThemeMode, variant newVariant: ThemeVariant) {
        mode = newMode
        variant = newVariant
        refresh()
    }

    /// Applies a user-authored palette.
    func applyCustom(_ colors: PaletteColors, variant newVariant: ThemeVariant) {
        customColors = colors
        mode = .custom
        variant = newVariant
        refresh()
    }

    /// Follows the device appearance. Called on launch and when `traitCollectionDidChange` reports a
    /// different `userInterfaceStyle`.
    func updateSystemAppearance(isDark: Bool) {
        guard isDark != systemIsDark else { return }
        systemIsDark = isDark
        if mode == .system {
            refresh()
        }
    }

    /// Sets the font choice and repaints.
    func applyFont(_ choice: FlowFontChoice) {
        fontChoice = choice
        FlowTypography.activeChoice = choice
        FlowEventBus.shared.broadcast("theme", notification: .flowThemeDidChange, payload: scheme)
    }

    /// Restores the persisted theme choice. Called once from `FlowApp.bootstrap()`.
    func restore(from prefs: PrefsStore) {
        // `UITraitCollection.current` is iOS 13; the screen's traits carry the same interface
        // style on iOS 12, and `restore` runs on the main thread before any window is shown.
        systemIsDark = UIScreen.main.traitCollection.userInterfaceStyle != .light
        let storedMode = ThemeMode.fromStored(prefs.string(for: PrefsStore.Key.themeMode)) ?? .default
        let storedVariant = prefs.string(for: PrefsStore.Key.themeVariant).flatMap(ThemeVariant.init(rawValue:))
        mode = storedMode
        variant = storedVariant ?? storedMode.defaultVariant
        if let custom = prefs.customPalette() {
            customColors = custom
        }
        fontChoice = FlowFontChoice(rawValue: prefs.string(for: PrefsStore.Key.fontFamily) ?? "") ?? .system
        FlowTypography.activeChoice = fontChoice
        refresh(notify: false)
    }

    /// Persists the current choice. Called by the appearance settings screen.
    func persist(to prefs: PrefsStore) {
        prefs.set(mode.rawValue, for: PrefsStore.Key.themeMode)
        prefs.set(variant.rawValue, for: PrefsStore.Key.themeVariant)
        prefs.set(fontChoice.rawValue, for: PrefsStore.Key.fontFamily)
        if let custom = customColors {
            prefs.setCustomPalette(custom)
        }
    }

    // MARK: Convenience

    var background: UIColor { return scheme.background }
    var surface: UIColor { return scheme.surface }
    var onSurface: UIColor { return scheme.onSurface }
    var onSurfaceVariant: UIColor { return scheme.onSurfaceVariant }
    var primary: UIColor { return scheme.primary }
    var onPrimary: UIColor { return scheme.onPrimary }
    var outline: UIColor { return scheme.outline }
    var outlineVariant: UIColor { return scheme.outlineVariant }
    var error: UIColor { return scheme.error }
    var secondary: UIColor { return scheme.secondary }
    var isDark: Bool { return scheme.isDark }

    /// The colour a snackbar action uses, toned until it reads on the inverse surface.
    var snackbarAction: UIColor { return scheme.inversePrimary }

    /// YouTube's brand red, for marks that stay red in every theme.
    static let youtubeRed = UIColor(hex: 0xFF0000)

    /// The link colour the description panel uses when it is not following the theme primary.
    static let descriptionLinkBlue = UIColor(hex: 0x3EA6FF)

    /// The red used for the Shorts glyph in every theme.
    var shortsAccent: UIColor { return FlowTheme.youtubeRed }
}

// MARK: - Motion

/// The two durations and curves the app animates with. Material 3's standard and emphasized
/// motion, expressed as UIKit animation options.
enum FlowMotion {
    /// 200 ms, ease-out. The default for state changes and small movements.
    static let standard: TimeInterval = 0.2
    /// 300 ms, ease-in-out. For sheets, player transitions and anything that moves a whole surface.
    static let emphasized: TimeInterval = 0.3
    /// 120 ms, linear. For colour and alpha fades that should not draw attention.
    static let quick: TimeInterval = 0.12

    static let standardCurve: UIView.AnimationOptions = [.curveEaseOut]
    static let emphasizedCurve: UIView.AnimationOptions = [.curveEaseInOut]

    /// Runs a standard animation, honouring Reduce Motion.
    static func animate(_ animations: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
        if UIAccessibility.isReduceMotionEnabled {
            animations()
            completion?(true)
            return
        }
        UIView.animate(withDuration: standard, delay: 0.0, options: standardCurve, animations: animations, completion: completion)
    }

    /// Runs an emphasized animation, honouring Reduce Motion.
    static func animateEmphasized(_ animations: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
        if UIAccessibility.isReduceMotionEnabled {
            animations()
            completion?(true)
            return
        }
        UIView.animate(withDuration: emphasized, delay: 0.0, options: emphasizedCurve, animations: animations, completion: completion)
    }
}
