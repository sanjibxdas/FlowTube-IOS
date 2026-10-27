import UIKit

/// Material 3's shape scale, in points. Every rounded surface in the app picks one of these, so a
/// card in Home and a card in Settings have the same corner.
enum FlowShapes {
    static let extraSmall: CGFloat = 4.0
    static let small: CGFloat = 8.0
    static let medium: CGFloat = 12.0
    static let large: CGFloat = 16.0
    static let extraLarge: CGFloat = 28.0

    /// Fully rounded, for pills and circular avatars.
    static func pill(for height: CGFloat) -> CGFloat {
        return height / 2.0
    }

    /// The corner radius for a card at the default size.
    static let card: CGFloat = small

    /// Thumbnails in lists use the smaller radius the Android app uses for video stills.
    static let thumbnail: CGFloat = 6.0

    /// The radius for a sheet's top corners.
    static let sheet: CGFloat = extraLarge

    /// The radius for chips and filter pills.
    static let chip: CGFloat = small

    /// The radius for the mini player and other floating bars.
    static let bar: CGFloat = medium
}

/// The app's spacing scale, transcribed from the Android `Dimensions.kt` so paddings match.
enum FlowSpacing {
    static let xxs: CGFloat = 2.0
    static let xs: CGFloat = 4.0
    static let sm: CGFloat = 6.0
    static let md: CGFloat = 8.0
    static let lg: CGFloat = 12.0
    static let xl: CGFloat = 16.0
    static let xxl: CGFloat = 24.0
    static let xxxl: CGFloat = 32.0

    // Android's named dimensions.
    static let listItemHeight: CGFloat = 64.0
    static let listThumbnailSize: CGFloat = 48.0
    static let suggestionItemHeight: CGFloat = 56.0
    static let gridThumbnailHeightBig: CGFloat = 128.0
    static let gridThumbnailHeightSmall: CGFloat = 104.0
    static let albumThumbnailSize: CGFloat = 144.0
    static let moodButtonHeight: CGFloat = 48.0
    static let contentPaddingHorizontal: CGFloat = 12.0
    static let contentPaddingVertical: CGFloat = 12.0
    static let itemSpacing: CGFloat = 12.0
    static let sectionSpacing: CGFloat = 16.0
    static let playerHorizontalPadding: CGFloat = 32.0

    /// The horizontal margin every screen's content sits inside.
    static let screenMargin: CGFloat = 16.0

    /// The height of the app's standard toolbar row.
    static let toolbarHeight: CGFloat = 56.0

    /// The height of the tab bar's content, above the home indicator.
    static let tabBarHeight: CGFloat = 49.0

    /// The height of the mini player bar.
    static let miniPlayerHeight: CGFloat = 64.0
}

/// The grid item size the Android app exposes as `GridItemSize`.
enum FlowGridItemSize {
    case big
    case small

    var thumbnailHeight: CGFloat {
        switch self {
        case .big: return FlowSpacing.gridThumbnailHeightBig
        case .small: return FlowSpacing.gridThumbnailHeightSmall
        }
    }
}
