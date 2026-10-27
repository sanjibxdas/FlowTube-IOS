import Foundation

/// A read-only view over one node of the JSON tree `JSONSerialization` produces.
///
/// YouTube's responses are renderer trees with wildly inconsistent shapes: the same fact arrives as
/// `simpleText`, as `runs`, as `content`, or nested one level deeper depending on the surface. Every
/// accessor here is total — a missing key or a wrong type yields nil rather than trapping — because
/// the parsers must survive a renderer YouTube adds or renames overnight.
struct JSONNode {

    let value: Any?

    static let empty = JSONNode(nil)

    init(_ value: Any?) {
        self.value = value
    }

    /// A child object by key.
    subscript(key: String) -> JSONNode {
        guard let dictionary = value as? [String: Any] else { return .empty }
        return JSONNode(dictionary[key])
    }

    /// A child object by the first key that exists.
    func first(_ keys: String...) -> JSONNode {
        for key in keys {
            let node = self[key]
            if !node.isMissing { return node }
        }
        return .empty
    }

    /// True when the node holds nothing at all.
    var isMissing: Bool {
        if value == nil { return true }
        if value is NSNull { return true }
        return false
    }

    var exists: Bool {
        return !isMissing
    }

    var object: [String: Any]? {
        return value as? [String: Any]
    }

    var array: [JSONNode] {
        guard let items = value as? [Any] else { return [] }
        return items.map(JSONNode.init)
    }

