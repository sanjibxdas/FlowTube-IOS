import Foundation

/// Everything the watch screen needs, assembled once.
///
/// The watch screen would otherwise make four independent requests and reconcile them itself. This
/// composes them: the player response and the `next` response are required, the SponsorBlock
/// segments, DeArrow branding and dislike counts are enrichment that may fail without failing the
/// page. The enrichment is requested in parallel and given a deadline, so a slow third-party
/// service cannot hold the screen back.
struct WatchPageModel {
    /// The player and metadata, as the watch screen renders them.
    let page: WatchPage
    /// The title to show, which is DeArrow's when the community has one.
    let title: String
    /// The thumbnail to show, which is DeArrow's when the community has one.
    let thumbnailUrl: String
    /// The segments to draw on the seek bar and act on during playback.
    let sponsorSegments: [SponsorBlockSegment]
    /// The community branding, when there was any.
    let deArrow: DeArrowResult?
    /// Return YouTube Dislike's counts, when the service knows the video.
    let dislikeCounts: DislikeCounts?
}

/// Loads a watch page and its enrichment.
final class WatchPageService {

    static let shared = WatchPageService()

    /// How long the enrichment may take before the page is delivered without it.
    static let enrichmentDeadline: TimeInterval = 3.0

    let api: YouTubeAPI
    let sponsorBlock: SponsorBlockService
    let deArrow: DeArrowService
    let dislikes: ReturnYouTubeDislikeService

    init(
        api: YouTubeAPI? = nil,
        sponsorBlock: SponsorBlockService = .shared,
        deArrow: DeArrowService = .shared,
        dislikes: ReturnYouTubeDislikeService = .shared
    ) {
        self.api = api ?? YouTubeAPI()
        self.sponsorBlock = sponsorBlock
        self.deArrow = deArrow
        self.dislikes = dislikes
    }

    /// Loads a video's watch page.
    ///
    /// The page itself is required: if the player or `next` fails, the load fails and the screen
    /// shows the error. The three enrichments are optional and are collected under one deadline;
    /// whichever have not answered by then are simply absent.
    func load(videoId: String, completion: @escaping (Result<WatchPageModel, FlowError>) -> Void) {
        api.watch(videoId: videoId) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let page):
                self.enrich(page: page, videoId: videoId, completion: completion)
            }
        }
    }

    /// The enrichment only, for a page that is already on screen.
    func enrich(
        page: WatchPage,
        videoId: String,
        completion: @escaping (Result<WatchPageModel, FlowError>) -> Void
    ) {
        let group = DispatchGroup()
        let lock = NSLock()
        var segments: [SponsorBlockSegment] = []
        var branding: DeArrowResult?
        var counts: DislikeCounts?
        var delivered = false

        // The deadline and the group's own notification race, so only the first may answer.
        let deliver = { [weak self] in
            guard let self = self else { return }
            lock.lock()
            if delivered {
                lock.unlock()
                return
            }
            delivered = true
            let resolvedSegments = segments
            let resolvedBranding = branding
            let resolvedCounts = counts
            lock.unlock()
            completion(.success(self.model(
                page: page,
                segments: resolvedSegments,
                branding: resolvedBranding,
                counts: resolvedCounts
            )))
        }

        group.enter()
        sponsorBlock.segments(for: videoId) { result in
            if case .success(let fetched) = result {
                lock.lock()
                segments = fetched
                lock.unlock()
            }
            group.leave()
        }

        group.enter()
        deArrow.branding(videoId: videoId) { content in
            guard let content = content else {
                group.leave()
                return
            }
            let resolved = DeArrowService.resolve(
                content: content,
                videoId: videoId,
                fallbackDurationSeconds: page.video.duration,
                useRandomFrame: true,
                isLiveOrUpcoming: page.isLive || page.isUpcoming
            )
            lock.lock()
            branding = resolved
            lock.unlock()
            group.leave()
        }

        group.enter()
        dislikes.counts(for: videoId) { fetched in
            lock.lock()
            counts = fetched
            lock.unlock()
            group.leave()
        }

        group.notify(queue: DispatchQueue.global(qos: .userInitiated), execute: deliver)
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + WatchPageService.enrichmentDeadline, execute: deliver)
    }

    /// Assembles the model, applying DeArrow's title and thumbnail over YouTube's.
    private func model(
        page: WatchPage,
        segments: [SponsorBlockSegment],
        branding: DeArrowResult?,
        counts: DislikeCounts?
    ) -> WatchPageModel {
        var title = page.video.title
        if let deArrowTitle = branding?.title, !deArrowTitle.isEmpty {
            title = deArrowTitle
        }
        var thumbnail = page.video.thumbnailUrl
        if let deArrowThumbnail = branding?.thumbnailUrl, !deArrowThumbnail.isEmpty {
            thumbnail = deArrowThumbnail
        }
        var likeCount = page.likeCount
        // The watch page often sends no like count for videos whose likes are visible; the
        // service's figure is adopted only in that case, never over a real one.
        if likeCount <= 0, let serviceLikes = counts?.likes, serviceLikes > 0 {
            likeCount = serviceLikes
        }
        return WatchPageModel(
            page: page,
            title: title,
            thumbnailUrl: thumbnail,
            sponsorSegments: segments,
            deArrow: branding,
            dislikeCounts: counts
        )
    }
}
