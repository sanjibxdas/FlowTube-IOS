import Foundation

/// The content locale a request asks YouTube to answer in: `gl` is the country, `hl` the host
/// language. Both are sanitised before they reach a request, because an empty or malformed pair
/// makes YouTube answer in a default language the viewer did not choose.
struct YouTubeLocale: Equatable {

    let gl: String
    let hl: String

    static let extraction = YouTubeLocale(gl: "US", hl: "en")

    /// The locale for the device, normalised to the codes YouTube accepts.
    static var current: YouTubeLocale {
        let locale = Locale.current
        let region = locale.regionCode ?? "US"
        let language = locale.languageCode ?? "en"
        return YouTubeLocale(
            gl: YouTubeLocale.sanitizeCountry(region),
            hl: YouTubeLocale.normalizeHostLanguage(locale.identifier)
        )
    }

    /// Builds a locale from raw strings, falling back to the device's own on anything malformed.
    init(gl: String, hl: String) {
        self.gl = YouTubeLocale.sanitizeCountry(gl)
        self.hl = YouTubeLocale.normalizeHostLanguage(hl)
    }

    private init(sanitizedCountry: String, sanitizedLanguage: String) {
        gl = sanitizedCountry
        hl = sanitizedLanguage
    }

    /// A two-letter upper-case country code, or the device's, or US.
    static func sanitizeCountry(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let letters = CharacterSet.uppercaseLetters
        if normalized.count == 2, normalized.unicodeScalars.allSatisfy({ letters.contains($0) }) {
            return normalized
        }
        if let region = Locale.current.regionCode, region.count == 2 {
            return region.uppercased()
        }
        return "US"
    }

    /// YouTube's host-language codes, which differ from BCP 47 in a few places: Portuguese splits on
    /// Brazil, Chinese splits on script and region, and Kabyle is served English.
    static func normalizeHostLanguage(_ languageTag: String) -> String {
        let trimmed = languageTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if trimmed.isEmpty || trimmed.lowercased() == "system" {
            candidate = Locale.current.identifier
        } else {
            candidate = trimmed
        }
        let normalizedTag = candidate.replacingOccurrences(of: "_", with: "-")
        let components = normalizedTag.components(separatedBy: "-")
        let language = (components.first ?? "en").lowercased()
        if language.isEmpty || language == "und" { return "en" }

        let region = components.dropFirst().first?.uppercased() ?? ""
        let hasTraditionalScript = components.dropFirst().contains { $0.lowercased() == "hant" }

        switch language {
        case "kab":
            return "en"
        case "pt":
            return region == "BR" ? "pt-BR" : "pt"
        case "zh":
            if region == "HK" { return "zh-HK" }
            if hasTraditionalScript || region == "TW" || region == "MO" { return "zh-TW" }
            return "zh-CN"
        default:
            return language
        }
    }

    /// The `gl`/`hl` pair as YouTube's context expects it.
    var contextValues: [String: Any] {
        return ["gl": gl, "hl": hl]
    }
}

/// Which runtime mints a PO Token a client's URLs will accept. A token minted by one platform is
/// never valid on another's URL, so the client records which family it belongs to.
enum AttestationPlatform {
    case web
    case droidGuard
    case iosGuard
}

/// One YouTube client identity: the name and version that go into the context, the user agent that
/// goes into the header, and the flags that decide which optional context fields are sent.
struct YouTubeClient {

    let clientName: String
    let clientVersion: String
    let clientId: String
    let userAgent: String
    let osName: String?
    let osVersion: String?
    let deviceMake: String?
    let deviceModel: String?
    let androidSdkVersion: String?
    let originalUrl: String?
    let platform: String?
    let utcOffsetMinutes: Int?
    let buildId: String?
    let cronetVersion: String?
    let packageName: String?
    let friendlyName: String?
    let loginSupported: Bool
    let loginRequired: Bool
    let useSignatureTimestamp: Bool
    let isEmbedded: Bool
    let useWebPoTokens: Bool
    let attestation: AttestationPlatform
    let sendUserAgentInContext: Bool