    var string: String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    var int: Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    var int64: Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    var double: Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    var bool: Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            if text == "true" { return true }
            if text == "false" { return false }
        }
        return nil
    }

    /// The node's text, whichever of YouTube's three shapes it arrived in.
    var text: String? {
        if let direct = value as? String { return direct }
        if let simple = self["simpleText"].string { return simple }
        if let content = self["content"].string { return content }
        let runs = self["runs"].array
        if !runs.isEmpty {
            let joined = runs.compactMap { $0["text"].string }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// The text of a node whose runs carry navigation endpoints, such as a byline.
    var runs: [JSONNode] {
        return self["runs"].array
    }

    /// Every `text` in the node's runs, in order.
    var runTexts: [String] {
        return runs.compactMap { $0["text"].string }
    }

    /// The last thumbnail URL in a `thumbnails` array, which is the largest.
    var largestThumbnailURL: String? {
        let thumbnails = self["thumbnails"].array
        if let last = thumbnails.last, let url = last["url"].string {
            return url
        }
        return nil
    }

    /// The best thumbnail URL under any of YouTube's thumbnail renderers.
    var thumbnailURL: String? {
        if let direct = self["url"].string, direct.contains("http") { return direct }
        if let fromThumbnails = largestThumbnailURL { return fromThumbnails }
        if let music = self["musicThumbnailRenderer"].largestThumbnailURL { return music }
        if let cropped = self["croppedSquareThumbnailRenderer"]["thumbnail"].largestThumbnailURL { return cropped }
        if let thumbnail = self["thumbnail"].largestThumbnailURL { return thumbnail }
        return nil
    }

    /// A browse id from a navigation endpoint nested anywhere under this node.
    var browseId: String? {
        let candidates = [
            self["browseEndpoint"]["browseId"],
            self["navigationEndpoint"]["browseEndpoint"]["browseId"],
            self["endpoint"]["browseEndpoint"]["browseId"],
            self["commandMetadata"]["webCommandMetadata"]["url"],
        ]
        for candidate in candidates {
            if let id = candidate.string, !id.isEmpty { return id }
        }
        return nil
    }

    /// A video id from a watch endpoint nested anywhere under this node.
    var videoId: String? {
        let candidates = [
            self["watchEndpoint"]["videoId"],
            self["navigationEndpoint"]["watchEndpoint"]["videoId"],
            self["endpoint"]["watchEndpoint"]["videoId"],
            self["videoId"],
        ]
        for candidate in candidates {
            if let id = candidate.string, !id.isEmpty { return id }
        }
        return nil
    }

    /// A playlist id from a watch-playlist or browse endpoint.
    var playlistId: String? {
        let candidates = [
            self["watchEndpoint"]["playlistId"],
            self["navigationEndpoint"]["watchEndpoint"]["playlistId"],
            self["watchPlaylistEndpoint"]["playlistId"],
            self["navigationEndpoint"]["watchPlaylistEndpoint"]["playlistId"],
            self["playlistId"],
        ]
        for candidate in candidates {
            if let id = candidate.string, !id.isEmpty { return id }
        }
        return nil
    }

    /// The continuation token in a `continuationItemRenderer`, wherever it sits.
    var continuationToken: String? {
        let candidates = [
            self["continuationEndpoint"]["continuationCommand"]["token"],
            self["continuationCommand"]["token"],
            self["nextContinuationData"]["continuation"],
            self["reloadContinuationData"]["continuation"],
        ]
        for candidate in candidates {
            if let token = candidate.string, !token.isEmpty { return token }
        }
        return nil
    }

    /// The first continuation token found anywhere in an array of items.
    static func firstContinuation(in nodes: [JSONNode]) -> String? {
        for node in nodes {
            if let token = node.continuationToken { return token }
            if let renderer = node["continuationItemRenderer"].continuationToken { return renderer }
        }
        return nil
    }
}

/// Parsing helpers shared by every page parser.
enum InnerTubeParse {

    /// The text of a `runs` array joined with a separator, skipping empty runs.
    static func joinedRuns(_ node: JSONNode, separator: String = "") -> String? {
        let texts = node.runTexts.filter { !$0.isEmpty }
        if texts.isEmpty { return node.text }
        return texts.joined(separator: separator)
    }

    /// Splits a byline into its ` • `-separated segments, dropping the separators themselves.
    static func bylineSegments(_ node: JSONNode) -> [String] {
        let texts = node.runTexts
        if texts.isEmpty {
            guard let whole = node.text else { return [] }
            return whole.components(separatedBy: "•").map { $0.trimmed }.filter { !$0.isEmpty }
        }
        return texts.map { $0.trimmed }.filter { !$0.isEmpty && $0 != "•" }
    }

    /// Reads a duration written as `1:02:03`, `12:34` or `1:02` into seconds.
    static func duration(from text: String?) -> Int? {
        guard let text = text?.trimmed, !text.isEmpty else { return nil }
        let parts = text.components(separatedBy: ":")
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        switch numbers.count {
        case 2: return numbers[0] * 60 + numbers[1]
        case 3: return numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        default: return nil
        }
    }

    /// Reads a count as YouTube prints it — "1.2M views", "3,4 M de visualizaciones", "33万回視聴" —
    /// into a number. The suffix table is English plus the compact Latin forms YouTube also emits.
    static func count(from text: String?) -> Int64? {
        guard let raw = text?.trimmed, !raw.isEmpty else { return nil }
        let normalized = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
        var digits = ""
        var suffix = ""
        for character in normalized {
            if character.isNumber || character == "," || character == "." || character == "'" {
                if suffix.isEmpty {
                    digits.append(character)
                }
            } else if character == " " {
                continue
            } else {
                suffix.append(character)
            }
        }
        guard !digits.isEmpty else { return nil }
        let lastSeparator = digits.lastIndex { !$0.isNumber }
        var numberText = digits
        if let separatorIndex = lastSeparator {
            let after = digits.distance(from: digits.index(after: separatorIndex), to: digits.endIndex)
            if after == 3 {
                numberText = digits.filter { $0.isNumber }
            } else {
                let head = String(digits[digits.startIndex..<separatorIndex]).filter { $0.isNumber }
                let tail = String(digits[digits.index(after: separatorIndex)...]).filter { $0.isNumber }
                numberText = head + "." + tail
            }
        }
        guard let base = Double(numberText) else { return nil }
        let lowered = suffix.lowercased()
        var multiplier: Double = 1.0
        if lowered.hasPrefix("k") || lowered.hasPrefix("thousand") {
            multiplier = 1_000.0
        } else if lowered.hasPrefix("m") || lowered.hasPrefix("million") {
            multiplier = 1_000_000.0
        } else if lowered.hasPrefix("b") || lowered.hasPrefix("billion") {
            multiplier = 1_000_000_000.0
        } else if lowered.hasPrefix("万") {
            multiplier = 10_000.0
        } else if lowered.hasPrefix("億") {
            multiplier = 100_000_000.0
        } else if lowered.hasPrefix("천") {
            multiplier = 1_000.0
        } else if lowered.hasPrefix("만") {
            multiplier = 10_000.0
        }
        return Int64((base * multiplier).rounded())
    }

    /// The publish date text YouTube printed, left as text because it is already localised.
    static func uploadDateText(_ node: JSONNode) -> String {
        if let published = node["publishedTimeText"].text, !published.isEmpty { return published }
        if let published = node["publishedTimeText"]["simpleText"].string { return published }
        return ""
    }

    /// The video id out of a `/watch?v=` URL or a bare id.
    static func videoId(fromURLOrID raw: String) -> String? {
        let trimmed = raw.trimmed
        if trimmed.looksLikeVideoID { return trimmed }
        guard let components = URLComponents(string: trimmed) else { return nil }
        if let value = components.queryItems?.first(where: { $0.name == "v" })?.value, value.looksLikeVideoID {
            return value
        }
        let last = components.path.components(separatedBy: "/").last ?? ""
        return last.looksLikeVideoID ? last : nil
    }
}

// MARK: - Domain models

/// A video as a list row, a search result or a watch page needs it.
struct Video {
    let id: String
    var title: String
    var channelName: String
    var channelId: String
    var thumbnailUrl: String
    /// Duration in seconds. Zero for a live stream.
    var duration: Int
    var viewCount: Int64
    var likeCount: Int64
    /// YouTube's own wording, already localised — "3 weeks ago", "Premiered 2 days ago".
    var uploadDate: String
    var timestamp: Date
    var description: String
    var channelThumbnailUrl: String
    var tags: [String]
    var category: String?
    var isMusic: Bool
    var isLive: Bool
    var isShort: Bool
    var isUpcoming: Bool
    var membersOnlyText: String?
    var commentCountText: String
    var isVerifiedChannel: Bool
    /// YouTube's own pills — "4K", "CC", "New" — already localised.
    var badges: [String]
    var snippet: String

    init(
        id: String,
        title: String,
        channelName: String = "",
        channelId: String = "",
        thumbnailUrl: String = "",
        duration: Int = 0,
        viewCount: Int64 = 0,
        likeCount: Int64 = 0,
        uploadDate: String = "",
        timestamp: Date = Date(),
        description: String = "",
        channelThumbnailUrl: String = "",
        tags: [String] = [],
        category: String? = nil,
        isMusic: Bool = false,
        isLive: Bool = false,
        isShort: Bool = false,
        isUpcoming: Bool = false,
        membersOnlyText: String? = nil,
        commentCountText: String = "",
        isVerifiedChannel: Bool = false,
        badges: [String] = [],
        snippet: String = ""
    ) {
        self.id = id
        self.title = title
        self.channelName = channelName
        self.channelId = channelId
        self.thumbnailUrl = thumbnailUrl
        self.duration = duration
        self.viewCount = viewCount
        self.likeCount = likeCount
        self.uploadDate = uploadDate
        self.timestamp = timestamp
        self.description = description
        self.channelThumbnailUrl = channelThumbnailUrl
        self.tags = tags
        self.category = category
        self.isMusic = isMusic
        self.isLive = isLive
        self.isShort = isShort
        self.isUpcoming = isUpcoming
        self.membersOnlyText = membersOnlyText
        self.commentCountText = commentCountText
        self.isVerifiedChannel = isVerifiedChannel
        self.badges = badges
        self.snippet = snippet
    }

    /// The watch URL, for sharing.
    var shareURL: String {
        return "https://www.youtube.com/watch?v=" + id
    }

    /// The thumbnail at a chosen width, derived from the URL YouTube served.
    func thumbnail(width: Int) -> String {
        guard !thumbnailUrl.isEmpty else {
            return "https://i.ytimg.com/vi/" + id + "/hqdefault.jpg"
        }
        return thumbnailUrl
    }
}

/// A channel, as its page header and its rows need it.
struct Channel {
    let id: String
    var name: String
    var thumbnailUrl: String
    var subscriberCount: Int64
    var subscriberCountText: String
    var description: String
    var isSubscribed: Bool
    var isMusic: Bool
    var handle: String
    var videoCount: Int
    var isVerified: Bool
    var bannerUrl: String

    init(
        id: String,
        name: String,
        thumbnailUrl: String = "",
        subscriberCount: Int64 = 0,
        subscriberCountText: String = "",
        description: String = "",
        isSubscribed: Bool = false,
        isMusic: Bool = false,
        handle: String = "",
        videoCount: Int = 0,
        isVerified: Bool = false,
        bannerUrl: String = ""
    ) {
        self.id = id
        self.name = name
        self.thumbnailUrl = thumbnailUrl
        self.subscriberCount = subscriberCount
        self.subscriberCountText = subscriberCountText
        self.description = description
        self.isSubscribed = isSubscribed
        self.isMusic = isMusic
        self.handle = handle
        self.videoCount = videoCount
        self.isVerified = isVerified
        self.bannerUrl = bannerUrl
    }

    var shareURL: String {
        return "https://www.youtube.com/channel/" + id
    }
}

/// A playlist, local or remote.
struct Playlist {
    let id: String
    var name: String
    var thumbnailUrl: String
    var videoCount: Int
    var description: String
    var videos: [Video]
    var isLocal: Bool
    var authorName: String

    init(
        id: String,
        name: String,
        thumbnailUrl: String = "",
        videoCount: Int = 0,
        description: String = "",
        videos: [Video] = [],
        isLocal: Bool = false,
        authorName: String = ""
    ) {
        self.id = id
        self.name = name
        self.thumbnailUrl = thumbnailUrl
        self.videoCount = videoCount
        self.description = description
        self.videos = videos
        self.isLocal = isLocal
        self.authorName = authorName
    }

    var shareURL: String {
        return "https://www.youtube.com/playlist?list=" + id
    }
}

/// One comment, with its replies when they were loaded.
struct Comment {
    let id: String
    var author: String
    var authorThumbnail: String
    var authorChannelId: String
    var text: String
    var likeCount: Int
    var likeCountText: String
    var publishedTime: String
    var replies: [Comment]
    var replyCount: Int
    var continuation: String?
    var isPinned: Bool
    var isHearted: Bool
    var isVerified: Bool
    var isCreator: Bool

    init(
        id: String,
        author: String,
        authorThumbnail: String = "",
        authorChannelId: String = "",
        text: String,
        likeCount: Int = 0,
        likeCountText: String = "",
        publishedTime: String = "",
        replies: [Comment] = [],
        replyCount: Int = 0,
        continuation: String? = nil,
        isPinned: Bool = false,
        isHearted: Bool = false,
        isVerified: Bool = false,
        isCreator: Bool = false
    ) {
        self.id = id
        self.author = author
        self.authorThumbnail = authorThumbnail
        self.authorChannelId = authorChannelId
        self.text = text
        self.likeCount = likeCount
        self.likeCountText = likeCountText
        self.publishedTime = publishedTime
        self.replies = replies
        self.replyCount = replyCount
        self.continuation = continuation
        self.isPinned = isPinned
        self.isHearted = isHearted
        self.isVerified = isVerified
        self.isCreator = isCreator
    }
}

/// The filter a video search applies. The raw values are the opaque `params` tokens YouTube's own
/// search dialog sends.
enum VideoSearchFilter: String {
    case all = ""
    case videos = "EgIQAQ%3D%3D"
    case channels = "EgIQAg%3D%3D"
    case playlists = "EgIQAw%3D%3D"
    case live = "EgJAAQ%3D%3D"
    case movies = "EgIQBA%3D%3D"

    var title: String {
        switch self {
        case .all: return "All"
        case .videos: return "Videos"
        case .channels: return "Channels"
        case .playlists: return "Playlists"
        case .live: return "Live"
        case .movies: return "Movies"
        }
    }

    /// The `params` value, or nil when the search is unfiltered.
    var params: String? {
        return rawValue.isEmpty ? nil : rawValue
    }
}

/// The music search filters, as the music search dialog sends them.
enum MusicSearchFilter: String {
    case all = ""
    case songs = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
    case videos = "EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D"
    case albums = "EgWKAQIYAWoKEAkQChAFEAMQBA%3D%3D"
    case artists = "EgWKAQIgAWoKEAkQChAFEAMQBA%3D%3D"
    case playlists = "EgeKAQQoADgBagwQDhAKEAMQBRAJEAQ%3D"
    case podcasts = "EgWKAQJQAWoKEAkQChAFEAMQBA%3D%3D"

    var params: String? {
        return rawValue.isEmpty ? nil : rawValue
    }
}

/// One item on a music surface. The Android app models these as a sealed hierarchy; the cases here
/// carry the same fields, and `kind` is what a list cell switches on.
enum MusicItem {
    case song(SongItem)
    case album(AlbumItem)
    case playlist(PlaylistItem)
    case artist(ArtistItem)

    var id: String {
        switch self {
        case .song(let item): return item.id
        case .album(let item): return item.id
        case .playlist(let item): return item.id
        case .artist(let item): return item.id
        }
    }

    var title: String {
        switch self {
        case .song(let item): return item.title
        case .album(let item): return item.title
        case .playlist(let item): return item.title
        case .artist(let item): return item.title
        }
    }

    var thumbnailUrl: String {
        switch self {
        case .song(let item): return item.thumbnailUrl
        case .album(let item): return item.thumbnailUrl
        case .playlist(let item): return item.thumbnailUrl
        case .artist(let item): return item.thumbnailUrl
        }
    }

    var isExplicit: Bool {
        switch self {
        case .song(let item): return item.isExplicit
        case .album(let item): return item.isExplicit
        case .playlist: return false
        case .artist: return false
        }
    }

    var shareURL: String {
        switch self {
        case .song(let item): return item.shareURL
        case .album(let item): return item.shareURL
        case .playlist(let item): return item.shareURL
        case .artist(let item): return item.shareURL
        }
    }
}

/// An artist credit on a song, album or playlist.
struct MusicArtist {
    let name: String
    let id: String?
}

/// A song on a music surface.
struct SongItem {
    let id: String
    var title: String
    var artists: [MusicArtist]
    var albumName: String?
    var albumId: String?
    var duration: Int?
    var musicVideoType: String?
    var thumbnailUrl: String
    var isExplicit: Bool
    var viewCountText: String?
    var likeCountText: String?
    var setVideoId: String?

    init(
        id: String,
        title: String,
        artists: [MusicArtist] = [],
        albumName: String? = nil,
        albumId: String? = nil,
        duration: Int? = nil,
        musicVideoType: String? = nil,
        thumbnailUrl: String = "",
        isExplicit: Bool = false,
        viewCountText: String? = nil,
        likeCountText: String? = nil,
        setVideoId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.albumName = albumName
        self.albumId = albumId
        self.duration = duration
        self.musicVideoType = musicVideoType
        self.thumbnailUrl = thumbnailUrl
        self.isExplicit = isExplicit
        self.viewCountText = viewCountText
        self.likeCountText = likeCountText
        self.setVideoId = setVideoId
    }

    /// The byline a row shows: the artists, joined.
    var artistLine: String {
        return artists.map { $0.name }.joined(separator: ", ")
    }

    /// True when the entry is a music video rather than an audio track.
    var isVideoSong: Bool {
        guard let type = musicVideoType else { return false }
        return type != "MUSIC_VIDEO_TYPE_ATV"
    }

    var shareURL: String {
        return "https://music.youtube.com/watch?v=" + id
    }

    /// The same song as a plain video, for the player and the history table.
    var asVideo: Video {
        return Video(
            id: id,
            title: title,
            channelName: artistLine,
            channelId: artists.first?.id ?? "",
            thumbnailUrl: thumbnailUrl,
            duration: duration ?? 0,
            isMusic: true
        )
    }
}

/// An album on a music surface.
struct AlbumItem {
    let browseId: String
    var playlistId: String
    var title: String
    var artists: [MusicArtist]
    var year: Int?
    var thumbnailUrl: String
    var isExplicit: Bool

    init(
        browseId: String,
        playlistId: String = "",
        title: String,
        artists: [MusicArtist] = [],
        year: Int? = nil,
        thumbnailUrl: String = "",
        isExplicit: Bool = false
    ) {
        self.browseId = browseId
        self.playlistId = playlistId
        self.title = title
        self.artists = artists
        self.year = year
        self.thumbnailUrl = thumbnailUrl
        self.isExplicit = isExplicit
    }

    var id: String { return browseId }

    var artistLine: String {
        return artists.map { $0.name }.joined(separator: ", ")
    }

    var shareURL: String {
        return "https://music.youtube.com/playlist?list=" + playlistId
    }
}

/// A playlist on a music surface.
struct PlaylistItem {
    let id: String
    var title: String
    var authorName: String?
    var authorId: String?
    var songCountText: String?
    var thumbnailUrl: String
    var isEditable: Bool

    init(
        id: String,
        title: String,
        authorName: String? = nil,
        authorId: String? = nil,
        songCountText: String? = nil,
        thumbnailUrl: String = "",
        isEditable: Bool = false
    ) {
        self.id = id
        self.title = title
        self.authorName = authorName
        self.authorId = authorId
        self.songCountText = songCountText
        self.thumbnailUrl = thumbnailUrl
        self.isEditable = isEditable
    }

    var shareURL: String {
        return "https://music.youtube.com/playlist?list=" + id
    }
}

/// An artist on a music surface.
struct ArtistItem {
    let id: String
    var title: String
    var thumbnailUrl: String
    var channelId: String?
    var subscriberCountText: String?
    /// A YouTube channel that is not an artist: it opens on its channel page.
    var isProfile: Bool

    init(
        id: String,
        title: String,
        thumbnailUrl: String = "",
        channelId: String? = nil,
        subscriberCountText: String? = nil,
        isProfile: Bool = false
    ) {
        self.id = id
        self.title = title
        self.thumbnailUrl = thumbnailUrl
        self.channelId = channelId
        self.subscriberCountText = subscriberCountText
        self.isProfile = isProfile
    }

    var shareURL: String {
        return "https://music.youtube.com/channel/" + id
    }
}

// MARK: - Page models

/// The home feed: filter chips plus the shelves beneath them.
struct HomeFeed {
    var chips: [HomeChip]
    var sections: [HomeSection]
    var continuation: String?

    init(chips: [HomeChip] = [], sections: [HomeSection] = [], continuation: String? = nil) {
        self.chips = chips
        self.sections = sections
        self.continuation = continuation
    }
}

/// One filter chip above the home feed.
struct HomeChip {
    let title: String
    let browseId: String?
    let params: String?
    let deselectBrowseId: String?
}

/// One shelf of the home feed.
struct HomeSection {
    let title: String
    let subtitle: String?
    let thumbnailUrl: String?
    let moreBrowseId: String?
    let items: [MusicItem]
}

/// The main-site home feed: the filter chips above it and the shelves it is made of.
struct VideoHomeFeed {
    var chips: [HomeChip]
    var sections: [VideoShelf]
    var continuation: String?

    init(chips: [HomeChip] = [], sections: [VideoShelf] = [], continuation: String? = nil) {
        self.chips = chips
        self.sections = sections
        self.continuation = continuation
    }

    var isEmpty: Bool {
        return sections.allSatisfy { $0.items.isEmpty }
    }
}

/// One page of video search results, in the order YouTube ranked them.
struct VideoSearchResults {
    var videos: [Video]
    var channels: [Channel]
    var playlists: [Playlist]
    var continuation: String?
    var estimatedResults: Int64?
    var chips: [SearchChip]

    init(
        videos: [Video] = [],
        channels: [Channel] = [],
        playlists: [Playlist] = [],
        continuation: String? = nil,
        estimatedResults: Int64? = nil,
        chips: [SearchChip] = []
    ) {
        self.videos = videos
        self.channels = channels
        self.playlists = playlists
        self.continuation = continuation
        self.estimatedResults = estimatedResults
        self.chips = chips
    }

    var isEmpty: Bool {
        return videos.isEmpty && channels.isEmpty && playlists.isEmpty
    }
}

/// A refinement chip on the search results page.
struct SearchChip {
    let label: String
    let isSelected: Bool
    let continuation: String?
    let params: String?
}

/// One page of music search results.
struct MusicSearchResults {
    var items: [MusicItem]
    var continuation: String?
}

/// The watch page's data: the player response plus the metadata the next response carries.
struct WatchPage {
    let video: Video
    let playabilityStatus: String
    let playabilityReason: String?
    let hlsManifestUrl: String?
    let dashManifestUrl: String?
    let formats: [StreamFormat]
    let adaptiveFormats: [StreamFormat]
    let captionTracks: [CaptionTrack]
    let related: [Video]
    let chapters: [Chapter]
    let commentsContinuation: String?
    let likeCount: Int64
    let isLive: Bool
    let isUpcoming: Bool
    let scheduledStartTime: String?

    /// Whether the player can play anything at all.
    var isPlayable: Bool {
        return playabilityStatus == "OK"
            && (hlsManifestUrl != nil || dashManifestUrl != nil || !formats.isEmpty || !adaptiveFormats.isEmpty)
    }

    /// The progressive formats that carry both video and audio, best first.
    var progressiveFormats: [StreamFormat] {
        return formats.filter { $0.isProgressive }.sorted { $0.bitrate > $1.bitrate }
    }

    /// The adaptive audio tracks, best first, preferring the original language and non-DRC copies.
    var audioFormats: [StreamFormat] {
        let audio = adaptiveFormats.filter { $0.isAudioOnly }
        return audio.sorted { left, right in
            if left.isOriginal != right.isOriginal { return left.isOriginal }
            if left.isDynamicRangeCompressed != right.isDynamicRangeCompressed {
                return !left.isDynamicRangeCompressed
            }
            return left.bitrate > right.bitrate
        }
    }

    /// The adaptive video tracks, best first.
    var videoFormats: [StreamFormat] {
        return adaptiveFormats.filter { $0.isVideoOnly }.sorted { left, right in
            if left.height != right.height { return left.height > right.height }
            return left.bitrate > right.bitrate
        }
    }
}

/// One stream YouTube offers.
struct StreamFormat {
    let itag: Int
    let url: String?
    let signatureCipher: String?
    let mimeType: String
    let bitrate: Int
    let averageBitrate: Int?
    let width: Int
    let height: Int
    let fps: Int
    let quality: String
    let qualityLabel: String
    let audioQuality: String
    let audioSampleRate: Int
    let audioChannels: Int
    let contentLength: Int64
    let approxDurationMs: Int64
    let isDRC: Bool
    let xtags: String
    let audioTrackId: String?
    let audioTrackIsDefault: Bool?
    let audioTrackIsAutoDubbed: Bool?

    init(
        itag: Int,
        url: String?,
        signatureCipher: String? = nil,
        mimeType: String = "",
        bitrate: Int = 0,
        averageBitrate: Int? = nil,
        width: Int = 0,
        height: Int = 0,
        fps: Int = 0,
        quality: String = "",
        qualityLabel: String = "",
        audioQuality: String = "",
        audioSampleRate: Int = 0,
        audioChannels: Int = 0,
        contentLength: Int64 = 0,
        approxDurationMs: Int64 = 0,
        isDRC: Bool = false,
        xtags: String = "",
        audioTrackId: String? = nil,
        audioTrackIsDefault: Bool? = nil,
        audioTrackIsAutoDubbed: Bool? = nil
    ) {
        self.itag = itag
        self.url = url
        self.signatureCipher = signatureCipher
        self.mimeType = mimeType
        self.bitrate = bitrate
        self.averageBitrate = averageBitrate
        self.width = width
        self.height = height
        self.fps = fps
        self.quality = quality
        self.qualityLabel = qualityLabel
        self.audioQuality = audioQuality
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.contentLength = contentLength
        self.approxDurationMs = approxDurationMs
        self.isDRC = isDRC
        self.xtags = xtags
        self.audioTrackId = audioTrackId
        self.audioTrackIsDefault = audioTrackIsDefault
        self.audioTrackIsAutoDubbed = audioTrackIsAutoDubbed
    }

    /// An audio-only track has no picture dimensions.
    var isAudioOnly: Bool {
        return width == 0 && height == 0
    }

    /// A video-only track has no audio sample rate.
    var isVideoOnly: Bool {
        return width > 0 && height > 0 && audioSampleRate == 0
    }

    /// A progressive track carries both.
    var isProgressive: Bool {
        return width > 0 && height > 0 && audioSampleRate > 0
    }

    var isH264: Bool {
        return mimeType.contains("avc1")
    }

    var isHDR: Bool {
        return false
    }

    /// Whether the track is in the video's original language rather than a dub.
    var isOriginal: Bool {
        let tags = StreamFormat.decodeTags(xtags)
        if let original = tags["acont"], !original.isEmpty {
            return original.lowercased() == "original"
        }
        if audioTrackIsAutoDubbed == true { return false }
        if let isDefault = audioTrackIsDefault { return isDefault }
        guard let trackId = audioTrackId else { return true }
        let suffix = trackId.components(separatedBy: ".").last ?? "4"
        return suffix == "4"
    }

    /// The language of a dubbed track, when YouTube names one.
    var audioLanguageTag: String? {
        if let trackId = audioTrackId, !trackId.isEmpty {
            let head = trackId.components(separatedBy: ".").first ?? ""
            if !head.isEmpty { return head }
        }
        let tags = StreamFormat.decodeTags(xtags)
        return tags["lang"]
    }

    /// Whether this is the dynamic-range-compressed copy of the track.
    var isDynamicRangeCompressed: Bool {
        if isDRC { return true }
        return StreamFormat.decodeTags(xtags)["drc"] == "1"
    }

    /// A human label for the quality menu — "1080p", "720p60", "High".
    var displayLabel: String {
        if !qualityLabel.isEmpty { return qualityLabel }
        if height > 0 {
            return fps > 30 ? "\(height)p\(fps)" : "\(height)p"
        }
        if !audioQuality.isEmpty { return audioQuality }
        return quality
    }

    /// Decodes the `xtags` query string YouTube attaches to a track.
    static func decodeTags(_ xtags: String) -> [String: String] {
        guard !xtags.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for pair in xtags.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            if parts.count == 2 {
                result[parts[0]] = parts[1]
            }
        }
        return result
    }
}

