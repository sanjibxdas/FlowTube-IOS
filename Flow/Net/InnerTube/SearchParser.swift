import Foundation

/// Parses `/search` responses on both hosts.
///
/// The main-site response is a `tabbedSearchResultsRenderer` whose first tab holds a section list;
/// the music response is the same shape but every row is a `musicResponsiveListItemRenderer`. The
/// two are parsed by different functions because their rows carry different facts — a music row has
/// artists and an album, a video row has a channel and a view count.
enum SearchParser {

    // MARK: - Video search

    /// One page of main-site search results.
    static func videoResults(from root: JSONNode) -> VideoSearchResults {
        var videos: [Video] = []
        var channels: [Channel] = []
        var playlists: [Playlist] = []
        var continuation: String?
        var chips: [SearchChip] = []
        var estimated: Int64?

        let tabs = root["contents"]["tabbedSearchResultsRenderer"]["tabs"].array
        let sectionList = tabs.first?["tabRenderer"]["content"]["sectionListRenderer"] ?? .empty
        let contents = sectionList["contents"].array

        if let estimateText = sectionList["estimatedResults"].string {
            estimated = Int64(estimateText)
        }

        for node in contents {
            if let token = node["continuationItemRenderer"].continuationToken {
                continuation = token
                continue
            }
            if node["itemSectionRenderer"].exists {
                let section = node["itemSectionRenderer"]
                if let token = section["continuations"].array.first?.continuationToken {
                    continuation = token
                }
                for item in section["contents"].array {
                    collectSearchItem(item, videos: &videos, channels: &channels, playlists: &playlists)
                }
                continue
            }
            if node["chipCloudRenderer"].exists {
                chips.append(contentsOf: searchChips(from: node["chipCloudRenderer"]))
                continue
            }
            if let shelf = BrowseParser.videoShelf(from: node) {
                videos.append(contentsOf: shelf.items)
            }
            collectSearchItem(node, videos: &videos, channels: &channels, playlists: &playlists)
        }

        // A channel's home tab and the search page both wrap results in a rich grid.
        for node in contents {
            if node["richGridRenderer"].exists {
                for entry in node["richGridRenderer"]["contents"].array {
                    if let token = entry["continuationItemRenderer"].continuationToken {
                        continuation = token
                        continue
                    }
                    collectSearchItem(entry["richItemRenderer"]["content"], videos: &videos, channels: &channels, playlists: &playlists)
                }
            }
        }

        return VideoSearchResults(
            videos: dedupeVideos(videos),
            channels: channels,
            playlists: playlists,
            continuation: continuation,
            estimatedResults: estimated,
            chips: chips
        )
    }

    /// A continuation of main-site search results.
    static func videoContinuation(from root: JSONNode) -> VideoSearchResults {
        var videos: [Video] = []
        var channels: [Channel] = []
        var playlists: [Playlist] = []
        var continuation: String?

        let actions = root["onResponseReceivedActions"].array
        for action in actions {
            for item in action["appendContinuationItemsAction"]["continuationItems"].array {
                if let token = item["continuationItemRenderer"].continuationToken {
                    continuation = token
                    continue
                }
                collectSearchItem(item, videos: &videos, channels: &channels, playlists: &playlists)
                if let shelf = BrowseParser.videoShelf(from: item) {
                    videos.append(contentsOf: shelf.items)
                }
            }
        }

        if videos.isEmpty && channels.isEmpty && playlists.isEmpty {
            let contents = root["continuationContents"]["sectionListContinuation"]["contents"].array
            for item in contents {
                if let token = item["continuationItemRenderer"].continuationToken {
                    continuation = token
                    continue
                }
                collectSearchItem(item, videos: &videos, channels: &channels, playlists: &playlists)
            }
            if continuation == nil {
                continuation = JSONNode.firstContinuation(in: contents)
            }
        }

        return VideoSearchResults(
            videos: dedupeVideos(videos),
            channels: channels,
            playlists: playlists,
            continuation: continuation
        )
    }

    /// Reads one search result entry, putting it in the list that matches its renderer.
    private static func collectSearchItem(
        _ node: JSONNode,
        videos: inout [Video],
        channels: inout [Channel],
        playlists: inout [Playlist]
    ) {
        if node["videoRenderer"].exists || node["gridVideoRenderer"].exists
            || node["compactVideoRenderer"].exists || node["reelItemRenderer"].exists
            || node["videoWithContextRenderer"].exists {
            if let video = BrowseParser.video(from: node) {
                videos.append(video)
            }
            return
        }
        if node["channelRenderer"].exists {
            if let channel = channel(from: node["channelRenderer"]) {
                channels.append(channel)
            }
            return
        }
        if node["gridChannelRenderer"].exists {
            if let channel = channel(from: node["gridChannelRenderer"]) {
                channels.append(channel)
            }
            return
        }
        if let playlist = BrowseParser.playlist(from: node) {
            playlists.append(playlist)
            return
        }
        if node["lockupViewModel"].exists {
            let contentType = node["lockupViewModel"]["contentType"].string ?? ""
            if contentType.contains("CHANNEL") {
                if let channel = channelFromLockup(node["lockupViewModel"]) {
                    channels.append(channel)
                }
                return
            }
            if let video = BrowseParser.lockup(node["lockupViewModel"]) {
                videos.append(video)
            }
            return
        }
        if node["shelfRenderer"].exists {
            for item in node["shelfRenderer"]["content"]["horizontalListRenderer"]["items"].array {
                collectSearchItem(item, videos: &videos, channels: &channels, playlists: &playlists)
            }
            return
        }
    }

