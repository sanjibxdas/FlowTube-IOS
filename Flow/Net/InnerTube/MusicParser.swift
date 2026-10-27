import Foundation

/// Parses YouTube Music's browse responses and the music rows inside search results.
///
/// Music rows come in two shapes: `musicResponsiveListItemRenderer`, a list row with flex columns,
/// and `musicTwoRowItemRenderer`, a card with a title and one subtitle line. Both describe songs,
/// albums, playlists and artists, and the only reliable way to tell which is the page type on the
/// navigation endpoint — the row's text is localized, the type is not.
enum MusicParser {

    // MARK: - Rows

    /// Reads one music row, whichever renderer it arrived in.
    static func item(from node: JSONNode) -> MusicItem? {
        if node["musicResponsiveListItemRenderer"].exists {
            return listItem(node["musicResponsiveListItemRenderer"])
        }
        if node["musicTwoRowItemRenderer"].exists {
            return twoRowItem(node["musicTwoRowItemRenderer"])
        }
        if node["musicResponsiveHeaderRenderer"].exists {
            return nil
        }
        if node["musicResponsiveListItemRenderer"].isMissing, node["title"].exists, node["navigationEndpoint"].exists {
            return twoRowItem(node)
        }
        return nil
    }

    /// The items of a `musicCardShelfRenderer`, which is the answer card above music search results.
    static func cardShelfItems(_ node: JSONNode) -> [MusicItem] {
        var items: [MusicItem] = []
        for entry in node["contents"].array {
            if let item = item(from: entry) {
                items.append(item)
            }
        }
        return items
    }

    /// The items of a `musicCarouselShelfRenderer`.
    static func carouselItems(_ node: JSONNode) -> [MusicItem] {
        var items: [MusicItem] = []
        for entry in node["contents"].array {
            if let item = item(from: entry) {
                items.append(item)
            }
        }
        return items
    }

    /// A `musicResponsiveListItemRenderer`, typed by its page type.
    static func listItem(_ renderer: JSONNode) -> MusicItem? {
        let pageType = musicPageType(renderer["navigationEndpoint"])
        let columns = flexColumns(renderer)

        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK":
            return albumItem(renderer, columns: columns)
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            return playlistItem(renderer, columns: columns)
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST":
            return artistItem(renderer, columns: columns, isProfile: false)
        case "MUSIC_PAGE_TYPE_USER_CHANNEL":
            return artistItem(renderer, columns: columns, isProfile: true)
        case "MUSIC_PAGE_TYPE_UNKNOWN":
            // The reduced search answer types artists and profiles alike as unknown; only an
            // artist carries a radio menu item.
            let browseId = renderer["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? ""
            if browseId.hasPrefix("UC"),
               renderer["navigationEndpoint"]["watchEndpoint"].isMissing,
               menuPlaylistEndpoint(renderer, iconType: "MIX") != nil {
                return artistItem(renderer, columns: columns, isProfile: false)
            }
            return songItem(renderer, columns: columns)
        default:
            return songItem(renderer, columns: columns)
        }
    }

