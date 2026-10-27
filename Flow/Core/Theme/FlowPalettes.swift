import UIKit

/// Which of a palette's authored variants is on screen. AMOLED keeps the dark accents on a fixed
/// near-black surface ladder, exactly as the Android app's `ThemeVariant.AMOLED` does.
enum ThemeVariant: String, CaseIterable {
    case light
    case dark
    case amoled

    var isDark: Bool {
        return self != .light
    }
}

/// The nine colours a palette is authored with, per light or dark variant, as in Flow Desktop.
struct PaletteSeed {
    let primary: UIColor
    let onPrimary: UIColor
    let secondary: UIColor
    let background: UIColor
    let surface: UIColor
    let onSurface: UIColor
    let onSurfaceVariant: UIColor
    let outline: UIColor
    let error: UIColor
}

/// The thirteen roles one variant of a theme resolves to — the same set Flow Desktop's
/// `ThemeColors` holds, so a custom theme moves between the two apps role for role.
struct PaletteColors {
    let primary: UIColor
    let onPrimary: UIColor
    let secondary: UIColor
    let background: UIColor
    let surface: UIColor
    let surfaceContainerLow: UIColor
    let surfaceContainer: UIColor
    let surfaceContainerHigh: UIColor
    let surfaceContainerHighest: UIColor
    let outline: UIColor
    let onSurface: UIColor
    let onSurfaceVariant: UIColor
    let error: UIColor
}

/// A built-in palette: its Flow Desktop id and its two authored variants.
struct PalettePair {
    let id: String
    let light: PaletteSeed
    let dark: PaletteSeed

    /// The thirteen roles for `variant`. AMOLED derives from the dark seed.
    func colors(for variant: ThemeVariant) -> PaletteColors {
        switch variant {
        case .light:
            return light.expanded(variant: .light)
        case .dark, .amoled:
            return dark.expanded(variant: variant)
        }
    }
}

// MARK: - Expansion

enum AmoledLadder {
    static let background = UIColor(hex: 0x000000)
    static let surface = UIColor(hex: 0x080808)
    static let surfaceContainerLow = UIColor(hex: 0x050505)
    static let surfaceContainer = UIColor(hex: 0x0C0C0C)
    static let surfaceContainerHigh = UIColor(hex: 0x141414)
    static let surfaceContainerHighest = UIColor(hex: 0x1C1C1C)
}

extension PaletteSeed {
    /// Flow Desktop's `expandPalette`: the container ladder blends the text colour into the surface,
    /// so each step always stands apart from the surface whatever the palette's tint.
    func expanded(variant: ThemeVariant) -> PaletteColors {
        if variant == .amoled {
            return PaletteColors(
                primary: primary,
                onPrimary: onPrimary,
                secondary: secondary,
                background: AmoledLadder.background,
                surface: AmoledLadder.surface,
                surfaceContainerLow: AmoledLadder.surfaceContainerLow,
                surfaceContainer: AmoledLadder.surfaceContainer,
                surfaceContainerHigh: AmoledLadder.surfaceContainerHigh,
                surfaceContainerHighest: AmoledLadder.surfaceContainerHighest,
                outline: outline,
                onSurface: onSurface,
                onSurfaceVariant: onSurfaceVariant,
                error: error
            )
        }
        let dark = variant == .dark
        return PaletteColors(
            primary: primary,
            onPrimary: onPrimary,
            secondary: secondary,
            background: background,
            surface: surface,
            surfaceContainerLow: surface.mixed(with: background, amount: dark ? 0.72 : 0.58),
            surfaceContainer: surface,
            surfaceContainerHigh: onSurface.mixed(with: surface, amount: dark ? 0.09 : 0.07),
            surfaceContainerHighest: onSurface.mixed(with: surface, amount: dark ? 0.14 : 0.11),
            outline: outline,
            onSurface: onSurface,
            onSurfaceVariant: onSurfaceVariant,
            error: error
        )
    }
}

// MARK: - Catalog

