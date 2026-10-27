import Foundation

/// Parses `/browse` responses: the main-site home feed, a channel's page, and a playlist.
///
/// Every walk here is defensive. YouTube ships several generations of the same renderer at once —
/// `richItemRenderer` beside `richGridRenderer`, `videoRenderer` beside `lockupViewModel` — and
/// which one arrives depends on the client and the day. A parser that recognised only one shape
/// would show an empty home screen the morning YouTube switched.
enum BrowseParser {

    // MARK: - Home feed

    /// The main-site home feed (`FEwhat_to_watch`), as shelves of videos.
    static func homeFeed(from root: JSONNode) -> (sections: [VideoShelf], continuation: String?) {
        let tabs = root["contents"]["twoColumnBrowseResultsRenderer"]["tabs"].array
            .isEmpty
            ? root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array
            : root["contents"]["twoColumnBrowseResultsRenderer"]["tabs"].array

        var sections: [VideoShelf] = []
        var continuation: String?

        for tab in tabs {
            let content = tab["tabRenderer"]["content"]
            let sectionList = content["sectionListRenderer"]
            let sectionNodes = sectionList["contents"].array
            if sectionNodes.isEmpty { continue }

            for node in sectionNodes {
                if let token = node["continuationItemRenderer"].continuationToken {
                    continuation = token
                    continue
                }
                for shelf in shelves(in: node) {
                    if let parsed = videoShelf(from: shelf) {
                        sections.append(parsed)
                    }
                }
            }
            if continuation == nil {
                continuation = JSONNode.firstContinuation(in: sectionList["contents"].array)
            }
            if !sections.isEmpty { break }
        }

        if sections.isEmpty {
            for node in root["contents"]["sectionListRenderer"]["contents"].array {
                if let token = node["continuationItemRenderer"].continuationToken {
                    continuation = token
                    continue
                }
                for shelf in shelves(in: node) {
                    if let parsed = videoShelf(from: shelf) {
                        sections.append(parsed)
                    }
                }
            }
        }

        return (sections, continuation)
    }

    /// The filter chips above the main-site home feed.
    static func homeChips(from root: JSONNode) -> [HomeChip] {
        let tabs = root["contents"]["twoColumnBrowseResultsRenderer"]["tabs"].array
            + root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array
        var chips: [HomeChip] = []
        for tab in tabs {
            let header = tab["tabRenderer"]["content"]["sectionListRenderer"]["header"]
            let chipCloud = header["chipCloudRenderer"]
            guard chipCloud.exists else { continue }
            for chip in chipCloud["chips"].array {
                let renderer = chip["chipCloudChipRenderer"]
                guard let title = renderer["text"].runTexts.first ?? renderer["text"].text else { continue }
                let browse = renderer["navigationEndpoint"]["browseEndpoint"]
                chips.append(HomeChip(
                    title: title,
                    browseId: browse["browseId"].string,
                    params: browse["params"].string,
                    deselectBrowseId: renderer["onDeselectedCommand"]["browseEndpoint"]["browseId"].string
                ))
            }
            if !chips.isEmpty { break }
        }
        return chips
    }

    /// A home continuation: the same shelves, appended to what the screen already shows.
    static func homeContinuation(from root: JSONNode) -> (sections: [VideoShelf], continuation: String?) {
        var sections: [VideoShelf] = []
        let continuationContents = root["continuationContents"]
        let sectionList = continuationContents["sectionListContinuation"]
        let nodes = sectionList["contents"].array.isEmpty
            ? continuationContents["richGridContinuation"]["contents"].array
            : sectionList["contents"].array

        for node in nodes {
            for shelf in shelves(in: node) {
                if let parsed = videoShelf(from: shelf) {
                    sections.append(parsed)
                }
            }
        }
        let token = JSONNode.firstContinuation(in: nodes)
            ?? root["onResponseReceivedActions"].array.compactMap { action in
                JSONNode.firstContinuation(in: action["appendContinuationItemsAction"]["continuationItems"].array)
            }.first
        return (sections, token)
    }

    /// Every shelf container a list entry can hold: a shelf directly, a rich section, or an item
    /// section with several children.
    private static func shelves(in node: JSONNode) -> [JSONNode] {
        if node["itemSectionRenderer"].exists {
            return node["itemSectionRenderer"]["contents"].array
        }
        if node["richSectionRenderer"].exists {
            return [node["richSectionRenderer"]["content"]]
        }
        if node["richItemRenderer"].exists {
            return [node["richItemRenderer"]["content"]]
        }
        return [node]
    }

