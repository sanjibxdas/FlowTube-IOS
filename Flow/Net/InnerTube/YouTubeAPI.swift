import Foundation

/// The app's single door to YouTube.
///
/// Every screen calls this, never `InnerTubeClient` directly. The facade owns the request bodies,
/// the choice of client and host per endpoint, and the mapping from a raw response to a page model.
/// It is callback-based because the whole app is: there is no async/await on iOS 12.
///
/// The player ladder mirrors the Android app's: a token-free direct client first, then the app
/// clients, then the web client. A client that refuses a video is skipped rather than failing the
/// whole load, because YouTube refuses different clients for different videos.
final class YouTubeAPI {

    /// The transport, shared so the visitor identity and the request log are global.
    let client: InnerTubeClient

    /// The clients tried for a player request, in order. The first that answers `OK` with streams
    /// wins; a refusal moves to the next.
    var playerClients: [YouTubeClient] = [YouTubeClient.visionOS, YouTubeClient.androidVR, YouTubeClient.mobile, YouTubeClient.web]

    /// Whether a player response should be requested from the main site rather than the music host.
    /// The main site serves direct adaptive URLs for the visionOS and VR clients; the music host
    /// answers those clients with SABR-only responses that AVPlayer cannot open.
    var playerUsesMainSite: Bool = true

    init(client: InnerTubeClient = InnerTubeClient()) {
        self.client = client
    }

    // MARK: - Discovery