/// Every built-in palette with its two authored variants, transcribed role for role from the
/// Android `FlowPalettes.kt`. Several keep their original id so a stored choice survives an update:
/// `default` is Flow Default, `lavender` is Lavender, `nord` is Nord, `deep-ocean` is Deep Ocean
/// and `cream-paper` is Cream Paper.
enum FlowPalettes {

    static let all: [ThemeMode: PalettePair] = [
        .default: PalettePair(
            id: "default",
            light: PaletteSeed(
                primary: UIColor(hex: 0xFF0000),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x606060),
                background: UIColor(hex: 0xFFFFFF),
                surface: UIColor(hex: 0xF3F3F3),
                onSurface: UIColor(hex: 0x111111),
                onSurfaceVariant: UIColor(hex: 0x5F5F5F),
                outline: UIColor(hex: 0xD7D7D7),
                error: UIColor(hex: 0xD32F2F)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xFF0000),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0xAAAAAA),
                background: UIColor(hex: 0x0F0F0F),
                surface: UIColor(hex: 0x1D1D1D),
                onSurface: UIColor(hex: 0xF4F4F4),
                onSurfaceVariant: UIColor(hex: 0xB8B8B8),
                outline: UIColor(hex: 0x343434),
                error: UIColor(hex: 0xEF5350)
            )
        ),
        .monochrome: PalettePair(
            id: "monochrome",
            light: PaletteSeed(
                primary: UIColor(hex: 0x202020),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x595959),
                background: UIColor(hex: 0xFFFFFF),
                surface: UIColor(hex: 0xF2F2F2),
                onSurface: UIColor(hex: 0x111111),
                onSurfaceVariant: UIColor(hex: 0x575757),
                outline: UIColor(hex: 0xD2D2D2),
                error: UIColor(hex: 0xA62B2B)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xEEEEEE),
                onPrimary: UIColor(hex: 0x111111),
                secondary: UIColor(hex: 0xBCBCBC),
                background: UIColor(hex: 0x111111),
                surface: UIColor(hex: 0x1D1D1D),
                onSurface: UIColor(hex: 0xF3F3F3),
                onSurfaceVariant: UIColor(hex: 0xBCBCBC),
                outline: UIColor(hex: 0x3A3A3A),
                error: UIColor(hex: 0xE06C6C)
            )
        ),
        .catppuccin: PalettePair(
            id: "catppuccin",
            light: PaletteSeed(
                primary: UIColor(hex: 0x8839EF),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x7287FD),
                background: UIColor(hex: 0xEFF1F5),
                surface: UIColor(hex: 0xE6E9EF),
                onSurface: UIColor(hex: 0x4C4F69),
                onSurfaceVariant: UIColor(hex: 0x6C6F85),
                outline: UIColor(hex: 0xBCC0CC),
                error: UIColor(hex: 0xD20F39)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xCBA6F7),
                onPrimary: UIColor(hex: 0x1E1E2E),
                secondary: UIColor(hex: 0x89B4FA),
                background: UIColor(hex: 0x11111B),
                surface: UIColor(hex: 0x1E1E2E),
                onSurface: UIColor(hex: 0xCDD6F4),
                onSurfaceVariant: UIColor(hex: 0xA6ADC8),
                outline: UIColor(hex: 0x45475A),
                error: UIColor(hex: 0xF38BA8)
            )
        ),
        .greenApple: PalettePair(
            id: "green-apple",
            light: PaletteSeed(
                primary: UIColor(hex: 0x3F7D20),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x72A83B),
                background: UIColor(hex: 0xFBFFF7),
                surface: UIColor(hex: 0xEEF6E8),
                onSurface: UIColor(hex: 0x17210F),
                onSurfaceVariant: UIColor(hex: 0x53614A),
                outline: UIColor(hex: 0xC7D7BB),
                error: UIColor(hex: 0xBA1A1A)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xA5D66A),
                onPrimary: UIColor(hex: 0x1D3700),
                secondary: UIColor(hex: 0x89B75A),
                background: UIColor(hex: 0x10150C),
                surface: UIColor(hex: 0x1A2214),
                onSurface: UIColor(hex: 0xE7F0DF),
                onSurfaceVariant: UIColor(hex: 0xBDCBB3),
                outline: UIColor(hex: 0x3B4932),
                error: UIColor(hex: 0xFFB4AB)
            )
        ),
        .lavender: PalettePair(
            id: "lavender",
            light: PaletteSeed(
                primary: UIColor(hex: 0x7357A4),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x8D73B8),
                background: UIColor(hex: 0xFDF9FF),
                surface: UIColor(hex: 0xF3EDFA),
                onSurface: UIColor(hex: 0x211A29),
                onSurfaceVariant: UIColor(hex: 0x62586C),
                outline: UIColor(hex: 0xD0C4DB),
                error: UIColor(hex: 0xBA1A1A)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xD2B8FF),
                onPrimary: UIColor(hex: 0x3E246C),
                secondary: UIColor(hex: 0xBEA4E6),
                background: UIColor(hex: 0x151119),
                surface: UIColor(hex: 0x211A28),
                onSurface: UIColor(hex: 0xEEE6F2),
                onSurfaceVariant: UIColor(hex: 0xCABFD0),
                outline: UIColor(hex: 0x4A4053),
                error: UIColor(hex: 0xFFB4AB)
            )
        ),
        .nord: PalettePair(
            id: "nord",
            light: PaletteSeed(
                primary: UIColor(hex: 0x5E81AC),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x81A1C1),
                background: UIColor(hex: 0xECEFF4),
                surface: UIColor(hex: 0xE5E9F0),
                onSurface: UIColor(hex: 0x2E3440),
                onSurfaceVariant: UIColor(hex: 0x4C566A),
                outline: UIColor(hex: 0xC3CAD5),
                error: UIColor(hex: 0xBF616A)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0x88C0D0),
                onPrimary: UIColor(hex: 0x1F2933),
                secondary: UIColor(hex: 0x81A1C1),
                background: UIColor(hex: 0x242933),
                surface: UIColor(hex: 0x2E3440),
                onSurface: UIColor(hex: 0xECEFF4),
                onSurfaceVariant: UIColor(hex: 0xD8DEE9),
                outline: UIColor(hex: 0x4C566A),
                error: UIColor(hex: 0xBF616A)
            )
        ),
        .tako: PalettePair(
            id: "tako",
            light: PaletteSeed(
                primary: UIColor(hex: 0x6650A4),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x7D5260),
                background: UIColor(hex: 0xFFF7FF),
                surface: UIColor(hex: 0xF6EEF8),
                onSurface: UIColor(hex: 0x211F26),
                onSurfaceVariant: UIColor(hex: 0x625B67),
                outline: UIColor(hex: 0xCAC2CF),
                error: UIColor(hex: 0xBA1A1A)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xD0BCFF),
                onPrimary: UIColor(hex: 0x381E72),
                secondary: UIColor(hex: 0xE8B9C7),
                background: UIColor(hex: 0x17131C),
                surface: UIColor(hex: 0x221D29),
                onSurface: UIColor(hex: 0xE9E1EB),
                onSurfaceVariant: UIColor(hex: 0xCCC3D0),
                outline: UIColor(hex: 0x4B4450),
                error: UIColor(hex: 0xFFB4AB)
            )
        ),
        .yinYang: PalettePair(
            id: "yin-yang",
            light: PaletteSeed(
                primary: UIColor(hex: 0x343434),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x6E6E6E),
                background: UIColor(hex: 0xFAFAFA),
                surface: UIColor(hex: 0xEDEDED),
                onSurface: UIColor(hex: 0x151515),
                onSurfaceVariant: UIColor(hex: 0x5B5B5B),
                outline: UIColor(hex: 0xCCCCCC),
                error: UIColor(hex: 0xB3261E)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xFAFAFA),
                onPrimary: UIColor(hex: 0x171717),
                secondary: UIColor(hex: 0xC7C7C7),
                background: UIColor(hex: 0x0B0B0B),
                surface: UIColor(hex: 0x171717),
                onSurface: UIColor(hex: 0xF5F5F5),
                onSurfaceVariant: UIColor(hex: 0xBDBDBD),
                outline: UIColor(hex: 0x383838),
                error: UIColor(hex: 0xF2B8B5)
            )
        ),
        .strawberryDaiquiri: PalettePair(
            id: "strawberry-daiquiri",
            light: PaletteSeed(
                primary: UIColor(hex: 0xB3264F),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x9B405B),
                background: UIColor(hex: 0xFFF8F8),
                surface: UIColor(hex: 0xFCEBED),
                onSurface: UIColor(hex: 0x28171B),
                onSurfaceVariant: UIColor(hex: 0x6B555B),
                outline: UIColor(hex: 0xDBC0C7),
                error: UIColor(hex: 0xBA1A1A)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xFFB1C3),
                onPrimary: UIColor(hex: 0x67002B),
                secondary: UIColor(hex: 0xE8B8C4),
                background: UIColor(hex: 0x1C1013),
                surface: UIColor(hex: 0x291A1E),
                onSurface: UIColor(hex: 0xF4DFE4),
                onSurfaceVariant: UIColor(hex: 0xD6C0C6),
                outline: UIColor(hex: 0x523B41),
                error: UIColor(hex: 0xFFB4AB)
            )
        ),
        .kanagawa: PalettePair(
            id: "kanagawa",
            light: PaletteSeed(
                primary: UIColor(hex: 0x6F5C2F),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x597B75),
                background: UIColor(hex: 0xF2ECDC),
                surface: UIColor(hex: 0xE7DFCF),
                onSurface: UIColor(hex: 0x36322B),
                onSurfaceVariant: UIColor(hex: 0x6F685B),
                outline: UIColor(hex: 0xC5BAA5),
                error: UIColor(hex: 0xC34043)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xE6C384),
                onPrimary: UIColor(hex: 0x282727),
                secondary: UIColor(hex: 0x7E9CD8),
                background: UIColor(hex: 0x1F1F28),
                surface: UIColor(hex: 0x2A2A37),
                onSurface: UIColor(hex: 0xDCD7BA),
                onSurfaceVariant: UIColor(hex: 0xC8C093),
                outline: UIColor(hex: 0x54546D),
                error: UIColor(hex: 0xE46876)
            )
        ),
        .tokyoNight: PalettePair(
            id: "tokyo-night",
            light: PaletteSeed(
                primary: UIColor(hex: 0x34548A),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x5A4A78),
                background: UIColor(hex: 0xD5D6DB),
                surface: UIColor(hex: 0xCBCCD1),
                onSurface: UIColor(hex: 0x343B58),
                onSurfaceVariant: UIColor(hex: 0x596172),
                outline: UIColor(hex: 0xA8ABB5),
                error: UIColor(hex: 0x8C4351)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0x7AA2F7),
                onPrimary: UIColor(hex: 0x10121B),
                secondary: UIColor(hex: 0xBB9AF7),
                background: UIColor(hex: 0x16161E),
                surface: UIColor(hex: 0x1F2335),
                onSurface: UIColor(hex: 0xC0CAF5),
                onSurfaceVariant: UIColor(hex: 0xA9B1D6),
                outline: UIColor(hex: 0x3B4261),
                error: UIColor(hex: 0xF7768E)
            )
        ),
        .rosePine: PalettePair(
            id: "rose-pine",
            light: PaletteSeed(
                primary: UIColor(hex: 0x907AA9),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0xD7827E),
                background: UIColor(hex: 0xFAF4ED),
                surface: UIColor(hex: 0xF2E9E1),
                onSurface: UIColor(hex: 0x575279),
                onSurfaceVariant: UIColor(hex: 0x797593),
                outline: UIColor(hex: 0xCECACD),
                error: UIColor(hex: 0xB4637A)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xC4A7E7),
                onPrimary: UIColor(hex: 0x191724),
                secondary: UIColor(hex: 0xEBBCBA),
                background: UIColor(hex: 0x191724),
                surface: UIColor(hex: 0x26233A),
                onSurface: UIColor(hex: 0xE0DEF4),
                onSurfaceVariant: UIColor(hex: 0x908CAA),
                outline: UIColor(hex: 0x403D52),
                error: UIColor(hex: 0xEB6F92)
            )
        ),
        .everforest: PalettePair(
            id: "everforest",
            light: PaletteSeed(
                primary: UIColor(hex: 0x8DA101),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x35A77C),
                background: UIColor(hex: 0xFDF6E3),
                surface: UIColor(hex: 0xF4F0D9),
                onSurface: UIColor(hex: 0x5C6A72),
                onSurfaceVariant: UIColor(hex: 0x829181),
                outline: UIColor(hex: 0xD3CDB2),
                error: UIColor(hex: 0xF85552)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xA7C080),
                onPrimary: UIColor(hex: 0x1E2326),
                secondary: UIColor(hex: 0x83C092),
                background: UIColor(hex: 0x1E2326),
                surface: UIColor(hex: 0x272E33),
                onSurface: UIColor(hex: 0xD3C6AA),
                onSurfaceVariant: UIColor(hex: 0x9DA9A0),
                outline: UIColor(hex: 0x414B50),
                error: UIColor(hex: 0xE67E80)
            )
        ),
        .gruvbox: PalettePair(
            id: "gruvbox",
            light: PaletteSeed(
                primary: UIColor(hex: 0xB57614),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x79740E),
                background: UIColor(hex: 0xFBF1C7),
                surface: UIColor(hex: 0xEBDBB2),
                onSurface: UIColor(hex: 0x3C3836),
                onSurfaceVariant: UIColor(hex: 0x665C54),
                outline: UIColor(hex: 0xD5C4A1),
                error: UIColor(hex: 0xCC241D)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xFABD2F),
                onPrimary: UIColor(hex: 0x282828),
                secondary: UIColor(hex: 0xB8BB26),
                background: UIColor(hex: 0x1D2021),
                surface: UIColor(hex: 0x282828),
                onSurface: UIColor(hex: 0xEBDBB2),
                onSurfaceVariant: UIColor(hex: 0xBDAE93),
                outline: UIColor(hex: 0x504945),
                error: UIColor(hex: 0xFB4934)
            )
        ),
        .dracula: PalettePair(
            id: "dracula",
            light: PaletteSeed(
                primary: UIColor(hex: 0x6D4AA2),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0xA33C83),
                background: UIColor(hex: 0xF8F7FB),
                surface: UIColor(hex: 0xECEAF2),
                onSurface: UIColor(hex: 0x282A36),
                onSurfaceVariant: UIColor(hex: 0x626473),
                outline: UIColor(hex: 0xCFCCD8),
                error: UIColor(hex: 0xC93654)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xBD93F9),
                onPrimary: UIColor(hex: 0x282A36),
                secondary: UIColor(hex: 0xFF79C6),
                background: UIColor(hex: 0x21222C),
                surface: UIColor(hex: 0x282A36),
                onSurface: UIColor(hex: 0xF8F8F2),
                onSurfaceVariant: UIColor(hex: 0xC5C8D4),
                outline: UIColor(hex: 0x44475A),
                error: UIColor(hex: 0xFF5555)
            )
        ),
        .solarized: PalettePair(
            id: "solarized",
            light: PaletteSeed(
                primary: UIColor(hex: 0x268BD2),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x2AA198),
                background: UIColor(hex: 0xFDF6E3),
                surface: UIColor(hex: 0xEEE8D5),
                onSurface: UIColor(hex: 0x586E75),
                onSurfaceVariant: UIColor(hex: 0x657B83),
                outline: UIColor(hex: 0xD6CFB8),
                error: UIColor(hex: 0xDC322F)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0x2AA198),
                onPrimary: UIColor(hex: 0x002B36),
                secondary: UIColor(hex: 0x268BD2),
                background: UIColor(hex: 0x002B36),
                surface: UIColor(hex: 0x073642),
                onSurface: UIColor(hex: 0xEEE8D5),
                onSurfaceVariant: UIColor(hex: 0x93A1A1),
                outline: UIColor(hex: 0x335963),
                error: UIColor(hex: 0xDC322F)
            )
        ),
        .tide: PalettePair(
            id: "tide",
            light: PaletteSeed(
                primary: UIColor(hex: 0x247F83),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x5C8F91),
                background: UIColor(hex: 0xF4FBFB),
                surface: UIColor(hex: 0xE5F1F1),
                onSurface: UIColor(hex: 0x183638),
                onSurfaceVariant: UIColor(hex: 0x587173),
                outline: UIColor(hex: 0xBFD1D1),
                error: UIColor(hex: 0xBA1A1A)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0x78C6C5),
                onPrimary: UIColor(hex: 0x093737),
                secondary: UIColor(hex: 0x97B8B8),
                background: UIColor(hex: 0x101A1C),
                surface: UIColor(hex: 0x182529),
                onSurface: UIColor(hex: 0xDCE8E8),
                onSurfaceVariant: UIColor(hex: 0xAABBBB),
                outline: UIColor(hex: 0x34474B),
                error: UIColor(hex: 0xFFB4AB)
            )
        ),
        .sage: PalettePair(
            id: "sage",
            light: PaletteSeed(
                primary: UIColor(hex: 0x5D7456),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x778870),
                background: UIColor(hex: 0xF7FAF4),
                surface: UIColor(hex: 0xEBF0E7),
                onSurface: UIColor(hex: 0x20281D),
                onSurfaceVariant: UIColor(hex: 0x5D6858),
                outline: UIColor(hex: 0xC5CEC0),
                error: UIColor(hex: 0xBA1A1A)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xB4CDA9),
                onPrimary: UIColor(hex: 0x21351D),
                secondary: UIColor(hex: 0xAEBFA7),
                background: UIColor(hex: 0x121812),
                surface: UIColor(hex: 0x1C251D),
                onSurface: UIColor(hex: 0xE2E9DF),
                onSurfaceVariant: UIColor(hex: 0xBEC8BA),
                outline: UIColor(hex: 0x3B493A),
                error: UIColor(hex: 0xFFB4AB)
            )
        ),
        .caffeine: PalettePair(
            id: "caffeine",
            light: PaletteSeed(
                primary: UIColor(hex: 0x795548),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x9A6F5D),
                background: UIColor(hex: 0xFFFAF6),
                surface: UIColor(hex: 0xF3E9E1),
                onSurface: UIColor(hex: 0x30231E),
                onSurfaceVariant: UIColor(hex: 0x6D5A51),
                outline: UIColor(hex: 0xD7C4B9),
                error: UIColor(hex: 0xBA1A1A)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xE6C2AA),
                onPrimary: UIColor(hex: 0x442A1E),
                secondary: UIColor(hex: 0xC7A797),
                background: UIColor(hex: 0x15110F),
                surface: UIColor(hex: 0x221A17),
                onSurface: UIColor(hex: 0xEEE4DF),
                onSurfaceVariant: UIColor(hex: 0xCDBDB5),
                outline: UIColor(hex: 0x493A34),
                error: UIColor(hex: 0xFFB4AB)
            )
        ),
        .claude: PalettePair(
            id: "claude",
            light: PaletteSeed(
                primary: UIColor(hex: 0xC15F3C),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x7D685F),
                background: UIColor(hex: 0xF7F4EF),
                surface: UIColor(hex: 0xECE7DF),
                onSurface: UIColor(hex: 0x2F2926),
                onSurfaceVariant: UIColor(hex: 0x6B605B),
                outline: UIColor(hex: 0xD2C9C0),
                error: UIColor(hex: 0xB3261E)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xE07A58),
                onPrimary: UIColor(hex: 0x2B1510),
                secondary: UIColor(hex: 0xB9A49B),
                background: UIColor(hex: 0x1D1B19),
                surface: UIColor(hex: 0x282522),
                onSurface: UIColor(hex: 0xEEE9E5),
                onSurfaceVariant: UIColor(hex: 0xC8BEB8),
                outline: UIColor(hex: 0x4B4541),
                error: UIColor(hex: 0xFFB4AB)
            )
        ),
        .deepOcean: PalettePair(
            id: "deep-ocean",
            light: PaletteSeed(
                primary: UIColor(hex: 0x00629B),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x2E7FA6),
                background: UIColor(hex: 0xF5FAFF),
                surface: UIColor(hex: 0xE6F0F9),
                onSurface: UIColor(hex: 0x0B2135),
                onSurfaceVariant: UIColor(hex: 0x4A6072),
                outline: UIColor(hex: 0xBFD0DF),
                error: UIColor(hex: 0xBA1A1A)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0x4FB3E8),
                onPrimary: UIColor(hex: 0x00253A),
                secondary: UIColor(hex: 0x7FD1E0),
                background: UIColor(hex: 0x0A1929),
                surface: UIColor(hex: 0x132438),
                onSurface: UIColor(hex: 0xE3F2FD),
                onSurfaceVariant: UIColor(hex: 0xA9C1D6),
                outline: UIColor(hex: 0x2A4058),
                error: UIColor(hex: 0xFFB4AB)
            )
        ),
        .gunmetal: PalettePair(
            id: "gunmetal",
            light: PaletteSeed(
                primary: UIColor(hex: 0x455A64),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x607D8B),
                background: UIColor(hex: 0xF7F9FA),
                surface: UIColor(hex: 0xECEFF1),
                onSurface: UIColor(hex: 0x1C2429),
                onSurfaceVariant: UIColor(hex: 0x546E7A),
                outline: UIColor(hex: 0xCFD8DC),
                error: UIColor(hex: 0xB3261E)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0x90A4AE),
                onPrimary: UIColor(hex: 0x11181D),
                secondary: UIColor(hex: 0x78909C),
                background: UIColor(hex: 0x0F1216),
                surface: UIColor(hex: 0x1A1F26),
                onSurface: UIColor(hex: 0xECEFF1),
                onSurfaceVariant: UIColor(hex: 0xB0BEC5),
                outline: UIColor(hex: 0x37424C),
                error: UIColor(hex: 0xEF9A9A)
            )
        ),
        .cosmicVoid: PalettePair(
            id: "cosmic-void",
            light: PaletteSeed(
                primary: UIColor(hex: 0x5B2DE0),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x7C4DFF),
                background: UIColor(hex: 0xFBF9FF),
                surface: UIColor(hex: 0xF0ECFB),
                onSurface: UIColor(hex: 0x1B1726),
                onSurfaceVariant: UIColor(hex: 0x5B5470),
                outline: UIColor(hex: 0xD6CFE6),
                error: UIColor(hex: 0xB3261E)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xA384FF),
                onPrimary: UIColor(hex: 0x1A0059),
                secondary: UIColor(hex: 0x8C63FF),
                background: UIColor(hex: 0x050505),
                surface: UIColor(hex: 0x121212),
                onSurface: UIColor(hex: 0xE8E3F5),
                onSurfaceVariant: UIColor(hex: 0xB9B0CC),
                outline: UIColor(hex: 0x2E2A38),
                error: UIColor(hex: 0xFF8A80)
            )
        ),
        .cyberpunk: PalettePair(
            id: "cyberpunk",
            light: PaletteSeed(
                primary: UIColor(hex: 0xA3008F),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x00838F),
                background: UIColor(hex: 0xFFF7FE),
                surface: UIColor(hex: 0xF6E9F7),
                onSurface: UIColor(hex: 0x24102A),
                onSurfaceVariant: UIColor(hex: 0x66506B),
                outline: UIColor(hex: 0xDCC5DF),
                error: UIColor(hex: 0xBA1A1A)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xFF4DF0),
                onPrimary: UIColor(hex: 0x2B0029),
                secondary: UIColor(hex: 0x00E5FF),
                background: UIColor(hex: 0x0D001A),
                surface: UIColor(hex: 0x1A0A2E),
                onSurface: UIColor(hex: 0xF2E6FF),
                onSurfaceVariant: UIColor(hex: 0xC4B0DD),
                outline: UIColor(hex: 0x3D2A5A),
                error: UIColor(hex: 0xFF5C8A)
            )
        ),
        .royalGold: PalettePair(
            id: "royal-gold",
            light: PaletteSeed(
                primary: UIColor(hex: 0x7D6300),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x9A7D12),
                background: UIColor(hex: 0xFFFDF5),
                surface: UIColor(hex: 0xF7F0DC),
                onSurface: UIColor(hex: 0x221C08),
                onSurfaceVariant: UIColor(hex: 0x665C3D),
                outline: UIColor(hex: 0xDDD2B0),
                error: UIColor(hex: 0xBA1A1A)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xFFD700),
                onPrimary: UIColor(hex: 0x2A2100),
                secondary: UIColor(hex: 0xC5A000),
                background: UIColor(hex: 0x050505),
                surface: UIColor(hex: 0x141210),
                onSurface: UIColor(hex: 0xFFF8E1),
                onSurfaceVariant: UIColor(hex: 0xD6C9A3),
                outline: UIColor(hex: 0x3A3423),
                error: UIColor(hex: 0xFFB4AB)
            )
        ),
        .creamPaper: PalettePair(
            id: "cream-paper",
            light: PaletteSeed(
                primary: UIColor(hex: 0x7F6157),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0xA1887F),
                background: UIColor(hex: 0xFFFBF0),
                surface: UIColor(hex: 0xF5F5DC),
                onSurface: UIColor(hex: 0x3E2723),
                onSurfaceVariant: UIColor(hex: 0x6D5C52),
                outline: UIColor(hex: 0xDCD3BD),
                error: UIColor(hex: 0xB3261E)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xD7B7A8),
                onPrimary: UIColor(hex: 0x3B2620),
                secondary: UIColor(hex: 0xBCAAA4),
                background: UIColor(hex: 0x1A1712),
                surface: UIColor(hex: 0x25211A),
                onSurface: UIColor(hex: 0xF1EBDF),
                onSurfaceVariant: UIColor(hex: 0xCFC4B3),
                outline: UIColor(hex: 0x4A4336),
                error: UIColor(hex: 0xFFB4AB)
            )
        ),
    ]

    /// The palette behind `mode`, or Flow Default for modes that are not palettes themselves.
    static func pair(for mode: ThemeMode) -> PalettePair {
        if let pair = all[mode] { return pair }
        return all[.default] ?? PalettePair(
            id: "default",
            light: PaletteSeed(
                primary: UIColor(hex: 0xFF0000),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0x606060),
                background: UIColor(hex: 0xFFFFFF),
                surface: UIColor(hex: 0xF3F3F3),
                onSurface: UIColor(hex: 0x111111),
                onSurfaceVariant: UIColor(hex: 0x5F5F5F),
                outline: UIColor(hex: 0xD7D7D7),
                error: UIColor(hex: 0xD32F2F)
            ),
            dark: PaletteSeed(
                primary: UIColor(hex: 0xFF0000),
                onPrimary: UIColor(hex: 0xFFFFFF),
                secondary: UIColor(hex: 0xAAAAAA),
                background: UIColor(hex: 0x0F0F0F),
                surface: UIColor(hex: 0x1D1D1D),
                onSurface: UIColor(hex: 0xF4F4F4),
                onSurfaceVariant: UIColor(hex: 0xB8B8B8),
                outline: UIColor(hex: 0x343434),
                error: UIColor(hex: 0xEF5350)
            )
        )
    }

    /// Flow Default, the palette every unknown mode falls back to.
    static var `default`: PalettePair {
        return pair(for: .default)
    }
}
