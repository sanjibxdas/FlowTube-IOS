import Foundation

/// Parses `/player` responses: the playability verdict, the stream ladder, the caption tracks and
/// the video details.
///
/// The response is the single source of truth for what can be played. Everything else on the watch
/// page — title, view count, chapters — comes from `next`; this parser deliberately reads only the
/// fields the player itself owns, so a `next` shape change cannot stop playback.
enum PlayerParser {

    /// The parsed player response.
    struct Result {
        let status: String
        let reason: String?
        let videoId: String
        let title: String
        let author: String
        let channelId: String
        let lengthSeconds: Int
        let viewCount: Int64
        let shortDescription: String
        let keywords: [String]
        let isLive: Bool
        let isLiveContent: Bool
        let hlsManifestUrl: String?
        let dashManifestUrl: String?
        let formats: [StreamFormat]
        let adaptiveFormats: [StreamFormat]
        let captions: [CaptionTrack]
        let musicVideoType: String?
        let category: String?
        let publishDate: String?
        let thumbnailUrl: String
        /// When a premiere or scheduled stream starts, as YouTube words it.
        let scheduledStartTime: String?
    }

    /// Reads a player response. A missing `playabilityStatus` is treated as an unknown failure
    /// rather than a success, because a success with no streams is worse than an honest error.
    static func parse(_ root: JSONNode) -> Result {
        let statusNode = root["playabilityStatus"]
        let status = statusNode["status"].string ?? "ERROR"
        let reason = statusNode["reason"].string
            ?? statusNode["errorScreen"]["playerErrorMessageRenderer"]["subreason"].text

        let details = root["videoDetails"]
        let streaming = root["streamingData"]
        let microformat = root["microformat"]["playerMicroformatRenderer"]

        let formats = streaming["formats"].array.compactMap { format(from: $0) }
        let adaptive = streaming["adaptiveFormats"].array.compactMap { format(from: $0) }

        let captionTracks = root["captions"]["playerCaptionsTracklistRenderer"]["captionTracks"].array.compactMap { track -> CaptionTrack? in
            guard let baseUrl = track["baseUrl"].string, !baseUrl.isEmpty else { return nil }
            let name = track["name"]["simpleText"].string
                ?? track["name"]["runs"].array.compactMap { $0["text"].string }.joined()
            let language = track["languageCode"].string ?? ""
            return CaptionTrack(
                baseUrl: baseUrl,
                name: name.isEmpty ? language : name,
                languageCode: language,
                isAutomatic: track["kind"].string == "asr",
                isTranslatable: track["isTranslatable"].bool ?? false
            )
        }

        let lengthText = details["lengthSeconds"].string ?? "0"
        let viewText = details["viewCount"].string
        let microViewText = microformat["viewCount"].string

        let isLive = details["isLive"].bool ?? false
        let isLiveContent = details["isLiveContent"].bool ?? false

        return Result(
            status: status,
            reason: reason,
            videoId: details["videoId"].string ?? "",
            title: details["title"].string ?? "",
            author: details["author"].string ?? "",
            channelId: details["channelId"].string ?? "",
            lengthSeconds: Int(lengthText) ?? 0,
            viewCount: Int64(viewText ?? microViewText ?? "") ?? 0,
            shortDescription: details["shortDescription"].string ?? "",
            keywords: details["keywords"].array.compactMap { $0.string },
            isLive: isLive,
            isLiveContent: isLiveContent,
            hlsManifestUrl: streaming["hlsManifestUrl"].string,
            dashManifestUrl: streaming["dashManifestUrl"].string,
            formats: formats,
            adaptiveFormats: adaptive,
            captions: captionTracks,
            musicVideoType: details["musicVideoType"].string,
            category: microformat["category"].string,
            publishDate: microformat["publishDate"].string ?? microformat["uploadDate"].string,
            thumbnailUrl: details["thumbnail"].thumbnailURL ?? "",
            scheduledStartTime: microformat["liveBroadcastDetails"]["startTimestamp"].string
        )
    }