    /// One video shelf, whatever renderer carried it.
    static func videoShelf(from node: JSONNode) -> VideoShelf? {
        // richGridRenderer — the modern home feed.
        let richGrid = node["richGridRenderer"]
        if richGrid.exists {
            let items = richGrid["contents"].array.compactMap { entry -> Video? in
                let content = entry["richItemRenderer"]["content"]
                return video(from: content)
            }
            guard !items.isEmpty else { return nil }
            return VideoShelf(title: "", subtitle: nil, items: items, moreBrowseId: nil)
        }

        // gridRenderer — a channel's videos tab.
        let grid = node["gridRenderer"]
        if grid.exists {
            let items = grid["items"].array.compactMap { video(from: $0) }
            guard !items.isEmpty else { return nil }
            let title = grid["header"]["gridHeaderRenderer"]["title"].text ?? ""
            return VideoShelf(title: title, subtitle: nil, items: items, moreBrowseId: nil)
        }

        // shelfRenderer — a titled carousel, which is what most home rows are.
        let shelf = node["shelfRenderer"]
        if shelf.exists {
            let title = shelf["title"].text ?? ""
            let subtitle = shelf["subtitle"].text
            let content = shelf["content"]
            var items: [Video] = []
            if content["horizontalListRenderer"].exists {
                for entry in content["horizontalListRenderer"]["items"].array {
                    if let parsed = video(from: entry["gridVideoRenderer"]) {
                        items.append(parsed)
                    } else if let parsed = video(from: entry) {
                        items.append(parsed)
                    }
                }
            } else if content["verticalListRenderer"].exists {
                for entry in content["verticalListRenderer"]["items"].array {
                    if let parsed = video(from: entry) {
                        items.append(parsed)
                    }
                }
            } else if content["gridRenderer"].exists {
                items = content["gridRenderer"]["items"].array.compactMap { video(from: $0) }
            } else if let parsed = video(from: content) {
                items.append(parsed)
            }
            let more = shelf["moreContentButton"]["buttonRenderer"]["navigationEndpoint"]["browseEndpoint"]["browseId"].string
            guard !items.isEmpty else { return nil }
            return VideoShelf(title: title, subtitle: subtitle, items: items, moreBrowseId: more)
        }

        // reelShelfRenderer — the Shorts row.
        let reelShelf = node["reelShelfRenderer"]
        if reelShelf.exists {
            let items = reelShelf["items"].array.compactMap { reel -> Video? in
                guard let parsed = video(from: reel["reelItemRenderer"]) else { return nil }
                var short = parsed
                short.isShort = true
                short.duration = 0
                return short
            }
            guard !items.isEmpty else { return nil }
            let title = reelShelf["title"].text ?? "Shorts"
            return VideoShelf(title: title, subtitle: nil, items: items, moreBrowseId: nil)
        }

        // A lone video renderer, which is how the first "continue watching" card arrives.
        if let single = video(from: node) {
            return VideoShelf(title: "", subtitle: nil, items: [single], moreBrowseId: nil)
        }
        return nil
    }

    // MARK: - Videos

    /// Reads a video out of any of the renderers that carry one.
    static func video(from node: JSONNode) -> Video? {
        if node["videoRenderer"].exists { return videoRenderer(node["videoRenderer"]) }
        if node["gridVideoRenderer"].exists { return gridVideoRenderer(node["gridVideoRenderer"]) }
        if node["compactVideoRenderer"].exists { return compactVideoRenderer(node["compactVideoRenderer"]) }
        if node["reelItemRenderer"].exists { return reelItemRenderer(node["reelItemRenderer"]) }
        if node["lockupViewModel"].exists { return lockup(node["lockupViewModel"]) }
        if node["playlistVideoRenderer"].exists { return playlistVideoRenderer(node["playlistVideoRenderer"]) }
        if node["videoWithContextRenderer"].exists { return videoWithContextRenderer(node["videoWithContextRenderer"]) }
        return nil
    }