    /// The main-site home feed.
    func home(completion: @escaping (Result<VideoHomeFeed, FlowError>) -> Void) {
        browseMainSite(browseId: "FEwhat_to_watch", params: nil) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let root):
                let feed = BrowseParser.homeFeed(from: root)
                completion(.success(VideoHomeFeed(
                    chips: BrowseParser.homeChips(from: root),
                    sections: feed.sections,
                    continuation: feed.continuation
                )))
            case .failure(let error):
                self.fallbackHome(error: error, completion: completion)
            }
        }
    }

    /// A continuation of the main-site home feed.
    func homeContinuation(_ token: String, completion: @escaping (Result<VideoHomeFeed, FlowError>) -> Void) {
        browseMainSite(continuation: token) { result in
            switch result {
            case .success(let root):
                let feed = BrowseParser.homeContinuation(from: root)
                completion(.success(VideoHomeFeed(sections: feed.sections, continuation: feed.continuation)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// The music home feed, which is what the Music tab shows.
    func musicHome(completion: @escaping (Result<MusicHome, FlowError>) -> Void) {
        browseMusic(browseId: "FEmusic_home", params: nil) { result in
            switch result {
            case .success(let root):
                completion(.success(MusicParser.musicHome(from: root)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// The chips above the music home feed.
    func musicHomeChips(completion: @escaping (Result<[HomeChip], FlowError>) -> Void) {
        browseMusic(browseId: "FEmusic_home", params: nil) { result in
            switch result {
            case .success(let root):
                completion(.success(MusicParser.homeChips(from: root)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// A continuation of the music home feed.
    func musicHomeContinuation(_ token: String, completion: @escaping (Result<MusicHome, FlowError>) -> Void) {
        browseMusic(continuation: token) { result in
            switch result {
            case .success(let root):
                completion(.success(MusicParser.homeContinuation(from: root)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Search

    /// One page of main-site search results.
    func search(
        query: String,
        filter: VideoSearchFilter = .all,
        completion: @escaping (Result<VideoSearchResults, FlowError>) -> Void
    ) {
        var body: [String: Any] = ["context": context()]
        body["query"] = query
        if let params = filter.params {
            body["params"] = params
        }
        postMainSite(path: "search", body: body) { result in
            switch result {
            case .success(let root):
                completion(.success(SearchParser.videoResults(from: root)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// A continuation of main-site search results.
    func searchContinuation(_ token: String, completion: @escaping (Result<VideoSearchResults, FlowError>) -> Void) {
        let body: [String: Any] = ["context": context(), "continuation": token]
        postMainSite(path: "search", body: body) { result in
            switch result {
            case .success(let root):
                completion(.success(SearchParser.videoContinuation(from: root)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// One page of music search results.
    func musicSearch(
        query: String,
        filter: MusicSearchFilter = .all,
        completion: @escaping (Result<MusicSearchResults, FlowError>) -> Void
    ) {
        var body: [String: Any] = ["context": context(client: .webRemix)]
        body["query"] = query
        if let params = filter.params {
            body["params"] = params
        }
        postMusic(path: "search", client: .webRemix, body: body) { result in
            switch result {
            case .success(let root):
                completion(.success(SearchParser.musicResults(from: root)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// A continuation of music search results.
    func musicSearchContinuation(_ token: String, completion: @escaping (Result<MusicSearchResults, FlowError>) -> Void) {
        let body: [String: Any] = ["context": context(client: .webRemix), "continuation": token]
        postMusic(path: "search", client: .webRemix, body: body) { result in
            switch result {
            case .success(let root):
                completion(.success(SearchParser.musicContinuation(from: root)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Typeahead suggestions.
    func suggestions(query: String, completion: @escaping (Result<[String], FlowError>) -> Void) {
        client.fetchSuggestions(query: query, completion: completion)
    }

    // MARK: - Watch

    /// The watch page: the player response merged with the metadata from `next`.
    ///
    /// The two are requested together and only fail together. A player response that refuses to
    /// play still yields a page — the screen shows the reason — but a `next` failure with a working
    /// player is not fatal either, so the page is built from whichever arrived.
    func watch(videoId: String, completion: @escaping (Result<WatchPage, FlowError>) -> Void) {
        let group = DispatchGroup()
        var playerResult: Result<PlayerParser.Result, FlowError>?
        var nextResult: Result<JSONNode, FlowError>?

        group.enter()
        player(videoId: videoId) { result in
            playerResult = result
            group.leave()
        }

        group.enter()
        nextWatch(videoId: videoId) { result in
            nextResult = result
            group.leave()
        }

        group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
            guard let player = playerResult else {
                completion(.failure(.underlying("The player request did not answer.")))
                return
            }
            switch player {
            case .failure(let error):
                completion(.failure(error))
            case .success(let parsed):
                let nextRoot: JSONNode
                if case .success(let root) = nextResult {
                    nextRoot = root
                } else {
                    nextRoot = .empty
                }
                completion(.success(YouTubeAPI.watchPage(player: parsed, next: nextRoot, videoId: videoId)))
            }
        }
    }

    /// A player response on its own, for the download path and the audio-only player.
    func player(videoId: String, completion: @escaping (Result<PlayerParser.Result, FlowError>) -> Void) {
        requestPlayer(clients: playerClients, index: 0, videoId: videoId, lastError: nil, completion: completion)
    }

    /// The related videos for a video, from its `next` response.
    func related(videoId: String, completion: @escaping (Result<[Video], FlowError>) -> Void) {
        nextWatch(videoId: videoId) { result in
            switch result {
            case .success(let root):
                completion(.success(NextParser.related(from: root)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// A page of comments. Pass the continuation from the watch page for the first page, then the
    /// one each page returns.
    func comments(
        videoId: String,
        continuation: String?,
        completion: @escaping (Result<CommentsPage, FlowError>) -> Void
    ) {
        if let token = continuation, !token.isEmpty {
            commentsContinuation(token, completion: completion)
            return
        }
        nextWatch(videoId: videoId) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let root):
                guard let token = NextParser.commentsContinuation(from: root) else {
                    completion(.success(CommentsPage(comments: [], continuation: nil, totalText: nil, totalCount: nil)))
                    return
                }
                self.commentsContinuation(token, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// A page of one comment's replies.
    func commentReplies(continuation: String, completion: @escaping (Result<CommentsPage, FlowError>) -> Void) {
        commentsContinuation(continuation, completion: completion)
    }

    private func commentsContinuation(_ token: String, completion: @escaping (Result<CommentsPage, FlowError>) -> Void) {
        let body: [String: Any] = ["context": context(client: .web), "continuation": token]
        postMainSite(path: "next", body: body) { result in
            switch result {
            case .success(let root):
                completion(.success(NextParser.comments(from: root)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// A video's chapters, read from its `next` response.
    func chapters(videoId: String, completion: @escaping (Result<[Chapter], FlowError>) -> Void) {
        nextWatch(videoId: videoId) { result in
            switch result {
            case .success(let root):
                completion(.success(NextParser.chapters(from: root)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Channel and playlist

    /// A channel's page.
    func channel(id: String, completion: @escaping (Result<ChannelPage, FlowError>) -> Void) {
        browseMainSite(browseId: id, params: nil) { result in
            switch result {
            case .success(let root):
                completion(.success(BrowseParser.channelPage(from: root, requestedId: id)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// One tab of a channel's page.
    func channelTab(
        id: String,
        params: String,
        completion: @escaping (Result<ChannelPage, FlowError>) -> Void
    ) {
        browseMainSite(browseId: id, params: params) { result in
            switch result {
            case .success(let root):
                completion(.success(BrowseParser.channelPage(from: root, requestedId: id)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// A playlist's page.
    func playlist(id: String, completion: @escaping (Result<PlaylistPage, FlowError>) -> Void) {
        browseMainSite(browseId: "VL" + id, params: nil) { result in
            switch result {
            case .success(let root):
                completion(.success(BrowseParser.playlistPage(from: root, requestedId: id)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// A continuation of a playlist's rows.
    func playlistContinuation(_ token: String, completion: @escaping (Result<(videos: [Video], continuation: String?), FlowError>) -> Void) {
        browseMainSite(continuation: token) { result in
            switch result {
            case .success(let root):
                completion(.success(BrowseParser.playlistContinuation(from: root)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Music pages

    /// An artist's page.
    func artist(id: String, completion: @escaping (Result<ArtistPage, FlowError>) -> Void) {
        browseMusic(browseId: id, params: nil) { result in
            switch result {
            case .success(let root):
                completion(.success(MusicParser.artistPage(from: root, browseId: id)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// An album's page.
    func album(id: String, completion: @escaping (Result<AlbumPage, FlowError>) -> Void) {
        browseMusic(browseId: id, params: nil) { result in
            switch result {
            case .success(let root):
                completion(.success(MusicParser.albumPage(from: root, browseId: id)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// A music playlist's page.
    func musicPlaylist(id: String, completion: @escaping (Result<MusicPlaylistPage, FlowError>) -> Void) {
        browseMusic(browseId: "VL" + id, params: nil) { result in
            switch result {
            case .success(let root):
                completion(.success(MusicParser.musicPlaylistPage(from: root, playlistId: id)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// A continuation of a music playlist's songs.
    func musicPlaylistContinuation(_ token: String, completion: @escaping (Result<(songs: [SongItem], continuation: String?), FlowError>) -> Void) {
        browseMusic(continuation: token) { result in
            switch result {
            case .success(let root):
                completion(.success(MusicParser.musicPlaylistContinuation(from: root)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// The mood and genre groups.
    func moodsAndGenres(completion: @escaping (Result<[MoodAndGenreGroup], FlowError>) -> Void) {
        browseMusic(browseId: "FEmusic_moods_and_genres", params: nil) { result in
            switch result {
            case .success(let root):
                completion(.success(MusicParser.moodsAndGenres(from: root)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// A video's lyrics, from the music watch-next tab that carries them.
    ///
    /// The lyrics live behind a browse id the watch-next response names (`MPLYt…`), so this is two
    /// requests: one for the tab list, one for the lyrics themselves. A video without lyrics is a
    /// success carrying nil, not an error.
    func lyrics(videoId: String, completion: @escaping (Result<Lyrics?, FlowError>) -> Void) {
        let body: [String: Any] = [
            "context": context(client: .webRemix),
            "videoId": videoId,
        ]
        postMusic(path: "next", client: .webRemix, body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let root):
                guard let browseId = MusicParser.lyricsBrowseId(fromNext: root) else {
                    completion(.success(nil))
                    return
                }
                self.browseMusic(browseId: browseId, params: nil) { lyricsResult in
                    switch lyricsResult {
                    case .success(let lyricsRoot):
                        completion(.success(MusicParser.lyrics(from: lyricsRoot)))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// A video's transcript.
    func transcript(videoId: String, completion: @escaping (Result<[TranscriptLine], FlowError>) -> Void) {
        let params = InnerTubeClient.base64("\n" + String(UnicodeScalar(11) ?? " ") + videoId)
        let body: [String: Any] = [
            "context": context(client: .webRemix),
            "params": params,
        ]
        postMusic(path: "get_transcript", client: .webRemix, body: body) { result in
            switch result {
            case .success(let root):
                completion(.success(NextParser.transcript(from: root)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Player ladder

    /// Tries each client in turn. A refusal or an empty stream list moves to the next client; a
    /// transport failure is kept as the last error so the caller sees something actionable.
    private func requestPlayer(
        clients: [YouTubeClient],
        index: Int,
        videoId: String,
        lastError: FlowError?,
        completion: @escaping (Result<PlayerParser.Result, FlowError>) -> Void
    ) {
        guard index < clients.count else {
            completion(.failure(lastError ?? .noPlayableStream))
            return
        }
        let client = clients[index]
        var body: [String: Any] = [
            "context": client.context(locale: self.client.locale, visitorData: self.client.visitorData, dataSyncId: nil),
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "cpn": InnerTubeClient.playbackNonce(),
        ]
        if client.useSignatureTimestamp {
            body["playbackContext"] = [
                "contentPlaybackContext": ["signatureTimestamp": 0],
            ]
        }

        self.client.postPlayer(client: client, body: body, useMainSite: playerUsesMainSite) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.requestPlayer(
                    clients: clients,
                    index: index + 1,
                    videoId: videoId,
                    lastError: error,
                    completion: completion
                )
            case .success(let data):
                switch InnerTubeClient.decode(data) {
                case .failure(let error):
                    self.requestPlayer(
                        clients: clients,
                        index: index + 1,
                        videoId: videoId,
                        lastError: error,
                        completion: completion
                    )
                case .success(let payload):
                    let parsed = PlayerParser.parse(JSONNode(payload))
                    let hasStreams = !parsed.formats.isEmpty
                        || !parsed.adaptiveFormats.isEmpty
                        || parsed.hlsManifestUrl != nil
                        || parsed.dashManifestUrl != nil
                    if parsed.status == "OK" && hasStreams {
                        completion(.success(parsed))
                    } else {
                        let reason = PlayerParser.unavailableReason(for: parsed)
                        self.requestPlayer(
                            clients: clients,
                            index: index + 1,
                            videoId: videoId,
                            lastError: .unavailable(reason: reason),
                            completion: completion
                        )
                    }
                }
            }
        }
    }

    // MARK: - Request plumbing

    /// The context every request carries, built from the client's locale and visitor identity.
    private func context(client: YouTubeClient = .web) -> [String: Any] {
        return client.context(
            locale: self.client.locale,
            visitorData: self.client.visitorData,
            dataSyncId: self.client.dataSyncId
        )
    }

    private func postMusic(
        path: String,
        client: YouTubeClient,
        body: [String: Any],
        completion: @escaping (Result<JSONNode, FlowError>) -> Void
    ) {
        self.client.postMusic(path: path, client: client, body: body) { result in
            YouTubeAPI.decode(result, completion: completion)
        }
    }

    private func postMainSite(
        path: String,
        body: [String: Any],
        completion: @escaping (Result<JSONNode, FlowError>) -> Void
    ) {
        self.client.postMainSite(path: path, client: .web, body: body) { result in
            YouTubeAPI.decode(result, completion: completion)
        }
    }

    private func browseMusic(
        browseId: String? = nil,
        params: String? = nil,
        continuation: String? = nil,
        completion: @escaping (Result<JSONNode, FlowError>) -> Void
    ) {
        var body: [String: Any] = ["context": context(client: .webRemix)]
        if let browseId = browseId { body["browseId"] = browseId }
        if let params = params { body["params"] = params }
        if let continuation = continuation { body["continuation"] = continuation }
        postMusic(path: "browse", client: .webRemix, body: body, completion: completion)
    }

    private func browseMainSite(
        browseId: String? = nil,
        params: String? = nil,
        continuation: String? = nil,
        completion: @escaping (Result<JSONNode, FlowError>) -> Void
    ) {
        var body: [String: Any] = ["context": context(client: .web)]
        if let browseId = browseId { body["browseId"] = browseId }
        if let params = params { body["params"] = params }
        if let continuation = continuation { body["continuation"] = continuation }
        postMainSite(path: "browse", body: body, completion: completion)
    }

    private func nextWatch(videoId: String, completion: @escaping (Result<JSONNode, FlowError>) -> Void) {
        let body: [String: Any] = [
            "context": context(client: .web),
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        postMainSite(path: "next", body: body, completion: completion)
    }

    /// The main-site home feed, falling back to the music home when the main site refuses — which
    /// it does for a walled visitor. The fallback keeps the Home tab populated rather than empty.
    private func fallbackHome(error: FlowError, completion: @escaping (Result<VideoHomeFeed, FlowError>) -> Void) {
        browseMusic(browseId: "FEmusic_home", params: nil) { result in
            switch result {
            case .success(let root):
                let home = MusicParser.musicHome(from: root)
                let sections = home.sections.map { section in
                    VideoShelf(
                        title: section.title,
                        subtitle: section.subtitle,
                        items: section.items.map { YouTubeAPI.video(from: $0) },
                        moreBrowseId: section.moreBrowseId
                    )
                }
                completion(.success(VideoHomeFeed(chips: [], sections: sections, continuation: home.continuation)))
            case .failure:
                completion(.failure(error))
            }
        }
    }

    private static func decode(
        _ result: Result<Data, FlowError>,
        completion: @escaping (Result<JSONNode, FlowError>) -> Void
    ) {
        switch result {
        case .failure(let error):
            completion(.failure(error))
        case .success(let data):
            switch InnerTubeClient.decode(data) {
            case .failure(let error):
                completion(.failure(error))
            case .success(let payload):
                completion(.success(JSONNode(payload)))
            }
        }
    }

    /// Builds the watch page from the two responses that describe it.
    static func watchPage(player: PlayerParser.Result, next: JSONNode, videoId: String) -> WatchPage {
        let metadata = NextParser.watchMetadata(from: next, videoId: videoId)
        var video = metadata.video
        if video.title.isEmpty { video.title = player.title }
        if video.channelName.isEmpty {
            video.channelName = player.author
            video.channelId = player.channelId
        }
        if video.viewCount == 0 { video.viewCount = player.viewCount }
        if video.description.isEmpty { video.description = player.shortDescription }
        if video.thumbnailUrl.isEmpty { video.thumbnailUrl = player.thumbnailUrl }
        if video.duration == 0 { video.duration = player.lengthSeconds }
        video.isLive = video.isLive || player.isLive

        return WatchPage(
            video: video,
            playabilityStatus: player.status,
            playabilityReason: player.status == "OK" ? nil : PlayerParser.unavailableReason(for: player),
            hlsManifestUrl: player.hlsManifestUrl,
            dashManifestUrl: player.dashManifestUrl,
            formats: player.formats,
            adaptiveFormats: player.adaptiveFormats,
            captionTracks: player.captions,
            related: NextParser.related(from: next),
            chapters: metadata.chapters,
            commentsContinuation: NextParser.commentsContinuation(from: next),
            likeCount: video.likeCount,
            isLive: player.isLive,
            isUpcoming: video.isUpcoming,
            scheduledStartTime: player.scheduledStartTime
        )
    }

    /// A music item as a plain video, for the rows that share the video list.
    static func video(from item: MusicItem) -> Video {
        switch item {
        case .song(let song):
            return song.asVideo
        case .album(let album):
            return Video(
                id: album.playlistId,
                title: album.title,
                channelName: album.artistLine,
                channelId: album.artists.first?.id ?? "",
                thumbnailUrl: album.thumbnailUrl,
                isMusic: true
            )
        case .playlist(let playlist):
            return Video(
                id: playlist.id,
                title: playlist.title,
                channelName: playlist.authorName ?? "",
                channelId: playlist.authorId ?? "",
                thumbnailUrl: playlist.thumbnailUrl,
                isMusic: true
            )
        case .artist(let artist):
            return Video(
                id: artist.id,
                title: artist.title,
                channelName: artist.subscriberCountText ?? "",
                channelId: artist.channelId ?? artist.id,
                thumbnailUrl: artist.thumbnailUrl,
                isMusic: true
            )
        }
    }
}