    /// One stream, from either `formats` or `adaptiveFormats`.
    static func format(from node: JSONNode) -> StreamFormat? {
        guard let itag = node["itag"].int else { return nil }
        let url = node["url"].string
        let cipher = node["signatureCipher"].string ?? node["cipher"].string
        // A format with neither a direct URL nor a cipher cannot be played, so it is dropped here
        // rather than surfacing as a quality entry that fails when chosen.
        if (url == nil || url!.isEmpty) && (cipher == nil || cipher!.isEmpty) {
            return nil
        }
        let audioTrack = node["audioTrack"]
        return StreamFormat(
            itag: itag,
            url: url,
            signatureCipher: cipher,
            mimeType: node["mimeType"].string ?? "",
            bitrate: node["bitrate"].int ?? 0,
            averageBitrate: node["averageBitrate"].int,
            width: node["width"].int ?? 0,
            height: node["height"].int ?? 0,
            fps: node["fps"].int ?? 0,
            quality: node["quality"].string ?? "",
            qualityLabel: node["qualityLabel"].string ?? "",
            audioQuality: node["audioQuality"].string ?? "",
            audioSampleRate: node["audioSampleRate"].int ?? 0,
            audioChannels: node["audioChannels"].int ?? 0,
            contentLength: node["contentLength"].int64 ?? 0,
            approxDurationMs: Int64(node["approxDurationMs"].string ?? "0") ?? 0,
            isDRC: node["isDrc"].bool ?? false,
            xtags: node["xtags"].string ?? "",
            audioTrackId: audioTrack["id"].string,
            audioTrackIsDefault: audioTrack["audioIsDefault"].bool,
            audioTrackIsAutoDubbed: audioTrack["isAutoDubbed"].bool
        )
    }

    /// The reason a player response refused to play, in wording a person can read.
    static func unavailableReason(for result: Result) -> String {
        if let reason = result.reason, !reason.isEmpty { return reason }
        switch result.status {
        case "LOGIN_REQUIRED":
            return "This video requires signing in."
        case "AGE_VERIFICATION_REQUIRED", "AGE_CHECK_REQUIRED":
            return "This video is age-restricted."
        case "UNPLAYABLE":
            return "This video cannot be played."
        case "LIVE_STREAM_OFFLINE":
            return "This live stream is offline."
        case "CONTENT_CHECK_REQUIRED":
            return "This video requires a content check."
        case "ERROR":
            return "This video is unavailable."
        default:
            return "This video is unavailable (\(result.status))."
        }
    }

    /// The best audio-only track, preferring the original language and a non-DRC copy.
    static func bestAudio(in result: Result) -> StreamFormat? {
        let audio = result.adaptiveFormats.filter { $0.isAudioOnly }
        return audio.sorted { left, right in
            if left.isOriginal != right.isOriginal { return left.isOriginal }
            if left.isDynamicRangeCompressed != right.isDynamicRangeCompressed {
                return !left.isDynamicRangeCompressed
            }
            return left.bitrate > right.bitrate
        }.first
    }

    /// The best progressive track, which is what a download without muxing uses.
    static func bestProgressive(in result: Result) -> StreamFormat? {
        return result.formats
            .filter { $0.isProgressive }
            .sorted { left, right in
                if left.height != right.height { return left.height > right.height }
                return left.bitrate > right.bitrate
            }
            .first
    }

    /// The best video-only track at or below `height`, falling back to the smallest available.
    static func videoTrack(in result: Result, maximumHeight: Int) -> StreamFormat? {
        let video = result.adaptiveFormats.filter { $0.isVideoOnly }
        let eligible = video.filter { $0.height <= maximumHeight }
        if let best = eligible.sorted(by: { left, right in
            if left.height != right.height { return left.height > right.height }
            if left.isH264 != right.isH264 { return left.isH264 }
            return left.bitrate > right.bitrate
        }).first {
            return best
        }
        return video.sorted { $0.height < $1.height }.first
    }

    /// The distinct video heights, tallest first, for the quality menu.
    static func availableHeights(in result: Result) -> [Int] {
        var heights: Set<Int> = []
        for format in result.adaptiveFormats where format.isVideoOnly && format.height > 0 {
            heights.insert(format.height)
        }
        for format in result.formats where format.height > 0 {
            heights.insert(format.height)
        }
        return heights.sorted(by: >)
    }
}