    private static func videoRenderer(_ node: JSONNode) -> Video? {
        guard let id = node["videoId"].string, !id.isEmpty else { return nil }
        let title = node["title"].text ?? ""
        let channel = node["ownerText"].text
            ?? node["longBylineText"].text
            ?? node["shortBylineText"].text
            ?? ""
        let channelId = node["ownerText"]["runs"].array.first?["navigationEndpoint"]["browseEndpoint"]["browseId"].string
            ?? node["longBylineText"]["runs"].array.first?["navigationEndpoint"]["browseEndpoint"]["browseId"].string
            ?? ""
        let channelThumb = node["channelThumbnailSupportedRenderers"]["channelThumbnailWithLinkRenderer"]["thumbnail"].thumbnailURL
            ?? ""
        let durationText = node["lengthText"].text
        let viewsText = node["viewCountText"].text ?? node["shortViewCountText"].text
        let published = node["publishedTimeText"].text ?? ""
        let badges = node["badges"].array.compactMap { badge -> String? in
            let renderer = badge["metadataBadgeRenderer"]
            return renderer["label"].string ?? renderer["style"].string
        }
        let isLive = node["badges"].array.contains { badge in
            let style = badge["metadataBadgeRenderer"]["style"].string ?? ""
            return style.contains("LIVE") || style == "BADGE_STYLE_TYPE_LIVE_NOW"
        }
        let isUpcoming = node["upcomingEventData"].exists
        let descriptionSnippet = node["detailedMetadataSnippets"].array.first?["snippetText"].text
            ?? node["descriptionSnippet"].text
            ?? ""
        let isShort = (node["thumbnailOverlays"].array.contains { overlay in
            overlay["thumbnailOverlayTimeStatusRenderer"]["style"].string == "SHORTS"
        })

        return Video(
            id: id,
            title: title,
            channelName: channel,
            channelId: channelId,
            thumbnailUrl: node["thumbnail"].thumbnailURL ?? "",
            duration: isLive ? 0 : (InnerTubeParse.duration(from: durationText) ?? 0),
            viewCount: InnerTubeParse.count(from: viewsText) ?? 0,
            uploadDate: published,
            description: descriptionSnippet,
            channelThumbnailUrl: channelThumb,
            isLive: isLive,
            isShort: isShort,
            isUpcoming: isUpcoming,
            badges: badges,
            snippet: descriptionSnippet
        )
    }