    init(
        clientName: String,
        clientVersion: String,
        clientId: String,
        userAgent: String,
        osName: String? = nil,
        osVersion: String? = nil,
        deviceMake: String? = nil,
        deviceModel: String? = nil,
        androidSdkVersion: String? = nil,
        originalUrl: String? = nil,
        platform: String? = nil,
        utcOffsetMinutes: Int? = nil,
        buildId: String? = nil,
        cronetVersion: String? = nil,
        packageName: String? = nil,
        friendlyName: String? = nil,
        loginSupported: Bool = false,
        loginRequired: Bool = false,
        useSignatureTimestamp: Bool = false,
        isEmbedded: Bool = false,
        useWebPoTokens: Bool = false,
        attestation: AttestationPlatform = .web,
        sendUserAgentInContext: Bool = false
    ) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.clientId = clientId
        self.userAgent = userAgent
        self.osName = osName
        self.osVersion = osVersion
        self.deviceMake = deviceMake
        self.deviceModel = deviceModel
        self.androidSdkVersion = androidSdkVersion
        self.originalUrl = originalUrl
        self.platform = platform
        self.utcOffsetMinutes = utcOffsetMinutes
        self.buildId = buildId
        self.cronetVersion = cronetVersion
        self.packageName = packageName
        self.friendlyName = friendlyName
        self.loginSupported = loginSupported
        self.loginRequired = loginRequired
        self.useSignatureTimestamp = useSignatureTimestamp
        self.isEmbedded = isEmbedded
        self.useWebPoTokens = useWebPoTokens
        self.attestation = attestation
        self.sendUserAgentInContext = sendUserAgentInContext
    }

    // MARK: - Constants

    static let userAgentWeb = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"

    static let userAgentMWeb = "Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1,gzip(gfe)"

    static let originYouTubeMusic = "https://music.youtube.com"
    static let refererYouTubeMusic = "https://music.youtube.com/"
    static let apiURLYouTubeMusic = "https://music.youtube.com/youtubei/v1/"

    static let originYouTube = "https://www.youtube.com"
    static let refererYouTube = "https://www.youtube.com/"
    static let apiURLYouTube = "https://www.youtube.com/youtubei/v1/"

    /// The public web API key YouTube's own page ships. It is not a secret; it identifies the
    /// project, not the viewer.
    static let publicAPIKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    // MARK: - The clients Flow uses

    static let web = YouTubeClient(
        clientName: "WEB",
        clientVersion: "2.20260710.06.00",
        clientId: "1",
        userAgent: userAgentWeb,
        originalUrl: originYouTube,
        platform: "DESKTOP",
        utcOffsetMinutes: 0
    )

    static let mweb = YouTubeClient(
        clientName: "MWEB",
        clientVersion: "2.20250122.04.00",
        clientId: "2",
        userAgent: userAgentMWeb,
        platform: "MOBILE",
        utcOffsetMinutes: 0,
        useSignatureTimestamp: true,
        useWebPoTokens: true,
        sendUserAgentInContext: true
    )

    static let android = YouTubeClient(
        clientName: "ANDROID",
        clientVersion: "21.03.38",
        clientId: "3",
        userAgent: "com.google.android.youtube/21.03.38 (Linux; U; Android 14) gzip",
        osName: "Android",
        osVersion: "14",
        deviceMake: "Google",
        deviceModel: "Pixel 6 Pro",
        androidSdkVersion: "34",
        buildId: "TQ2A.230505.002",
        packageName: "com.google.android.youtube",
        friendlyName: "Android",
        loginSupported: true,
        useSignatureTimestamp: true,
        attestation: .droidGuard
    )

    static let webRemix = YouTubeClient(
        clientName: "WEB_REMIX",
        clientVersion: "1.20260213.01.00",
        clientId: "67",
        userAgent: userAgentWeb,
        loginSupported: true,
        useSignatureTimestamp: true,
        useWebPoTokens: true
    )

    static let webCreator = YouTubeClient(
        clientName: "WEB_CREATOR",
        clientVersion: "1.20260213.00.00",
        clientId: "62",
        userAgent: userAgentWeb,
        loginSupported: true,
        loginRequired: true,
        useSignatureTimestamp: true
    )

    static let tvHTML5 = YouTubeClient(
        clientName: "TVHTML5",
        clientVersion: "7.20260213.00.00",
        clientId: "7",
        userAgent: "Mozilla/5.0(SMART-TV; Linux; Tizen 4.0.0.2) AppleWebkit/605.1.15 (KHTML, like Gecko) SamsungBrowser/9.2 TV Safari/605.1.15",
        loginSupported: true,
        loginRequired: true,
        useSignatureTimestamp: true,
        useWebPoTokens: true
    )

    static let tvTizen = YouTubeClient(
        clientName: "TVHTML5",
        clientVersion: "5.20260707",
        clientId: "7",
        userAgent: "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
        osName: "Tizen",
        osVersion: "2.4.0",
        deviceMake: "Samsung",
        deviceModel: "SmartTV",
        useSignatureTimestamp: true
    )

    static let tvHTML5Embedded = YouTubeClient(
        clientName: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
        clientVersion: "2.0",
        clientId: "85",
        userAgent: "Mozilla/5.0 (PlayStation; PlayStation 4/12.02) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 Safari/605.1.15",
        loginSupported: true,
        useSignatureTimestamp: true,
        isEmbedded: true
    )

    static let ios = YouTubeClient(
        clientName: "IOS",
        clientVersion: "21.03.1",
        clientId: "5",
        userAgent: "com.google.ios.youtube/21.03.1 (iPhone16,2; U; CPU iOS 18_2 like Mac OS X;)",
        osVersion: "18.2.22C152",
        attestation: .iosGuard
    )

    static let mobile = YouTubeClient(
        clientName: "ANDROID",
        clientVersion: "21.03.38",
        clientId: "3",
        userAgent: "com.google.android.youtube/21.03.38 (Linux; U; Android 14) gzip",
        loginSupported: true,
        useSignatureTimestamp: true,
        attestation: .droidGuard
    )

    static let androidVRNoAuth = YouTubeClient(
        clientName: "ANDROID_VR",
        clientVersion: "1.61.48",
        clientId: "28",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.61.48 (Linux; U; Android 12; en_US; Oculus Quest 3; Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)",
        attestation: .droidGuard
    )

    static let androidVR = YouTubeClient(
        clientName: "ANDROID_VR",
        clientVersion: "1.65.10",
        clientId: "28",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        osName: "Android",
        osVersion: "12L",
        deviceMake: "Oculus",
        deviceModel: "Quest 3",
        androidSdkVersion: "32",
        buildId: "SQ3A.220605.009.A1",
        packageName: "com.google.android.apps.youtube.vr.oculus",
        friendlyName: "Android VR 1.65",
        attestation: .droidGuard
    )

    static let visionOS = YouTubeClient(
        clientName: "VISIONOS",
        clientVersion: "1.02",
        clientId: "101",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        osName: "visionOS",
        osVersion: "26.5.23O471",
        deviceMake: "Apple",
        deviceModel: "RealityDevice17,1",
        friendlyName: "visionOS",
        attestation: .iosGuard
    )

    static let iPadOS = YouTubeClient(
        clientName: "IOS",
        clientVersion: "21.03.3",
        clientId: "5",
        userAgent: "com.google.ios.youtube/21.03.3 (iPad7,6; U; CPU iPadOS 17_7_10 like Mac OS X; en-US)",
        osName: "iPadOS",
        osVersion: "17.7.10.21H450",
        deviceMake: "Apple",
        deviceModel: "iPad7,6",
        friendlyName: "iPadOS",
        packageName: "com.google.ios.youtube",
        attestation: .iosGuard
    )

    // MARK: - Context

    /// The `context` object this client sends with a request.
    func context(locale: YouTubeLocale, visitorData: String?, dataSyncId: String?) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": clientName,
            "clientVersion": clientVersion,
            "gl": locale.gl,
            "hl": locale.hl,
        ]
        if let osName = osName { client["osName"] = osName }
        if let osVersion = osVersion { client["osVersion"] = osVersion }
        if let deviceMake = deviceMake { client["deviceMake"] = deviceMake }
        if let deviceModel = deviceModel { client["deviceModel"] = deviceModel }
        if let androidSdkVersion = androidSdkVersion { client["androidSdkVersion"] = androidSdkVersion }
        if let originalUrl = originalUrl { client["originalUrl"] = originalUrl }
        if let platform = platform { client["platform"] = platform }
        if let utcOffsetMinutes = utcOffsetMinutes { client["utcOffsetMinutes"] = utcOffsetMinutes }
        if let buildId = buildId { client["buildId"] = buildId }
        if let cronetVersion = cronetVersion { client["cronetVersion"] = cronetVersion }
        if let packageName = packageName { client["packageName"] = packageName }
        if let friendlyName = friendlyName { client["friendlyName"] = friendlyName }
        if let visitorData = visitorData, !visitorData.isEmpty { client["visitorData"] = visitorData }
        if sendUserAgentInContext { client["userAgent"] = userAgent }

        var user: [String: Any] = ["lockedSafetyMode": false]
        if loginSupported, let dataSyncId = dataSyncId, !dataSyncId.isEmpty {
            user["onBehalfOfUser"] = dataSyncId
        }

        return [
            "client": client,
            "request": [
                "internalExperimentFlags": [],
                "useSsl": true,
            ],
            "user": user,
        ]
    }

    /// Whether this client's stream URLs accept a PO Token minted by the Web runtime.
    var acceptsWebPoToken: Bool {
        return attestation == .web
    }
}