/// One subtitle track.
struct CaptionTrack {
    let baseUrl: String
    let name: String
    let languageCode: String
    /// True for YouTube's machine-generated track.
    let isAutomatic: Bool
    let isTranslatable: Bool
}

/// One chapter of a video, from the description or the macro-markers.
struct Chapter {
    let title: String
    let startTime: TimeInterval
    let endTime: TimeInterval?
    let thumbnailUrl: String?
}

/// A video's description, with the figures the watch page prints beside it.
struct VideoDescription {
    let text: String
    let viewCountText: String?
    let viewCount: Int64?
    let publishedDateText: String?
    let channelName: String?
    let channelId: String?
    let channelAvatarUrl: String?
    let subscriberCountText: String?
}

/// One page of comments.
struct CommentsPage {
    let comments: [Comment]
    let continuation: String?
    let totalText: String?
    let totalCount: Int64?
}

/// A channel's page header and its tabs.
struct ChannelPage {
    let channel: Channel
    let tabs: [ChannelTab]
    let homeSections: [VideoShelf]
    let videos: [Video]
    let shorts: [Video]
    let playlists: [Playlist]
    let videosContinuation: String?
    let shortsContinuation: String?
    let playlistsContinuation: String?
}

/// One tab of a channel page.
struct ChannelTab {
    let title: String
    let params: String?
}