    private static func channel(from node: JSONNode) -> Channel? {
        guard let id = node["channelId"].string, !id.isEmpty else { return nil }
        let subscriberText = node["subscriberCountText"].text ?? node["videoCountText"].text ?? ""
        return Channel(
            id: id,
            name: node["title"].text ?? "",
            thumbnailUrl: node["thumbnail"].thumbnailURL ?? "",
            subscriberCount: InnerTubeParse.count(from: subscriberText) ?? 0,
            subscriberCountText: subscriberText,
            description: node["descriptionSnippet"].text ?? "",
            handle: node["subscriberCountText"].text?.hasPrefix("@") == true ? (node["subscriberCountText"].text ?? "") : "",
            videoCount: Int((node["videoCountText"].text ?? "").components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0,
            isVerified: node["ownerBadges"].array.contains { badge in
                badge["metadataBadgeRenderer"]["style"].string == "BADGE_STYLE_TYPE_VERIFIED"
            }
        )
    }

    private static func channelFromLockup(_ node: JSONNode) -> Channel? {
        guard let id = node["contentId"].string, !id.isEmpty else { return nil }
        let metadata = node["metadata"]["lockupMetadataViewModel"]
        let parts = BrowseParser.metadataParts(metadata)
        let subscriberText = parts.first { $0.lowercased().contains("subscriber") } ?? ""
        return Channel(
            id: id,
            name: metadata["title"].text ?? "",
            thumbnailUrl: node["contentImage"]["collectionThumbnailViewModel"]["primaryThumbnail"]["thumbnailViewModel"]["image"].thumbnailURL ?? "",
            subscriberCount: InnerTubeParse.count(from: subscriberText) ?? 0,
            subscriberCountText: subscriberText
        )
    }

    /// The refinement chips above the results.
    private static func searchChips(from node: JSONNode) -> [SearchChip] {
        var chips: [SearchChip] = []
        for chip in node["chips"].array {
            let renderer = chip["chipCloudChipRenderer"]
            guard let label = renderer["text"].text, !label.isEmpty else { continue }
            let selected = renderer["isSelected"].bool ?? false
            let token = renderer["navigationEndpoint"]["continuationCommand"]["token"].string
            let params = renderer["navigationEndpoint"]["searchEndpoint"]["params"].string
            chips.append(SearchChip(label: label, isSelected: selected, continuation: token, params: params))
        }
        return chips
    }

    // MARK: - Music search

    /// One page of music search results.
    static func musicResults(from root: JSONNode) -> MusicSearchResults {
        let tabs = root["contents"]["tabbedSearchResultsRenderer"]["tabs"].array
        let sectionList = tabs.first?["tabRenderer"]["content"]["sectionListRenderer"] ?? .empty
        var items: [MusicItem] = []
        var continuation: String?

        for node in sectionList["contents"].array {
            if let token = node["continuationItemRenderer"].continuationToken {
                continuation = token
                continue
            }
            if node["musicShelfRenderer"].exists {
                let shelf = node["musicShelfRenderer"]
                for entry in shelf["contents"].array {
                    if let token = entry["continuationItemRenderer"].continuationToken {
                        continuation = token
                        continue
                    }
                    if let item = MusicParser.item(from: entry["musicResponsiveListItemRenderer"]) {
                        items.append(item)
                    }
                }
                if continuation == nil {
                    continuation = JSONNode.firstContinuation(in: shelf["contents"].array)
                }
                continue
            }
            if node["musicCardShelfRenderer"].exists {
                items.append(contentsOf: MusicParser.cardShelfItems(node["musicCardShelfRenderer"]))
                continue
            }
            if node["musicCarouselShelfRenderer"].exists {
                items.append(contentsOf: MusicParser.carouselItems(node["musicCarouselShelfRenderer"]))
                continue
            }
        }

        if items.isEmpty {
            for node in root["contents"]["sectionListRenderer"]["contents"].array {
                if node["musicShelfRenderer"].exists {
                    for entry in node["musicShelfRenderer"]["contents"].array {
                        if let item = MusicParser.item(from: entry["musicResponsiveListItemRenderer"]) {
                            items.append(item)
                        }
                    }
                    if continuation == nil {
                        continuation = JSONNode.firstContinuation(in: node["musicShelfRenderer"]["contents"].array)
                    }
                }
            }
        }

        return MusicSearchResults(items: items, continuation: continuation)
    }

    /// A continuation of music search results.
    static func musicContinuation(from root: JSONNode) -> MusicSearchResults {
        var items: [MusicItem] = []
        var continuation: String?
        let shelf = root["continuationContents"]["musicShelfContinuation"]
        for entry in shelf["contents"].array {
            if let token = entry["continuationItemRenderer"].continuationToken {
                continuation = token
                continue
            }
            if let item = MusicParser.item(from: entry["musicResponsiveListItemRenderer"]) {
                items.append(item)
            }
        }
        if continuation == nil {
            continuation = JSONNode.firstContinuation(in: shelf["contents"].array)
        }
        return MusicSearchResults(items: items, continuation: continuation)
    }

    // MARK: - Helpers

    private static func dedupeVideos(_ videos: [Video]) -> [Video] {
        var seen: Set<String> = []
        var result: [Video] = []
        for video in videos where !seen.contains(video.id) {
            seen.insert(video.id)
            result.append(video)
        }
        return result
    }
}
