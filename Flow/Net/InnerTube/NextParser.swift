import Foundation

/// Parses `/next` responses: the watch page's metadata, its related shelf, its chapters, and the
/// comment section's continuation and pages.
///
/// The comment section is the awkward part. YouTube no longer puts comment text in the renderers —
/// a `commentThreadRenderer` names an entity key, and the text lives in `frameworkUpdates`, a
/// sibling object keyed by that name. Both are read here, and a missing payload drops the comment
/// rather than producing a blank row.
enum NextParser {

    // MARK: - Watch page

    /// The metadata the watch page shows beside the player.
    static func watchMetadata(from root: JSONNode, videoId: String) -> (video: Video, description: VideoDescription, chapters: [Chapter]) {
        let results = root["contents"]["twoColumnWatchNextResults"]["results"]["results"]["contents"].array
        let primary = results.first { $0["videoPrimaryInfoRenderer"].exists }?["videoPrimaryInfoRenderer"] ?? .empty
        let secondary = results.first { $0["videoSecondaryInfoRenderer"].exists }?["videoSecondaryInfoRenderer"] ?? .empty

        let title = primary["title"].text ?? ""
        let viewCountNode = primary["viewCount"]["videoViewCountRenderer"]
        let viewCountText = viewCountNode["viewCount"].text
        let originalViewCount = Int64(viewCountNode["originalViewCount"].string ?? "")
        let viewCount = originalViewCount ?? InnerTubeParse.count(from: viewCountText) ?? 0
        let published = primary["dateText"].text ?? ""

        let owner = secondary["owner"]["videoOwnerRenderer"]
        let channelName = owner["title"].text ?? ""
        let channelId = owner["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? ""
        let channelAvatar = owner["thumbnail"].thumbnailURL ?? ""
        let subscriberText = owner["subscriberCountText"].text ?? ""

        let descriptionText = secondary["attributedDescription"]["content"].string
            ?? secondary["description"]["runs"].array.compactMap { $0["text"].string }.joined()
            ?? ""

        let likeButton = primary["videoActions"]["menuRenderer"]["topLevelButtons"].array
            .first { $0["segmentedLikeDislikeButtonViewModel"].exists || $0["segmentedLikeDislikeButtonRenderer"].exists }
        let likeCount = likeButton.map(likeCountFrom) ?? 0

        let isLive = primary["badges"].array.contains { badge in
            let style = badge["metadataBadgeRenderer"]["style"].string ?? ""
            return style.contains("LIVE")
        }
        let isUpcoming = primary["badges"].array.contains { badge in
            (badge["metadataBadgeRenderer"]["label"].string ?? "").lowercased().contains("upcoming")
        }

        let description = VideoDescription(
            text: descriptionText,
            viewCountText: viewCountText,
            viewCount: viewCount,
            publishedDateText: published,
            channelName: channelName,
            channelId: channelId,
            channelAvatarUrl: channelAvatar,
            subscriberCountText: subscriberText
        )

        let video = Video(
            id: videoId,
            title: title,
            channelName: channelName,
            channelId: channelId,
            thumbnailUrl: "",
            duration: 0,
            viewCount: viewCount,
            likeCount: likeCount,
            uploadDate: published,
            description: descriptionText,
            channelThumbnailUrl: channelAvatar,
            isLive: isLive,
            isUpcoming: isUpcoming
        )

        return (video, description, chapters(from: root))
    }

    /// The like count from the segmented like/dislike button, which nests it two levels deep.
    private static func likeCountFrom(_ node: JSONNode) -> Int64 {
        let viewModel = node["segmentedLikeDislikeButtonViewModel"]["likeButtonViewModel"]["likeButtonViewModel"]
        let text = viewModel["toggleButtonViewModel"]["toggleButtonViewModel"]["defaultButtonViewModel"]["buttonViewModel"]["title"].string
            ?? viewModel["toggleButtonViewModel"]["toggleButtonViewModel"]["defaultButtonViewModel"]["buttonViewModel"]["accessibilityText"].string
            ?? node["segmentedLikeDislikeButtonRenderer"]["likeButton"]["toggleButtonRenderer"]["defaultText"]["accessibility"]["accessibilityData"]["label"].string
        return InnerTubeParse.count(from: text) ?? 0
    }

    /// A video's chapters, from the macro-markers engagement panel.
    static func chapters(from root: JSONNode) -> [Chapter] {
        let panels = root["engagementPanels"].array
        for panel in panels {
            let renderer = panel["engagementPanelSectionListRenderer"]
            let identifier = renderer["panelIdentifier"].string ?? ""
            guard identifier.contains("macro-markers") || identifier.contains("chapters") else { continue }
            let items = renderer["content"]["macroMarkersListRenderer"]["contents"].array
            var chapters: [Chapter] = []
            for item in items {
                let marker = item["macroMarkersListItemRenderer"]
                guard let title = marker["title"].text, !title.isEmpty else { continue }
                guard let start = marker["onTap"]["watchEndpoint"]["startTimeSeconds"].int, start >= 0 else { continue }
                chapters.append(Chapter(
                    title: title,
                    startTime: TimeInterval(start),
                    endTime: nil,
                    thumbnailUrl: marker["thumbnail"].thumbnailURL
                ))
            }
            if chapters.isEmpty { continue }
            let sorted = chapters.sorted { $0.startTime < $1.startTime }
            var withEnds: [Chapter] = []
            for (index, chapter) in sorted.enumerated() {
                let end: TimeInterval?
                if index + 1 < sorted.count {
                    end = sorted[index + 1].startTime
                } else {
                    end = nil
                }
                withEnds.append(Chapter(
                    title: chapter.title,
                    startTime: chapter.startTime,
                    endTime: end,
                    thumbnailUrl: chapter.thumbnailUrl
                ))
            }
            return withEnds
        }
        return []
    }

    /// The related videos shelf, in the order YouTube arranged it.
    static func related(from root: JSONNode) -> [Video] {
        var videos: [Video] = []
        let secondary = root["contents"]["twoColumnWatchNextResults"]["secondaryResults"]["secondaryResults"]["results"].array
        for item in secondary {
            if item["compactVideoRenderer"].exists {
                if let video = BrowseParser.video(from: item) {
                    videos.append(video)
                }
                continue
            }
            if item["lockupViewModel"].exists {
                if let video = BrowseParser.lockup(item["lockupViewModel"]) {
                    videos.append(video)
                }
                continue
            }
            if item["compactPlaylistRenderer"].exists {
                continue
            }
            if item["continuationItemRenderer"].exists {
                continue
            }
        }
        if videos.isEmpty {
            // The autoplay/related list on some clients arrives as a playlist panel.
            let panel = root["contents"]["twoColumnWatchNextResults"]["playlist"]["playlist"]["contents"].array
            for item in panel {
                if let video = BrowseParser.video(from: item["playlistPanelVideoRenderer"]) {
                    videos.append(video)
                }
            }
        }
        var seen: Set<String> = []
        var result: [Video] = []
        for video in videos where !seen.contains(video.id) {
            seen.insert(video.id)
            result.append(video)
        }
        return result
    }

    /// The continuation that loads the comment section.
    static func commentsContinuation(from root: JSONNode) -> String? {
        let results = root["contents"]["twoColumnWatchNextResults"]["results"]["results"]["contents"].array
        for entry in results {
            let section = entry["itemSectionRenderer"]
            guard section["sectionIdentifier"].string == "comment-item-section" else { continue }
            for item in section["contents"].array {
                if let token = item["continuationItemRenderer"].continuationToken {
                    return token
                }
            }
        }
        return nil
    }

    // MARK: - Comments

    /// A page of comments, from a `next` response whose continuation was the comment token.
    static func comments(from root: JSONNode) -> CommentsPage {
        let mutations = commentMutations(from: root)
        let items = continuationItems(from: root)

        let header = items.first { $0["commentsHeaderRenderer"].exists }?["commentsHeaderRenderer"] ?? .empty
        let totalText = header["commentsCount"].text
        let totalCount = InnerTubeParse.count(from: header["countText"].text)

        var comments: [Comment] = []
        var continuation: String?

        for item in items {
            if item["commentThreadRenderer"].exists {
                if let comment = commentThread(item["commentThreadRenderer"], mutations: mutations) {
                    comments.append(comment)
                }
                continue
            }
            if item["commentViewModel"].exists {
                if let comment = modernComment(item["commentViewModel"], mutations: mutations) {
                    comments.append(comment)
                }
                continue
            }
            if let token = item["continuationItemRenderer"].continuationToken {
                continuation = token
            }
        }

        var seen: Set<String> = []
        var unique: [Comment] = []
        for comment in comments where !seen.contains(comment.id) {
            seen.insert(comment.id)
            unique.append(comment)
        }

        return CommentsPage(
            comments: unique,
            continuation: continuation,
            totalText: totalText,
            totalCount: totalCount
        )
    }

    /// A page of one comment's replies.
    static func commentReplies(from root: JSONNode) -> CommentsPage {
        let mutations = commentMutations(from: root)
        let items = continuationItems(from: root)
        var comments: [Comment] = []
        var continuation: String?
        for item in items {
            if item["commentViewModel"].exists {
                if let comment = modernComment(item["commentViewModel"], mutations: mutations) {
                    comments.append(comment)
                }
                continue
            }
            if item["commentThreadRenderer"].exists {
                if let comment = commentThread(item["commentThreadRenderer"], mutations: mutations) {
                    comments.append(comment)
                }
                continue
            }
            if let token = item["continuationItemRenderer"].continuationToken {
                continuation = token
            }
        }
        return CommentsPage(comments: comments, continuation: continuation, totalText: nil, totalCount: nil)
    }

    /// The items of every reload and append command in a comment response.
    private static func continuationItems(from root: JSONNode) -> [JSONNode] {
        var items: [JSONNode] = []
        for endpoint in root["onResponseReceivedEndpoints"].array {
            if endpoint["reloadContinuationItemsCommand"].exists {
                items.append(contentsOf: endpoint["reloadContinuationItemsCommand"]["continuationItems"].array)
            }
            if endpoint["appendContinuationItemsAction"].exists {
                items.append(contentsOf: endpoint["appendContinuationItemsAction"]["continuationItems"].array)
            }
        }
        if items.isEmpty {
            items = root["continuationContents"]["commentThreadRenderer"].array
            if items.isEmpty {
                items = root["continuationContents"]["itemSectionContinuation"]["contents"].array
            }
        }
        return items
    }

    /// The entity payloads a comment response's keys resolve to.
    private static func commentMutations(from root: JSONNode) -> [String: JSONNode] {
        var result: [String: JSONNode] = [:]
        let mutations = root["frameworkUpdates"]["entityBatchUpdate"]["mutations"].array
        for mutation in mutations {
            guard let key = mutation["entityKey"].string else { continue }
            result[key] = mutation["payload"]
        }
        return result
    }

    /// One thread, which carries the comment itself plus its reply count and continuation.
    private static func commentThread(_ thread: JSONNode, mutations: [String: JSONNode]) -> Comment? {
        let repliesRenderer = thread["replies"]["commentRepliesRenderer"]
        var comment: Comment?
        if thread["commentViewModel"].exists {
            comment = modernComment(thread["commentViewModel"], mutations: mutations)
        } else if thread["comment"]["commentRenderer"].exists {
            comment = legacyComment(thread["comment"]["commentRenderer"])
        }
        guard var result = comment else { return nil }
        if let token = repliesRenderer["contents"].array.first?["continuationItemRenderer"].continuationToken
            ?? repliesRenderer["continuations"].array.first?.continuationToken {
            result.continuation = token
        }
        if thread["renderingPriority"].string == "RENDERING_PRIORITY_PINNED_COMMENT" {
            result.isPinned = true
        }
        return result
    }

    /// A comment in the modern entity-backed shape.
    private static func modernComment(_ node: JSONNode, mutations: [String: JSONNode]) -> Comment? {
        let view = node["commentViewModel"].exists ? node["commentViewModel"] : node
        guard let commentKey = view["commentKey"].string ?? view["commentId"].string else { return nil }
        let entity = mutations[commentKey]?["commentEntityPayload"] ?? .empty
        let properties = entity["properties"]
        let author = entity["author"]
        let toolbar = entity["toolbar"]

        guard let id = properties["commentId"].string ?? view["commentId"].string else { return nil }

        let avatar = author["avatarThumbnailUrl"].string
            ?? author["avatar"]["image"]["sources"].thumbnailURL
            ?? entity["avatar"]["image"]["sources"].thumbnailURL
            ?? ""

        let content = properties["content"]
        let text = content["content"].string
            ?? content.text
            ?? ""

        let likeCountText = toolbar["likeCountNotliked"].text ?? ""
        let replyCountText = toolbar["replyCount"].text ?? ""
        let toolbarStateKey = properties["toolbarStateKey"].string
        let toolbarState = toolbarStateKey.flatMap { mutations[$0] }?["engagementToolbarStateEntityPayload"] ?? .empty
        let pinnedText = view["pinnedText"].text ?? properties["pinnedText"].text

        return Comment(
            id: id,
            author: author["displayName"].string ?? "",
            authorThumbnail: avatar,
            authorChannelId: author["channelId"].string
                ?? author["navigationEndpoint"]["browseEndpoint"]["browseId"].string
                ?? "",
            text: text,
            likeCount: Int(InnerTubeParse.count(from: likeCountText) ?? 0),
            likeCountText: likeCountText,
            publishedTime: properties["publishedTime"].string ?? "",
            replies: [],
            replyCount: Int(InnerTubeParse.count(from: replyCountText) ?? 0),
            continuation: nil,
            isPinned: pinnedText != nil && !(pinnedText ?? "").isEmpty,
            isHearted: toolbarState["heartState"].string == "TOOLBAR_HEART_STATE_HEARTED",
            isVerified: author["isVerified"].bool ?? false,
            isCreator: author["isCreator"].bool ?? false
        )
    }

    /// A comment in the older renderer shape, still served by some clients.
    private static func legacyComment(_ node: JSONNode) -> Comment? {
        guard let id = node["commentId"].string, !id.isEmpty else { return nil }
        let likeText = node["voteCount"].text ?? ""
        return Comment(
            id: id,
            author: node["authorText"].text ?? "",
            authorThumbnail: node["authorThumbnail"].thumbnailURL ?? "",
            authorChannelId: node["authorEndpoint"]["browseEndpoint"]["browseId"].string ?? "",
            text: node["contentText"].text ?? "",
            likeCount: Int(InnerTubeParse.count(from: likeText) ?? 0),
            likeCountText: likeText,
            publishedTime: node["publishedTimeText"].text ?? "",
            replies: [],
            replyCount: Int(InnerTubeParse.count(from: node["replyCount"].text) ?? 0),
            continuation: nil,
            isPinned: node["pinnedCommentBadge"].exists,
            isHearted: false,
            isVerified: node["authorCommentBadge"].exists,
            isCreator: false
        )
    }

    // MARK: - Transcript

    /// A transcript, from the `get_transcript` response.
    static func transcript(from root: JSONNode) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        let segments = root["actions"].array
            .compactMap { $0["updateEngagementPanelAction"]["content"]["transcriptRenderer"]["content"]["transcriptSearchPanelRenderer"]["body"]["transcriptSegmentListRenderer"]["initialSegments"].array }
            .flatMap { $0 }

        for segment in segments {
            let renderer = segment["transcriptSegmentRenderer"]
            guard let text = renderer["snippet"].text, !text.isEmpty else { continue }
            let startMs = Int64(renderer["startMs"].string ?? "0") ?? 0
            let endMs = Int64(renderer["endMs"].string ?? "0") ?? 0
            let duration = max(endMs - startMs, 0)
            lines.append(TranscriptLine(
                text: text,
                startTime: TimeInterval(startMs) / 1000.0,
                duration: TimeInterval(duration) / 1000.0
            ))
        }

        if lines.isEmpty {
            let body = root["actions"].array
                .compactMap { $0["updateEngagementPanelAction"]["content"]["transcriptRenderer"]["content"]["transcriptSearchPanelRenderer"]["body"] }
                .first ?? .empty
            for segment in body["transcriptSegmentListRenderer"]["initialSegments"].array {
                let renderer = segment["transcriptSegmentRenderer"]
                guard let text = renderer["snippet"].text, !text.isEmpty else { continue }
                let startMs = Int64(renderer["startMs"].string ?? "0") ?? 0
                let endMs = Int64(renderer["endMs"].string ?? "0") ?? 0
                lines.append(TranscriptLine(
                    text: text,
                    startTime: TimeInterval(startMs) / 1000.0,
                    duration: TimeInterval(max(endMs - startMs, 0)) / 1000.0
                ))
            }
        }
        return lines
    }
}