/// A titled shelf of videos, which is what a channel's home tab and the subscriptions feed are made of.
struct VideoShelf {
    let title: String
    let subtitle: String?
    let items: [Video]
    let moreBrowseId: String?
}

/// A playlist's page.
struct PlaylistPage {
    let playlist: Playlist
    let videos: [Video]
    let continuation: String?
    let trackCount: Int?
}

/// A related-videos shelf, with the reason YouTube grouped it.
struct RelatedShelf {
    let title: String
    let videos: [Video]
}

/// The music home feed, which mixes songs, albums, playlists and artists in each shelf.
struct MusicHome {
    var sections: [HomeSection]
    var continuation: String?
}

/// An artist's page.
struct ArtistPage {
    let artist: ArtistItem
    let description: String?
    let subscriberCountText: String?
    let monthlyListenersText: String?
    let sections: [ArtistSection]
}

/// One shelf of an artist's page.
struct ArtistSection {
    let title: String
    let items: [MusicItem]
    let moreBrowseId: String?
}

/// An album's page.
struct AlbumPage {
    let album: AlbumItem
    let songs: [SongItem]
    let otherVersions: [AlbumItem]
    let durationText: String?
}

/// A music playlist's page.
struct MusicPlaylistPage {
    let playlist: PlaylistItem
    let songs: [SongItem]
    let continuation: String?
    let trackCount: Int?
}

/// One mood or genre button.
struct MoodAndGenre {
    let title: String
    let stripeColor: Int64
    let browseId: String
    let params: String?
}

/// One mood or genre group.
struct MoodAndGenreGroup {
    let title: String
    let items: [MoodAndGenre]
}

/// A lyric line, with the timestamp it starts at when the source is synchronised.
struct LyricLine {
    let text: String
    let startTime: TimeInterval?
    let endTime: TimeInterval?
}

/// A video's lyrics, synchronised when the source provides timings.
struct Lyrics {
    let lines: [LyricLine]
    let source: String
    let isSynchronised: Bool
}

/// One line of a transcript.
struct TranscriptLine {
    let text: String
    let startTime: TimeInterval
    let duration: TimeInterval
}