    private static func gridVideoRenderer(_ node: JSONNode) -> Video? {
        guard let id = node["videoId"].string, !id.isEmpty else { return nil }
        let title = node["title"].text ?? ""
        let viewsText = node["viewCountText"].text ?? node["shortViewCountText"].text
        let published = node["publishedTimeText"].text ?? ""
        let isLive = node["thumbnailOverlays"].array.contains { overlay in
            overlay["thumbnailOverlayTimeStatusRenderer"]["style"].string == "LIVE"
        }
        return Video(
            id: id,
            title: title,
            channelName: node["shortBylineText"].text ?? "",
            channelId: node["shortBylineText"]["runs"].array.first?["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? "",
            thumbnailUrl: node["thumbnail"].thumbnailURL ?? "",
            duration: isLive ? 0 : (InnerTubeParse.duration(from: node["lengthText"].text) ?? 0),
            viewCount: InnerTubeParse.count(from: viewsText) ?? 0,
            uploadDate: published,
            isLive: isLive
        )
    }

    private static func compactVideoRenderer(_ node: JSONNode) -> Video? {
        guard let id = node["videoId"].string, !id.isEmpty else { return nil }
        let isLive = node["badges"].array.contains { badge in
            let style = badge["metadataBadgeRenderer"]["style"].string ?? ""
            return style.contains("LIVE")
        }
        return Video(
            id: id,
            title: node["title"].text ?? "",
            channelName: node["longBylineText"].text ?? node["shortBylineText"].text ?? "",
            channelId: node["longBylineText"]["runs"].array.first?["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? "",
            thumbnailUrl: node["thumbnail"].thumbnailURL ?? "",
            duration: isLive ? 0 : (InnerTubeParse.duration(from: node["lengthText"].text) ?? 0),
            viewCount: InnerTubeParse.count(from: node["shortViewCountText"].text) ?? 0,
            uploadDate: node["publishedTimeText"].text ?? "",
            isLive: isLive
        )
    }

    private static func reelItemRenderer(_ node: JSONNode) -> Video? {
        guard let id = node["videoId"].string, !id.isEmpty else { return nil }
        let viewsText = node["viewCountText"].text
        return Video(
            id: id,
            title: node["headline"].text ?? "",
            thumbnailUrl: node["thumbnail"].thumbnailURL ?? "",
            duration: 0,
            viewCount: InnerTubeParse.count(from: viewsText) ?? 0,
            isShort: true
        )
    }

    private static func playlistVideoRenderer(_ node: JSONNode) -> Video? {
        guard let id = node["videoId"].string, !id.isEmpty else { return nil }
        let isLive = node["badges"].array.contains { badge in
            let style = badge["metadataBadgeRenderer"]["style"].string ?? ""
            return style.contains("LIVE")
        }
        return Video(
            id: id,
            title: node["title"].text ?? "",
            channelName: node["shortBylineText"].text ?? "",
            channelId: node["shortBylineText"]["runs"].array.first?["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? "",
            thumbnailUrl: node["thumbnail"].thumbnailURL ?? "",
            duration: isLive ? 0 : (InnerTubeParse.duration(from: node["lengthText"].text) ?? 0),
            viewCount: InnerTubeParse.count(from: node["videoInfo"].text) ?? 0,
            isLive: isLive
        )
    }

    private static func videoWithContextRenderer(_ node: JSONNode) -> Video? {
        guard let id = node["videoId"].string, !id.isEmpty else { return nil }
        return Video(
            id: id,
            title: node["headline"].text ?? "",
            channelName: node["shortBylineText"].text ?? "",
            thumbnailUrl: node["thumbnail"].thumbnailURL ?? "",
            duration: InnerTubeParse.duration(from: node["lengthText"].text) ?? 0,
            viewCount: InnerTubeParse.count(from: node["shortViewCountText"].text) ?? 0,
            uploadDate: node["publishedTimeText"].text ?? ""
        )
    }

    /// The modern `lockupViewModel`, which the home feed and channel tabs have largely moved to.
    static func lockup(_ node: JSONNode) -> Video? {
        guard let id = node["contentId"].string, !id.isEmpty else { return nil }
        let metadata = node["metadata"]["lockupMetadataViewModel"]
        let title = metadata["title"].text ?? ""
        if title.isEmpty { return nil }

        let parts = metadataParts(metadata)
        let byline = lockupByline(metadata)
        let badges = node["contentImage"]["collectionThumbnailViewModel"]["primaryThumbnail"]["thumbnailViewModel"]["overlays"].array
            .flatMap { overlay -> [String] in
                overlay["thumbnailOverlayBadgeViewModel"]["thumbnailBadges"].array.compactMap { badge in
                    badge["thumbnailBadgeViewModel"]["text"].string
                }
            }
        let durationText = node["contentImage"]["collectionThumbnailViewModel"]["primaryThumbnail"]["thumbnailViewModel"]["overlays"].array
            .compactMap { overlay -> String? in
                let time = overlay["thumbnailOverlayTimeStatusRenderer"]["text"].text
                if let time = time { return time }
                return overlay["thumbnailOverlayBadgeViewModel"]["thumbnailBadges"].array
                    .compactMap { $0["thumbnailBadgeViewModel"]["text"].string }
                    .first { $0.contains(":") }
            }
            .first
        let isLive = badges.contains { $0.uppercased() == "LIVE" }
        let isUpcoming = !isLive && badges.contains { $0.lowercased().contains("upcoming") }

        let viewsText = parts.first { part in
            let lowered = part.lowercased()
            return lowered.contains("view") || lowered.contains("watching") || lowered.contains("no views")
        }
        let dateText = parts.first { part in
            let lowered = part.lowercased()
            return lowered.contains("ago") || lowered.contains("streamed") || lowered.contains("premiere")
        } ?? ""

        return Video(
            id: id,
            title: title,
            channelName: byline?.name ?? "",
            channelId: byline?.id ?? "",
            thumbnailUrl: node["contentImage"]["collectionThumbnailViewModel"]["primaryThumbnail"]["thumbnailViewModel"]["image"].thumbnailURL
                ?? node["contentImage"]["thumbnailViewModel"]["image"].thumbnailURL
                ?? "",
            duration: isLive || isUpcoming ? 0 : (InnerTubeParse.duration(from: durationText) ?? 0),
            viewCount: InnerTubeParse.count(from: viewsText) ?? 0,
            uploadDate: dateText,
            channelThumbnailUrl: byline?.avatarUrl ?? "",
            isLive: isLive,
            isShort: node["contentType"].string == "LOCKUP_CONTENT_TYPE_SHORTS",
            isUpcoming: isUpcoming,
            badges: badges
        )
    }

    /// The text parts of a lockup's metadata row.
    static func metadataParts(_ metadata: JSONNode) -> [String] {
        let rows = metadata["metadata"]["contentMetadataViewModel"]["metadataRows"].array
        var parts: [String] = []
        for row in rows {
            for part in row["metadataParts"].array {
                if let text = part["text"].text, !text.isEmpty {
                    parts.append(text)
                }
            }
        }
        return parts
    }

    /// The channel a lockup names as its byline, when it names one.
    static func lockupByline(_ metadata: JSONNode) -> (id: String, name: String, avatarUrl: String)? {
        let rows = metadata["metadata"]["contentMetadataViewModel"]["metadataRows"].array
        for row in rows {
            for part in row["metadataParts"].array {
                let browseId = part["text"]["commandRuns"].array.first?["onTap"]["innertubeCommand"]["browseEndpoint"]["browseId"].string
                if let browseId = browseId, browseId.hasPrefix("UC") {
                    let name = part["text"].text ?? ""
                    if !name.isEmpty {
                        return (browseId, name, "")
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Channels

    /// A channel's page: header, tabs, and whichever tab the response opened on.
    static func channelPage(from root: JSONNode, requestedId: String) -> ChannelPage {
        let header = channelHeader(from: root, requestedId: requestedId)
        let tabs = channelTabs(from: root)

        var homeSections: [VideoShelf] = []
        var videos: [Video] = []
        var shorts: [Video] = []
        var playlists: [Playlist] = []
        var videosContinuation: String?
        var shortsContinuation: String?
        var playlistsContinuation: String?

        let tabContents = root["contents"]["twoColumnBrowseResultsRenderer"]["tabs"].array
            + root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array

        for tab in tabContents {
            let content = tab["tabRenderer"]["content"]
            let sectionList = content["sectionListRenderer"]
            let isSelected = tab["tabRenderer"]["selected"].bool ?? false
            let tabTitle = (tab["tabRenderer"]["title"].string ?? "").lowercased()

            for node in sectionList["contents"].array {
                if let token = node["continuationItemRenderer"].continuationToken {
                    if tabTitle.contains("short") {
                        shortsContinuation = token
                    } else if tabTitle.contains("playlist") {
                        playlistsContinuation = token
                    } else {
                        videosContinuation = token
                    }
                    continue
                }
                for shelfNode in shelves(in: node) {
                    if let shelf = videoShelf(from: shelfNode) {
                        homeSections.append(shelf)
                        if tabTitle.contains("short") {
                            shorts.append(contentsOf: shelf.items)
                        } else if isSelected || tabTitle.contains("video") || tabTitle.isEmpty {
                            videos.append(contentsOf: shelf.items)
                        }
                    }
                    let grid = shelfNode["gridRenderer"]
                    if grid.exists {
                        let items = grid["items"].array.compactMap { video(from: $0) }
                        if tabTitle.contains("short") {
                            shorts.append(contentsOf: items)
                        } else {
                            videos.append(contentsOf: items)
                        }
                    }
                    if let playlist = playlist(from: shelfNode) {
                        playlists.append(playlist)
                    }
                }
            }
        }

        return ChannelPage(
            channel: header,
            tabs: tabs,
            homeSections: homeSections,
            videos: dedupe(videos),
            shorts: dedupe(shorts),
            playlists: playlists,
            videosContinuation: videosContinuation,
            shortsContinuation: shortsContinuation,
            playlistsContinuation: playlistsContinuation
        )
    }

    /// The channel header, read from whichever generation of it the response carries.
    static func channelHeader(from root: JSONNode, requestedId: String) -> Channel {
        let page = root["header"]["pageHeaderRenderer"]["content"]["pageHeaderViewModel"]
        let legacy = root["header"]["c4TabbedHeaderRenderer"]
        let metadata = root["metadata"]["channelMetadataRenderer"]
        let about = root["contents"]["twoColumnBrowseResultsRenderer"]["secondaryContents"]["sectionListRenderer"]["contents"]
            .array
            .compactMap { $0["itemSectionRenderer"]["contents"].array }
            .flatMap { $0 }
            .compactMap { $0["aboutChannelRenderer"]["metadata"]["aboutChannelViewModel"] }
            .first ?? .empty

        let rows = page["metadata"]["contentMetadataViewModel"]["metadataRows"].array.flatMap { row in
            row["metadataParts"].array.compactMap { $0["text"].text }
        }
        let handle = rows.first { $0.hasPrefix("@") }
            ?? metadata["vanityChannelUrl"].string.flatMap { url -> String? in
                let last = url.components(separatedBy: "/").last ?? ""
                return last.hasPrefix("@") ? last : nil
            }
            ?? ""
        let subscriberText = rows.first { $0.lowercased().contains("subscriber") }
            ?? legacy["subscriberCountText"].text
            ?? ""
        let videoText = rows.first { $0.lowercased().contains("video") && !$0.hasPrefix("@") }
            ?? legacy["videosCountText"].text
            ?? ""

        let title = page["title"]["dynamicTextViewModel"]["text"].text
            ?? metadata["title"].text
            ?? legacy["title"].text
            ?? ""

        let avatar = page["image"]["decoratedAvatarViewModel"]["avatar"]["avatarViewModel"]["image"].thumbnailURL
            ?? page["image"]["avatarViewModel"]["image"].thumbnailURL
            ?? metadata["avatar"].thumbnailURL
            ?? legacy["avatar"].thumbnailURL
            ?? ""
        let banner = page["banner"]["imageBannerViewModel"]["image"].thumbnailURL
            ?? legacy["banner"].thumbnailURL
            ?? ""

        let description = about["description"].text
            ?? metadata["description"].text
            ?? page["description"]["descriptionPreviewViewModel"]["description"].text
            ?? ""

        let isVerified = page["title"]["dynamicTextViewModel"]["text"]["commandRuns"].array.contains { run in
            run["onTap"]["innertubeCommand"]["showEngagementPanelEndpoint"].exists
        } || legacy["badges"].array.contains { badge in
            badge["metadataBadgeRenderer"]["style"].string == "BADGE_STYLE_TYPE_VERIFIED"
        }

        let id = metadata["externalChannelId"].string
            ?? metadata["externalId"].string
            ?? legacy["channelId"].string
            ?? requestedId

        let videoCount = Int(videoText.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0

        return Channel(
            id: id,
            name: title,
            thumbnailUrl: avatar,
            subscriberCount: InnerTubeParse.count(from: subscriberText) ?? 0,
            subscriberCountText: subscriberText,
            description: description,
            // The browse response never states the viewer's subscription; the store that knows
            // overlays it after parsing.
            isSubscribed: false,
            isMusic: false,
            handle: handle,
            videoCount: videoCount,
            isVerified: isVerified,
            bannerUrl: banner
        )
    }

    /// The tabs the channel publishes, in its own order.
    static func channelTabs(from root: JSONNode) -> [ChannelTab] {
        let tabs = root["contents"]["twoColumnBrowseResultsRenderer"]["tabs"].array
            + root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array
        var result: [ChannelTab] = []
        for tab in tabs {
            let renderer = tab["tabRenderer"]
            guard let title = renderer["title"].string, !title.isEmpty else { continue }
            let params = renderer["endpoint"]["browseEndpoint"]["params"].string
                ?? renderer["navigationEndpoint"]["browseEndpoint"]["params"].string
            result.append(ChannelTab(title: title, params: params))
        }
        if result.isEmpty {
            result = [
                ChannelTab(title: "Home", params: "EghmZWF0dXJlZPIGBAoCMgA="),
                ChannelTab(title: "Videos", params: "EgZ2aWRlb3PyBgQKAjoA"),
                ChannelTab(title: "Shorts", params: "EgZzaG9ydHPyBgUKA5oBAA=="),
                ChannelTab(title: "Playlists", params: "EglwbGF5bGlzdHPyBgoKCEIGCgIQaCIA"),
                ChannelTab(title: "About", params: nil),
            ]
        }
        return result
    }

    /// A channel tab's videos, from a browse response opened on that tab.
    static func channelVideos(from root: JSONNode) -> (videos: [Video], continuation: String?) {
        var videos: [Video] = []
        var continuation: String?
        let sectionList = root["contents"]["twoColumnBrowseResultsRenderer"]["tabs"].array.first?["tabRenderer"]["content"]["sectionListRenderer"]
            ?? root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array.first?["tabRenderer"]["content"]["sectionListRenderer"]
            ?? .empty
        for node in sectionList["contents"].array {
            if let token = node["continuationItemRenderer"].continuationToken {
                continuation = token
                continue
            }
            for shelfNode in shelves(in: node) {
                if let shelf = videoShelf(from: shelfNode) {
                    videos.append(contentsOf: shelf.items)
                }
                if shelfNode["gridRenderer"].exists {
                    videos.append(contentsOf: shelfNode["gridRenderer"]["items"].array.compactMap { video(from: $0) })
                }
            }
        }
        if videos.isEmpty {
            for node in root["onResponseReceivedActions"].array {
                for item in node["appendContinuationItemsAction"]["continuationItems"].array {
                    videos.append(contentsOf: item["gridItems"].array.compactMap { video(from: $0) })
                    videos.append(contentsOf: item["gridRenderer"]["items"].array.compactMap { video(from: $0) })
                }
            }
        }
        return (dedupe(videos), continuation)
    }

    // MARK: - Playlists

    /// A playlist's page: its header and its rows.
    static func playlistPage(from root: JSONNode, requestedId: String) -> PlaylistPage {
        let header = root["header"]["playlistHeaderRenderer"]
        let musicHeader = root["header"]["musicDetailHeaderRenderer"]
        let editableHeader = root["header"]["musicEditablePlaylistDetailHeaderRenderer"]

        let title = header["title"].text
            ?? musicHeader["title"].text
            ?? editableHeader["header"]["musicDetailHeaderRenderer"]["title"].text
            ?? ""
        let description = header["descriptionText"].text
            ?? musicHeader["description"].text
            ?? ""
        let author = header["ownerText"].text
            ?? musicHeader["subtitle"].text
            ?? ""
        let thumbnail = header["playlistHeaderBanner"]["heroPlaylistThumbnailRenderer"]["thumbnail"].thumbnailURL
            ?? musicHeader["thumbnail"].thumbnailURL
            ?? editableHeader["header"]["musicDetailHeaderRenderer"]["thumbnail"].thumbnailURL
            ?? ""
        let countText = header["numVideosText"].text
            ?? musicHeader["secondSubtitle"].text
            ?? ""
        let trackCount = Int(countText.components(separatedBy: CharacterSet.decimalDigits.inverted).joined())

        var videos: [Video] = []
        var continuation: String?

        let sectionList = root["contents"]["twoColumnBrowseResultsRenderer"]["secondaryContents"]["sectionListRenderer"]
        let singleColumn = root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array.first?["tabRenderer"]["content"]["sectionListRenderer"] ?? .empty
        let contents = sectionList["contents"].array.isEmpty ? singleColumn["contents"].array : sectionList["contents"].array

        for node in contents {
            if let token = node["continuationItemRenderer"].continuationToken {
                continuation = token
                continue
            }
            if node["playlistVideoListRenderer"].exists {
                let list = node["playlistVideoListRenderer"]
                for item in list["contents"].array {
                    if let token = item["continuationItemRenderer"].continuationToken {
                        continuation = token
                        continue
                    }
                    if let parsed = video(from: item) {
                        videos.append(parsed)
                    }
                }
            }
            if node["musicPlaylistShelfRenderer"].exists {
                let list = node["musicPlaylistShelfRenderer"]
                for item in list["contents"].array {
                    if let token = item["continuationItemRenderer"].continuationToken {
                        continuation = token
                        continue
                    }
                    if let parsed = video(from: item["musicResponsiveListItemRenderer"]) {
                        videos.append(parsed)
                    }
                }
            }
        }

        let playlist = Playlist(
            id: requestedId,
            name: title,
            thumbnailUrl: thumbnail,
            videoCount: trackCount ?? videos.count,
            description: description,
            videos: videos,
            isLocal: false,
            authorName: author
        )
        return PlaylistPage(
            playlist: playlist,
            videos: videos,
            continuation: continuation,
            trackCount: trackCount
        )
    }

    /// A playlist continuation.
    static func playlistContinuation(from root: JSONNode) -> (videos: [Video], continuation: String?) {
        var videos: [Video] = []
        var continuation: String?
        let list = root["continuationContents"]["playlistVideoListContinuation"]
        for item in list["contents"].array {
            if let token = item["continuationItemRenderer"].continuationToken {
                continuation = token
                continue
            }
            if let parsed = video(from: item) {
                videos.append(parsed)
            }
        }
        if videos.isEmpty {
            for item in root["continuationContents"]["musicPlaylistShelfContinuation"]["contents"].array {
                if let token = item["continuationItemRenderer"].continuationToken {
                    continuation = token
                    continue
                }
                if let parsed = video(from: item["musicResponsiveListItemRenderer"]) {
                    videos.append(parsed)
                }
            }
        }
        return (videos, continuation)
    }

    /// A playlist card, from any of the renderers that carry one.
    static func playlist(from node: JSONNode) -> Playlist? {
        if node["gridPlaylistRenderer"].exists {
            let renderer = node["gridPlaylistRenderer"]
            guard let id = renderer["playlistId"].string, !id.isEmpty else { return nil }
            let countText = renderer["videoCountText"].text ?? renderer["videoCountShortText"].text
            return Playlist(
                id: id,
                name: renderer["title"].text ?? "",
                thumbnailUrl: renderer["thumbnail"].thumbnailURL ?? "",
                videoCount: Int(countText?.components(separatedBy: CharacterSet.decimalDigits.inverted).joined() ?? "") ?? 0,
                isLocal: false,
                authorName: renderer["shortBylineText"].text ?? ""
            )
        }
        if node["lockupViewModel"].exists {
            let lockupNode = node["lockupViewModel"]
            let contentType = lockupNode["contentType"].string ?? ""
            guard contentType.contains("PLAYLIST") || contentType.contains("ALBUM") || contentType.contains("PODCAST") else {
                return nil
            }
            guard let id = lockupNode["contentId"].string, !id.isEmpty else { return nil }
            let metadata = lockupNode["metadata"]["lockupMetadataViewModel"]
            let badges = lockupNode["contentImage"]["collectionThumbnailViewModel"]["primaryThumbnail"]["thumbnailViewModel"]["overlays"].array
                .flatMap { $0["thumbnailOverlayBadgeViewModel"]["thumbnailBadges"].array }
                .compactMap { $0["thumbnailBadgeViewModel"]["text"].string }
            let countText = badges.first { $0.lowercased().contains("video") || $0.lowercased().contains("episode") }
            let count = Int(countText?.components(separatedBy: CharacterSet.decimalDigits.inverted).joined() ?? "") ?? 0
            return Playlist(
                id: id,
                name: metadata["title"].text ?? "",
                thumbnailUrl: lockupNode["contentImage"]["collectionThumbnailViewModel"]["primaryThumbnail"]["thumbnailViewModel"]["image"].thumbnailURL ?? "",
                videoCount: count,
                isLocal: false
            )
        }
        if node["playlistRenderer"].exists {
            let renderer = node["playlistRenderer"]
            guard let id = renderer["playlistId"].string, !id.isEmpty else { return nil }
            let countText = renderer["videoCount"].string
            return Playlist(
                id: id,
                name: renderer["title"].text ?? "",
                thumbnailUrl: renderer["thumbnails"].array.first?["thumbnails"].thumbnailURL ?? "",
                videoCount: Int(countText ?? "") ?? 0,
                isLocal: false,
                authorName: renderer["shortBylineText"].text ?? ""
            )
        }
        return nil
    }

    // MARK: - Suggestions

    /// The search suggestions YouTube returns as a JSONP array.
    static func suggestions(fromPayload payload: String) -> [String] {
        return InnerTubeClient.parseSuggestionsPayload(payload)
    }

    // MARK: - Helpers

    /// Removes duplicate videos, keeping the first occurrence so YouTube's ranking survives.
    private static func dedupe(_ videos: [Video]) -> [Video] {
        var seen: Set<String> = []
        var result: [Video] = []
        for video in videos where !seen.contains(video.id) {
            seen.insert(video.id)
            result.append(video)
        }
        return result
    }
}