    /// A `musicTwoRowItemRenderer`, typed by its page type.
    static func twoRowItem(_ renderer: JSONNode) -> MusicItem? {
        let pageType = musicPageType(renderer["navigationEndpoint"])
        let title = renderer["title"].runTexts.first ?? renderer["title"].text ?? ""
        guard !title.isEmpty else { return nil }
        let subtitleRuns = renderer["subtitle"]["runs"].array
        let thumbnail = thumbnailUrl(renderer["thumbnailRenderer"])
        let explicit = isExplicit(renderer)

        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK":
            let browseId = renderer["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? ""
            guard !browseId.isEmpty else { return nil }
            let playlistId = renderer["thumbnailOverlay"]["musicItemThumbnailOverlayRenderer"]["content"]["musicPlayButtonRenderer"]["playNavigationEndpoint"]["watchPlaylistEndpoint"]["playlistId"].string ?? ""
            let artists = subtitleRuns.count > 1
                ? oddElements(Array(subtitleRuns.dropFirst())).map { artist(from: $0) }
                : []
            return .album(AlbumItem(
                browseId: browseId,
                playlistId: playlistId,
                title: title,
                artists: artists,
                year: Int(subtitleRuns.last?["text"].string ?? ""),
                thumbnailUrl: thumbnail,
                isExplicit: explicit
            ))

        case "MUSIC_PAGE_TYPE_PLAYLIST":
            let browseId = renderer["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? ""
            guard !browseId.isEmpty else { return nil }
            let authorRun = subtitleRuns.first { $0["navigationEndpoint"]["browseEndpoint"].exists }
                ?? subtitleRuns.last
            return .playlist(PlaylistItem(
                id: browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId,
                title: title,
                authorName: authorRun?["text"].string,
                authorId: authorRun?["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
                thumbnailUrl: thumbnail
            ))

        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST":
            let browseId = renderer["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? ""
            guard !browseId.isEmpty else { return nil }
            return .artist(ArtistItem(
                id: browseId,
                title: title,
                thumbnailUrl: thumbnail,
                channelId: subscribeChannelId(renderer["menu"])
            ))

        default:
            guard renderer["navigationEndpoint"]["watchEndpoint"].exists || pageType.isEmpty else {
                return nil
            }
            let videoId = renderer["navigationEndpoint"]["watchEndpoint"]["videoId"].string ?? ""
            guard !videoId.isEmpty else { return nil }
            let artists = subtitleRuns
                .filter { ($0["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? "").hasPrefix("UC") }
                .map { artist(from: $0) }
            let albumRun = subtitleRuns.first {
                ($0["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? "").hasPrefix("MPREb_")
            }
            let viewText = subtitleRuns.first { run in
                let text = (run["text"].string ?? "").lowercased()
                return text.hasSuffix("views") || text.hasSuffix("view")
            }?["text"].string
            return .song(SongItem(
                id: videoId,
                title: title,
                artists: artists,
                albumName: albumRun?["text"].string,
                albumId: albumRun?["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
                musicVideoType: musicVideoType(renderer),
                thumbnailUrl: thumbnail,
                isExplicit: explicit,
                viewCountText: viewText
            ))
        }
    }

    // MARK: - Typed list rows

    private static func songItem(_ renderer: JSONNode, columns: [[JSONNode]]) -> MusicItem? {
        let videoId = renderer["playlistItemData"]["videoId"].string
            ?? renderer["overlay"]["musicItemThumbnailOverlayRenderer"]["content"]["musicPlayButtonRenderer"]["playNavigationEndpoint"]["watchEndpoint"]["videoId"].string
            ?? renderer["navigationEndpoint"]["watchEndpoint"]["videoId"].string
        guard let id = videoId, !id.isEmpty else { return nil }
        guard let title = firstText(columns, index: 0) else { return nil }

        var artists: [MusicArtist] = []
        if columns.count > 1 {
            let typed = columns[1].filter {
                ($0["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? "").hasPrefix("UC")
            }
            artists = (typed.isEmpty ? oddElements(columns[1]) : typed).map { artist(from: $0) }
        }

        let albumColumn = columns.count > 2 ? columns[2] : []
        let albumRun = albumColumn.first
        let durationText = renderer["fixedColumns"].array.first?["musicResponsiveListItemFlexColumnRenderer"]["text"]["runs"].array.first?["text"].string

        return .song(SongItem(
            id: id,
            title: title,
            artists: artists,
            albumName: albumRun?["text"].string,
            albumId: albumRun?["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
            duration: InnerTubeParse.duration(from: durationText),
            musicVideoType: musicVideoType(renderer),
            thumbnailUrl: thumbnailUrl(renderer["thumbnail"]),
            isExplicit: isExplicit(renderer),
            setVideoId: renderer["playlistItemData"]["playlistSetVideoId"].string
        ))
    }

    private static func albumItem(_ renderer: JSONNode, columns: [[JSONNode]]) -> MusicItem? {
        let browseId = renderer["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? ""
        guard !browseId.isEmpty, let title = firstText(columns, index: 0) else { return nil }
        let playlistId = renderer["overlay"]["musicItemThumbnailOverlayRenderer"]["content"]["musicPlayButtonRenderer"]["playNavigationEndpoint"]["watchPlaylistEndpoint"]["playlistId"].string ?? ""
        let artistRuns = columns.count > 1 ? columns[1] : []
        return .album(AlbumItem(
            browseId: browseId,
            playlistId: playlistId,
            title: title,
            artists: oddElements(artistRuns).map { artist(from: $0) },
            year: Int(artistRuns.last?["text"].string ?? ""),
            thumbnailUrl: thumbnailUrl(renderer["thumbnail"]),
            isExplicit: isExplicit(renderer)
        ))
    }

    private static func playlistItem(_ renderer: JSONNode, columns: [[JSONNode]]) -> MusicItem? {
        let browseId = renderer["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? ""
        guard !browseId.isEmpty, let title = firstText(columns, index: 0) else { return nil }
        let metadata = columns.count > 1 ? columns[1] : []
        let authorRun = metadata.first { $0["navigationEndpoint"]["browseEndpoint"].exists }
        return .playlist(PlaylistItem(
            id: browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId,
            title: title,
            authorName: authorRun?["text"].string ?? metadata.last?["text"].string,
            authorId: authorRun?["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
            songCountText: metadata.last?["text"].string,
            thumbnailUrl: thumbnailUrl(renderer["thumbnail"])
        ))
    }

    private static func artistItem(_ renderer: JSONNode, columns: [[JSONNode]], isProfile: Bool) -> MusicItem? {
        let browseId = renderer["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? ""
        guard !browseId.isEmpty, let title = firstText(columns, index: 0) else { return nil }
        let metadata = columns.count > 1 ? columns[1] : []
        return .artist(ArtistItem(
            id: browseId,
            title: title,
            thumbnailUrl: thumbnailUrl(renderer["thumbnail"]),
            channelId: subscribeChannelId(renderer["menu"]),
            subscriberCountText: metadata.first?["text"].string,
            isProfile: isProfile
        ))
    }

    // MARK: - Music home

    /// The music home feed.
    static func musicHome(from root: JSONNode) -> MusicHome {
        let sectionList = root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array
            .first?["tabRenderer"]["content"]["sectionListRenderer"] ?? .empty
        var sections: [HomeSection] = []
        for node in sectionList["contents"].array {
            if let section = homeSection(node["musicCarouselShelfRenderer"]) {
                sections.append(section)
            }
        }
        return MusicHome(sections: sections, continuation: JSONNode.firstContinuation(in: sectionList["contents"].array))
    }

    /// The chips above the music home feed.
    static func homeChips(from root: JSONNode) -> [HomeChip] {
        let sectionList = root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array
            .first?["tabRenderer"]["content"]["sectionListRenderer"] ?? .empty
        var chips: [HomeChip] = []
        for chip in sectionList["header"]["chipCloudRenderer"]["chips"].array {
            let renderer = chip["chipCloudChipRenderer"]
            guard let title = renderer["text"].runTexts.first ?? renderer["text"].text else { continue }
            let browse = renderer["navigationEndpoint"]["browseEndpoint"]
            let deselect = renderer["onDeselectedCommand"]["browseEndpoint"]
            chips.append(HomeChip(
                title: title,
                browseId: browse["browseId"].string,
                params: browse["params"].string,
                deselectBrowseId: deselect["browseId"].string
            ))
        }
        return chips
    }

    /// A continuation of the music home feed.
    static func homeContinuation(from root: JSONNode) -> MusicHome {
        let continuation = root["continuationContents"]["sectionListContinuation"]
        var sections: [HomeSection] = []
        for node in continuation["contents"].array {
            if let section = homeSection(node["musicCarouselShelfRenderer"]) {
                sections.append(section)
            }
        }
        return MusicHome(
            sections: sections,
            continuation: JSONNode.firstContinuation(in: continuation["contents"].array)
        )
    }

    private static func homeSection(_ node: JSONNode) -> HomeSection? {
        guard node.exists else { return nil }
        let header = node["header"]["musicCarouselShelfBasicHeaderRenderer"]
        guard let title = header["title"].runTexts.first ?? header["title"].text else { return nil }
        let items = carouselItems(node)
        guard !items.isEmpty else { return nil }
        return HomeSection(
            title: title,
            subtitle: header["strapline"].text,
            thumbnailUrl: thumbnailUrl(header["thumbnail"]),
            moreBrowseId: header["moreContentButton"]["buttonRenderer"]["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
            items: items
        )
    }

    // MARK: - Album

    /// An album's page.
    static func albumPage(from root: JSONNode, browseId: String) -> AlbumPage {
        let header = albumHeader(from: root)
        let title = header["title"].runTexts.first ?? header["title"].text ?? ""
        let subtitleRuns = header["subtitle"]["runs"].array
        let year = Int(subtitleRuns.last?["text"].string ?? "")
        let artists = header["straplineTextOne"]["runs"].array.isEmpty
            ? oddElements(separatorGroups(subtitleRuns).dropFirst().first ?? [])
            : oddElements(header["straplineTextOne"]["runs"].array)
        let playlistId = albumPlaylistId(from: root)
        let thumbnail = root["background"]["musicThumbnailRenderer"].thumbnailURL
            ?? root["background"]["musicThumbnailRenderer"]["thumbnail"].thumbnailURL
            ?? header["thumbnail"]["croppedSquareThumbnailRenderer"].thumbnailURL
            ?? header["thumbnail"].thumbnailURL
            ?? ""

        let album = AlbumItem(
            browseId: browseId,
            playlistId: playlistId,
            title: title,
            artists: artists.map { artist(from: $0) },
            year: year,
            thumbnailUrl: thumbnail,
            isExplicit: isExplicit(header)
        )

        let songs = albumSongs(from: root, album: album)
        let durationText = header["secondSubtitle"]["runs"].array.isEmpty
            ? nil
            : separatorGroups(header["secondSubtitle"]["runs"].array).last?.first?["text"].string

        return AlbumPage(
            album: album,
            songs: songs,
            otherVersions: otherVersions(from: root, album: album),
            durationText: durationText
        )
    }

    private static func albumHeader(from root: JSONNode) -> JSONNode {
        let tabs = root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array.isEmpty
            ? root["contents"]["twoColumnBrowseResultsRenderer"]["tabs"].array
            : root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array
        let section = tabs.first?["tabRenderer"]["content"]["sectionListRenderer"]["contents"].array.first
        if section?["musicResponsiveHeaderRenderer"].exists == true {
            return section?["musicResponsiveHeaderRenderer"] ?? .empty
        }
        return root["header"]["musicDetailHeaderRenderer"]
    }

    private static func albumPlaylistId(from root: JSONNode) -> String {
        if let canonical = root["microformat"]["microformatDataRenderer"]["urlCanonical"].string,
           let last = canonical.components(separatedBy: "=").last,
           !last.isEmpty {
            return last
        }
        return root["header"]["musicDetailHeaderRenderer"]["menu"]["menuRenderer"]["topLevelButtons"].array
            .first?["buttonRenderer"]["navigationEndpoint"]["watchPlaylistEndpoint"]["playlistId"].string ?? ""
    }

    private static func albumSongs(from root: JSONNode, album: AlbumItem) -> [SongItem] {
        let tabs = root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array.isEmpty
            ? root["contents"]["twoColumnBrowseResultsRenderer"]["tabs"].array
            : root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array
        var shelf = tabs.first?["tabRenderer"]["content"]["sectionListRenderer"]["contents"].array
            .first?["musicShelfRenderer"] ?? .empty
        if shelf.isMissing {
            shelf = root["contents"]["twoColumnBrowseResultsRenderer"]["secondaryContents"]["sectionListRenderer"]["contents"].array
                .first?["musicShelfRenderer"] ?? .empty
        }
        var songs: [SongItem] = []
        for entry in shelf["contents"].array {
            guard let item = listItem(entry["musicResponsiveListItemRenderer"]),
                  case .song(let song) = item else { continue }
            songs.append(SongItem(
                id: song.id,
                title: song.title,
                artists: song.artists.isEmpty ? album.artists : song.artists,
                albumName: album.title,
                albumId: album.browseId,
                duration: song.duration,
                musicVideoType: song.musicVideoType,
                thumbnailUrl: song.thumbnailUrl.isEmpty ? album.thumbnailUrl : song.thumbnailUrl,
                isExplicit: song.isExplicit,
                viewCountText: song.viewCountText,
                setVideoId: song.setVideoId
            ))
        }
        return songs
    }

    /// The album's other editions, which the secondary column carries as a carousel.
    private static func otherVersions(from root: JSONNode, album: AlbumItem) -> [AlbumItem] {
        let artistIds = Set(album.artists.compactMap { $0.id })
        guard !artistIds.isEmpty else { return [] }
        for shelf in root["contents"]["twoColumnBrowseResultsRenderer"]["secondaryContents"]["sectionListRenderer"]["contents"].array {
            let carousel = shelf["musicCarouselShelfRenderer"]
            guard carousel.exists else { continue }
            var versions: [AlbumItem] = []
            for entry in carousel["contents"].array {
                guard let item = twoRowItem(entry["musicTwoRowItemRenderer"]),
                      case .album(let version) = item else { continue }
                versions.append(version)
            }
            if !versions.isEmpty, versions.allSatisfy({ version in
                version.artists.contains { artist in
                    guard let id = artist.id else { return false }
                    return artistIds.contains(id)
                }
            }) {
                return versions
            }
        }
        return []
    }

    // MARK: - Artist

    /// An artist's page.
    static func artistPage(from root: JSONNode, browseId: String) -> ArtistPage {
        let immersive = root["header"]["musicImmersiveHeaderRenderer"]
        let visual = root["header"]["musicVisualHeaderRenderer"]
        let detail = root["header"]["musicDetailHeaderRenderer"]

        let title = immersive["title"].runTexts.first
            ?? visual["title"].runTexts.first
            ?? root["header"]["musicHeaderRenderer"]["title"].runTexts.first
            ?? ""
        let thumbnail = thumbnailUrl(immersive["thumbnail"])
            .isEmpty ? thumbnailUrl(visual["foregroundThumbnail"]) : thumbnailUrl(immersive["thumbnail"])
        let channelId = immersive["subscriptionButton"]["subscribeButtonRenderer"]["channelId"].string
        let subscriberText = immersive["subscriptionButton"]["subscribeButtonRenderer"]["subscriberCountText"].runTexts.first
        let monthlyText = immersive["monthlyListenerCount"].runTexts.first
        let description = immersive["description"].runTexts.joined()

        let artist = ArtistItem(
            id: browseId,
            title: title,
            thumbnailUrl: thumbnail.isEmpty ? thumbnailUrl(detail["thumbnail"]) : thumbnail,
            channelId: channelId,
            subscriberCountText: subscriberText
        )

        let sectionContents = root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array
            .first?["tabRenderer"]["content"]["sectionListRenderer"]["contents"].array ?? []
        var sections: [ArtistSection] = []
        for content in sectionContents {
            if let section = artistSection(content) {
                sections.append(section)
            }
        }

        return ArtistPage(
            artist: artist,
            description: description.isEmpty ? nil : description,
            subscriberCountText: subscriberText,
            monthlyListenersText: monthlyText,
            sections: sections
        )
    }

    private static func artistSection(_ content: JSONNode) -> ArtistSection? {
        if content["musicShelfRenderer"].exists {
            let shelf = content["musicShelfRenderer"]
            let title = shelf["title"].runTexts.first ?? shelf["title"].text ?? ""
            var items: [MusicItem] = []
            for entry in shelf["contents"].array {
                if let item = item(from: entry) {
                    items.append(item)
                }
            }
            guard !items.isEmpty else { return nil }
            return ArtistSection(
                title: title,
                items: items,
                moreBrowseId: shelf["title"]["runs"].array.first?["navigationEndpoint"]["browseEndpoint"]["browseId"].string
            )
        }
        if content["musicCarouselShelfRenderer"].exists {
            let carousel = content["musicCarouselShelfRenderer"]
            let header = carousel["header"]["musicCarouselShelfBasicHeaderRenderer"]
            guard let title = header["title"].runTexts.first ?? header["title"].text else { return nil }
            let items = carouselItems(carousel)
            guard !items.isEmpty else { return nil }
            return ArtistSection(
                title: title,
                items: items,
                moreBrowseId: header["moreContentButton"]["buttonRenderer"]["navigationEndpoint"]["browseEndpoint"]["browseId"].string
            )
        }
        return nil
    }

    // MARK: - Music playlist

    /// A music playlist's page.
    static func musicPlaylistPage(from root: JSONNode, playlistId: String) -> MusicPlaylistPage {
        let header = root["header"]["musicDetailHeaderRenderer"].exists
            ? root["header"]["musicDetailHeaderRenderer"]
            : root["header"]["musicResponsiveHeaderRenderer"]
        let title = header["title"].runTexts.first ?? header["title"].text ?? ""
        let authorRun = header["subtitle"]["runs"].array.first {
            $0["navigationEndpoint"]["browseEndpoint"]["browseId"].string != nil
        }
        let secondSubtitle = separatorGroups(header["secondSubtitle"]["runs"].array)
        let trackCount = secondSubtitle.count >= 2
            ? Int(secondSubtitle[secondSubtitle.count - 2].compactMap { $0["text"].string }.joined().filter { $0.isNumber })
            : nil

        let playlist = PlaylistItem(
            id: playlistId,
            title: title,
            authorName: authorRun?["text"].string,
            authorId: authorRun?["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
            songCountText: trackCount.map { String($0) },
            thumbnailUrl: thumbnailUrl(header["thumbnail"])
        )

        let sectionContents = root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array
            .first?["tabRenderer"]["content"]["sectionListRenderer"]["contents"].array ?? []
        var songs: [SongItem] = []
        var continuation: String?
        for content in sectionContents {
            if content["musicShelfRenderer"].exists {
                let shelf = content["musicShelfRenderer"]
                for entry in shelf["contents"].array {
                    if entry["continuationItemRenderer"].exists {
                        continuation = entry.continuationToken
                        continue
                    }
                    guard let item = item(from: entry), case .song(let song) = item else { continue }
                    songs.append(song)
                }
                if continuation == nil {
                    continuation = JSONNode.firstContinuation(in: shelf["contents"].array)
                }
            }
            if content["musicPlaylistShelfRenderer"].exists {
                let shelf = content["musicPlaylistShelfRenderer"]
                for entry in shelf["contents"].array {
                    if entry["continuationItemRenderer"].exists {
                        continuation = entry.continuationToken
                        continue
                    }
                    guard let item = item(from: entry), case .song(let song) = item else { continue }
                    songs.append(song)
                }
                if continuation == nil {
                    continuation = JSONNode.firstContinuation(in: shelf["contents"].array)
                }
            }
        }

        return MusicPlaylistPage(
            playlist: playlist,
            songs: songs,
            continuation: continuation,
            trackCount: trackCount
        )
    }

    /// A continuation of a music playlist's songs.
    static func musicPlaylistContinuation(from root: JSONNode) -> (songs: [SongItem], continuation: String?) {
        let shelf = root["continuationContents"]["musicPlaylistShelfContinuation"].exists
            ? root["continuationContents"]["musicPlaylistShelfContinuation"]
            : root["continuationContents"]["musicShelfContinuation"]
        var songs: [SongItem] = []
        var continuation: String?
        for entry in shelf["contents"].array {
            if entry["continuationItemRenderer"].exists {
                continuation = entry.continuationToken
                continue
            }
            guard let item = item(from: entry), case .song(let song) = item else { continue }
            songs.append(song)
        }
        if continuation == nil {
            continuation = JSONNode.firstContinuation(in: shelf["contents"].array)
        }
        return (songs, continuation)
    }

    // MARK: - Moods and genres

    /// The mood and genre groups on the explore surface.
    static func moodsAndGenres(from root: JSONNode) -> [MoodAndGenreGroup] {
        let contents = root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array
            .first?["tabRenderer"]["content"]["sectionListRenderer"]["contents"].array ?? []
        var groups: [MoodAndGenreGroup] = []
        for content in contents {
            let grid = content["gridRenderer"]
            guard grid.exists else { continue }
            guard let title = grid["header"]["gridHeaderRenderer"]["title"].runTexts.first
                ?? grid["header"]["gridHeaderRenderer"]["title"].text else { continue }
            var items: [MoodAndGenre] = []
            for entry in grid["items"].array {
                let button = entry["musicNavigationButtonRenderer"]
                guard button.exists else { continue }
                guard let label = button["buttonText"].runTexts.first ?? button["buttonText"].text else { continue }
                guard let stripe = button["solid"]["leftStripeColor"].int64 else { continue }
                guard let browseId = button["clickCommand"]["browseEndpoint"]["browseId"].string else { continue }
                items.append(MoodAndGenre(
                    title: label,
                    stripeColor: stripe,
                    browseId: browseId,
                    params: button["clickCommand"]["browseEndpoint"]["params"].string
                ))
            }
            if !items.isEmpty {
                groups.append(MoodAndGenreGroup(title: title, items: items))
            }
        }
        return groups
    }

    // MARK: - Lyrics

    /// The browse id of the lyrics tab on a music watch-next response, found by prefix because
    /// YouTube reorders the tabs.
    static func lyricsBrowseId(fromNext root: JSONNode) -> String? {
        let tabs = root["contents"]["singleColumnMusicWatchNextResultsRenderer"]["tabbedRenderer"]["watchNextTabbedResultsRenderer"]["tabs"].array
        for tab in tabs {
            let browseId = tab["tabRenderer"]["endpoint"]["browseEndpoint"]["browseId"].string ?? ""
            if browseId.hasPrefix("MPLYt") {
                return browseId
            }
        }
        return nil
    }

    /// The lyrics text from the lyrics browse response.
    static func lyrics(from root: JSONNode) -> Lyrics? {
        let shelf = root["contents"]["sectionListRenderer"]["contents"].array
            .first?["musicDescriptionShelfRenderer"] ?? .empty
        guard let text = shelf["description"].runTexts.first ?? shelf["description"].text, !text.isEmpty else {
            return nil
        }
        let lines = text.components(separatedBy: "\n").compactMap { raw -> LyricLine? in
            let trimmed = raw.trimmed
            guard !trimmed.isEmpty else { return nil }
            return LyricLine(text: trimmed, startTime: nil, endTime: nil)
        }
        return Lyrics(lines: lines, source: "YouTube Music", isSynchronised: false)
    }

    // MARK: - Shared readers

    /// The music page type on a navigation endpoint, or an empty string when it has none.
    static func musicPageType(_ endpoint: JSONNode) -> String {
        return endpoint["browseEndpoint"]["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string ?? ""
    }

    /// The runs of each flex column, in column order.
    static func flexColumns(_ renderer: JSONNode) -> [[JSONNode]] {
        return renderer["flexColumns"].array.map {
            $0["musicResponsiveListItemFlexColumnRenderer"]["text"]["runs"].array
        }
    }

    /// The first run's text in a column.
    private static func firstText(_ columns: [[JSONNode]], index: Int) -> String? {
        guard columns.count > index else { return nil }
        return columns[index].first?["text"].string
    }

    /// Splits runs at the ` • ` separators YouTube inserts between facts.
    static func separatorGroups(_ runs: [JSONNode]) -> [[JSONNode]] {
        var groups: [[JSONNode]] = []
        var current: [JSONNode] = []
        for run in runs {
            if run["text"].string == " • " {
                groups.append(current)
                current = []
            } else {
                current.append(run)
            }
        }
        groups.append(current)
        return groups
    }

    /// Every other run, which is how a byline separates names from the separators between them.
    static func oddElements(_ runs: [JSONNode]) -> [JSONNode] {
        var result: [JSONNode] = []
        for (index, run) in runs.enumerated() where index % 2 == 0 {
            result.append(run)
        }
        return result
    }

    private static func artist(from run: JSONNode) -> MusicArtist {
        return MusicArtist(
            name: run["text"].string ?? "",
            id: run["navigationEndpoint"]["browseEndpoint"]["browseId"].string
        )
    }

    /// A thumbnail from any of the thumbnail renderers a music row uses.
    private static func thumbnailUrl(_ node: JSONNode) -> String {
        if let music = node["musicThumbnailRenderer"].thumbnailURL { return music }
        if let music = node["musicThumbnailRenderer"]["thumbnail"].thumbnailURL { return music }
        if let cropped = node["croppedSquareThumbnailRenderer"].thumbnailURL { return cropped }
        if let direct = node.thumbnailURL { return direct }
        return ""
    }

    private static func isExplicit(_ node: JSONNode) -> Bool {
        let badges = node["badges"].array + node["subtitleBadges"].array
        return badges.contains { badge in
            badge["musicInlineBadgeRenderer"]["icon"]["iconType"].string == "MUSIC_EXPLICIT_BADGE"
        }
    }

    private static func musicVideoType(_ renderer: JSONNode) -> String? {
        return renderer["overlay"]["musicItemThumbnailOverlayRenderer"]["content"]["musicPlayButtonRenderer"]["playNavigationEndpoint"]["musicVideoType"].string
            ?? renderer["navigationEndpoint"]["musicVideoType"].string
    }

    /// The playlist a menu item with the given icon plays, such as `MUSIC_SHUFFLE` or `MIX`.
    static func menuPlaylistEndpoint(_ renderer: JSONNode, iconType: String) -> String? {
        for item in renderer["menu"]["menuRenderer"]["items"].array {
            let navigation = item["menuNavigationItemRenderer"]
            guard navigation["icon"]["iconType"].string == iconType else { continue }
            return navigation["navigationEndpoint"]["watchPlaylistEndpoint"]["playlistId"].string
        }
        return nil
    }

    private static func subscribeChannelId(_ menu: JSONNode) -> String? {
        for item in menu["menuRenderer"]["items"].array {
            let toggle = item["toggleMenuServiceItemRenderer"]
            guard toggle["defaultIcon"]["iconType"].string == "SUBSCRIBE" else { continue }
            return toggle["defaultServiceEndpoint"]["subscribeEndpoint"]["channelIds"].array.first?.string
        }
        return nil
    }
}
