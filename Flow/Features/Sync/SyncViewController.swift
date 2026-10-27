import UIKit
import CoreImage
import Darwin

// MARK: - Collections

/// What two devices can exchange. The keys match the Android app's `SyncCollection` strings, so a
/// phone and a tablet agree on what each block of data is even though the payload shapes differ.
enum SyncCollection: String, CaseIterable {
    case playlists
    case watchHistory = "watch_history"
    case subscriptions
    case notes
    case settings

    var title: String {
        switch self {
        case .playlists: return "Playlists"
        case .watchHistory: return "Watch history"
        case .subscriptions: return "Subscriptions"
        case .notes: return "Notes"
        case .settings: return "Settings"
        }
    }

    var detail: String {
        switch self {
        case .playlists: return "Your playlists and the videos in them."
        case .watchHistory: return "What you have watched and how far you got."
        case .subscriptions: return "The channels you follow."
        case .notes: return "Your private notes on videos and channels."
        case .settings: return "Playback, appearance and download preferences."
        }
    }

    var icon: FlowIcon {
        switch self {
        case .playlists: return .playlist
        case .watchHistory: return .clock
        case .subscriptions: return .subscriptions
        case .notes: return .notes
        case .settings: return .settings
        }
    }
}

/// What happened to one collection when it was merged in.
struct FlowSyncApplyStats {
    var added = 0
    var updated = 0
    var skipped = 0

    var summary: String {
        return "+" + String(added) + " added, " + String(updated) + " updated, " + String(skipped) + " skipped"
    }

    static func + (left: FlowSyncApplyStats, right: FlowSyncApplyStats) -> FlowSyncApplyStats {
        return FlowSyncApplyStats(
            added: left.added + right.added,
            updated: left.updated + right.updated,
            skipped: left.skipped + right.skipped
        )
    }
}

// MARK: - Bytes

/// URL-safe base64, the encoding the QR payload uses for the session id and key.
enum FlowSyncBase64 {

    static func encode(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var value = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 {
            value += "="
        }
        return Data(base64Encoded: value)
    }

    /// `count` cryptographically random bytes.
    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        arc4random_buf(&bytes, count)
        return Data(bytes)
    }
}

// MARK: - Pairing code

/// The `FLOW-SYNC/1` payload a QR code carries: the session id, the one-time key, the host's
/// address, the role of the device showing the code and when the code lapses.
///
/// The key never travels over the network — it is only ever in the code the two devices exchange by
/// looking at each other's screens, which is what makes the pairing out-of-band.
struct FlowSyncCode {

    static let protocolVersion = 1
    static let ttl: TimeInterval = 120.0
    static let path = "/flow-sync"
    static let serviceType = "_flow-sync._tcp."

    let sessionId: Data
    let key: Data
    let address: String
    let port: Int
    let deviceName: String
    let expiresAt: Date
    let role: FlowSyncRole

    /// The verification code both screens show. It is derived from the session id and the key, so
    /// two devices that hold the same code compute the same six digits without sending them.
    var verificationCode: String {
        var material = [UInt8]()
        material.append(contentsOf: sessionId)
        material.append(contentsOf: key)
        material.append(contentsOf: Array("flow-sync-sas".utf8))
        let digest = InnerTubeClient.sha1(material)
        guard digest.count >= 4 else { return "000000" }
        let value = (UInt32(digest[0]) << 24) | (UInt32(digest[1]) << 16) | (UInt32(digest[2]) << 8) | UInt32(digest[3])
        return String(format: "%06d", Int32(value % 1_000_000))
    }

    /// The JSON text the QR encodes.
    func encoded() -> String {
        let payload: [String: Any] = [
            "v": FlowSyncCode.protocolVersion,
            "sid": FlowSyncBase64.encode(sessionId),
            "k": FlowSyncBase64.encode(key),
            "ip": address,
            "p": port,
            "d": String(deviceName.prefix(64)),
            "exp": Int(expiresAt.timeIntervalSince1970),
            "role": role.rawValue,
            "lease": "host",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    enum DecodeError: Error {
        case malformed
        case wrongVersion
        case badSession
        case badKey
        case badAddress
        case expired

        var message: String {
            switch self {
            case .malformed: return "That doesn't look like valid Flow connection data."
            case .wrongVersion: return "Incompatible app version on the other device."
            case .badSession: return "The connection data is missing its session id."
            case .badKey: return "The connection data is missing its key."
            case .badAddress: return "The connection data is missing a valid network address."
            case .expired: return "This code has expired. Ask the other device for a fresh one."
            }
        }
    }

    /// Parses text from a scanned or pasted code.
    static func decode(text: String, now: Date = Date()) -> Result<FlowSyncCode, DecodeError> {
        let trimmed = text.trimmed
        guard let data = trimmed.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return .failure(.malformed)
        }
        let version = (root["v"] as? NSNumber)?.intValue ?? 0
        guard version == FlowSyncCode.protocolVersion else { return .failure(.wrongVersion) }
        guard let sidText = root["sid"] as? String, let sid = FlowSyncBase64.decode(sidText), sid.count == 16 else {
            return .failure(.badSession)
        }
        guard let keyText = root["k"] as? String, let key = FlowSyncBase64.decode(keyText), key.count == 32 else {
            return .failure(.badKey)
        }
        guard let address = root["ip"] as? String, !address.isBlank,
              let port = (root["p"] as? NSNumber)?.intValue, port > 0, port < 65536 else {
            return .failure(.badAddress)
        }
        let expiry = (root["exp"] as? NSNumber)?.doubleValue ?? 0.0
        let expiresAt = Date(timeIntervalSince1970: expiry)
        let role = FlowSyncRole(rawValue: (root["role"] as? String) ?? "") ?? .sender
        // A host-leased code is validated by the host's own listener closing, so its expiry is not
        // compared with this device's clock; clocks disagree by minutes and that made valid codes
        // look expired on arrival.
        let isLeased = (root["lease"] as? String) == "host"
        if !isLeased, expiresAt.timeIntervalSince(now) < -600.0 {
            return .failure(.expired)
        }
        return .success(FlowSyncCode(
            sessionId: sid,
            key: key,
            address: address,
            port: port,
            deviceName: (root["d"] as? String) ?? "Device",
            expiresAt: expiresAt,
            role: role
        ))
    }
}

/// Which side of the transfer the device showing the code is on. The scanner takes the complement.
enum FlowSyncRole: String {
    case sender
    case receiver

    var title: String {
        switch self {
        case .sender: return "Send"
        case .receiver: return "Receive"
        }
    }
}

// MARK: - QR rendering

/// Draws a pairing code with Core Image's `CIQRCodeGenerator`. The generated bitmap is tiny, so it
/// is scaled up with a nearest-neighbour transform to keep the modules crisp.
enum FlowSyncQRCodeRenderer {

    static func image(for text: String, size: CGFloat) -> UIImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let extent = output.extent
        let scale = size / max(extent.width, extent.height)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - HTTP

/// One request the sync server understood.
struct FlowSyncHTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data
}

/// One response the sync server sends.
struct FlowSyncHTTPResponse {
    let status: Int
    let body: Data

    static func json(_ object: Any, status: Int = 200) -> FlowSyncHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return FlowSyncHTTPResponse(status: status, body: data)
    }

    static func message(_ text: String, status: Int) -> FlowSyncHTTPResponse {
        return json(["error": text], status: status)
    }
}

/// A deliberately small HTTP/1.1 server for the length of one sync session.
///
/// It runs on its own queue, accepts one connection at a time and closes each connection after one
/// response. That is all the protocol needs: the two devices exchange a handful of JSON documents,
/// and a general-purpose server would be more surface than the feature warrants. No third-party
/// code is involved — it is BSD sockets and `Data`.
final class FlowSyncHTTPServer {

    private let queue = DispatchQueue(label: "org.flowtube.Flow.sync.server", qos: .userInitiated)
    private let stateLock = NSLock()
    private var listenSocket: Int32 = -1
    private var stopping = false

    /// Called on the server's queue for every request.
    var handler: ((FlowSyncHTTPRequest) -> FlowSyncHTTPResponse)?

    private(set) var port: UInt16 = 0

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listenSocket >= 0
    }

    /// Starts listening. Returns the port the kernel assigned.
    func start() throws -> UInt16 {
        stop()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw FlowError.underlying("The sync server could not open a socket.")
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr.s_addr = inet_addr("0.0.0.0")

        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw FlowError.underlying("The sync server could not bind a port.")
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw FlowError.underlying("The sync server could not start listening.")
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fd, socketAddress, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw FlowError.underlying("The sync server could not read its port.")
        }

        stateLock.lock()
        listenSocket = fd
        stopping = false
        stateLock.unlock()
        port = UInt16(bigEndian: assigned.sin_port)

        queue.async { [weak self] in
            self?.acceptLoop(fd)
        }
        return port
    }

    /// Stops listening and closes the listening socket. A request already in flight finishes.
    func stop() {
        stateLock.lock()
        stopping = true
        let fd = listenSocket
        listenSocket = -1
        stateLock.unlock()
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private var shouldStop: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopping
    }

    // MARK: - Accepting

    private func acceptLoop(_ fd: Int32) {
        while !shouldStop {
            var clientAddress = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddress) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    accept(fd, socketAddress, &length)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                break
            }

            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            if let request = readRequest(from: client) {
                let response = handler?(request) ?? FlowSyncHTTPResponse.message("No handler", status: 500)
                write(response: response, to: client)
            }
            shutdown(client, SHUT_RDWR)
            close(client)
        }
    }

    private func readRequest(from fd: Int32) -> FlowSyncHTTPRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var headerRange: Range<Data.Index>?

        while buffer.count < 256 * 1024 {
            let received = recv(fd, &chunk, chunk.count, 0)
            if received <= 0 { break }
            buffer.append(contentsOf: chunk[0..<received])
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                headerRange = range
                break
            }
        }
        guard let range = headerRange else { return nil }

        let headerData = buffer.subdata(in: 0..<range.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let method = parts[0].uppercased()
        let target = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<separator]).lowercased().trimmed
            let value = String(line[line.index(after: separator)...]).trimmed
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength >= 0, contentLength <= 4 * 1024 * 1024 else { return nil }
        var body = buffer.subdata(in: range.upperBound..<buffer.count)
        while body.count < contentLength {
            let received = recv(fd, &chunk, chunk.count, 0)
            if received <= 0 { break }
            body.append(contentsOf: chunk[0..<received])
        }
        // A short body means the client gave up mid-request; answering it would apply half a
        // document, so the request is dropped instead.
        guard body.count >= contentLength else { return nil }
        if body.count > contentLength {
            body = body.subdata(in: 0..<contentLength)
        }

        var path = target
        var query: [String: String] = [:]
        if let question = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<question])
            let queryText = String(target[target.index(after: question)...])
            for pair in queryText.components(separatedBy: "&") where !pair.isEmpty {
                let pieces = pair.components(separatedBy: "=")
                let name = pieces.first?.removingPercentEncoding ?? pieces.first ?? ""
                let value = pieces.count > 1 ? (pieces[1].removingPercentEncoding ?? pieces[1]) : ""
                query[name] = value
            }
        }

        return FlowSyncHTTPRequest(method: method, path: path, query: query, body: body)
    }

    private func write(response: FlowSyncHTTPResponse, to fd: Int32) {
        var header = "HTTP/1.1 \(response.status) \(FlowSyncHTTPServer.reason(response.status))\r\n"
        header += "Content-Type: application/json; charset=utf-8\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"

        var payload = Data(header.utf8)
        payload.append(response.body)

        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            while sent < payload.count {
                let written = send(fd, base + sent, payload.count - sent, 0)
                if written <= 0 { break }
                sent += written
            }
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "Error"
        }
    }
}

// MARK: - Network address

/// The device's LAN address, which is what the other device dials. A device on cellular alone has
/// none, and the screen says so rather than showing a code nobody can reach.
enum FlowSyncNetwork {

    static func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }

        var preferred: String?
        var fallback: String?
        var pointer = interfaces
        while let current = pointer {
            let flags = Int32(current.pointee.ifa_flags)
            if let address = current.pointee.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0,
               (flags & IFF_LOOPBACK) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    address,
                    socklen_t(address.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    let value = String(cString: host)
                    if !value.hasPrefix("169.254") {
                        let name = String(cString: current.pointee.ifa_name)
                        if name == "en0" {
                            preferred = value
                        } else if fallback == nil {
                            fallback = value
                        }
                    }
                }
            }
            pointer = current.pointee.ifa_next
        }
        return preferred ?? fallback
    }

    /// Whether an address is on a private or link-local network. A code that points somewhere else
    /// is refused, so a pasted code cannot make the app talk to a stranger's server.
    static func isLocal(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31 { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        if parts[0] == 127 { return true }
        return false
    }
}

// MARK: - Bonjour

/// Publishes this device's sync listener so the other device can see that something is there.
///
/// The service carries only the device name and the fact that a session is open — never the key.
/// Discovery is a convenience ("both devices are on the same network"), while the connection itself
/// always goes through the code.
final class FlowSyncBonjourPublisher: NSObject, NetServiceDelegate {

    private var service: NetService?

    var onFailure: ((String) -> Void)?

    func publish(name: String, port: Int) {
        stop()
        let service = NetService(
            domain: "local.",
            type: FlowSyncCode.serviceType,
            name: String(name.prefix(48)),
            port: Int32(port)
        )
        service.delegate = self
        service.publish()
        self.service = service
    }

    func stop() {
        service?.stop()
        service?.delegate = nil
        service = nil
    }

    func netServiceDidPublish(_ sender: NetService) {
        _ = sender
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        onFailure?("The device could not be advertised on this network (" + String(code) + ").")
    }
}

/// One device seen on the local network.
struct FlowSyncPeer {
    let name: String
    let address: String
    let port: Int
}

/// Browses for other Flow sync listeners. The result is informational: it tells the viewer that the
/// other device is on the same network, which is the most common reason a code will not connect.
final class FlowSyncBonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private(set) var peers: [FlowSyncPeer] = []

    var onChange: (([FlowSyncPeer]) -> Void)?

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        stop()
        browser.searchForServices(ofType: FlowSyncCode.serviceType, inDomain: "local.")
    }

    func stop() {
        browser.stop()
        for service in services {
            service.stop()
            service.delegate = nil
        }
        services = []
        peers = []
        onChange?([])
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard !services.contains(where: { $0.name == service.name }) else { return }
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5.0)
        _ = moreComing
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0.name == service.name }
        peers.removeAll { $0.name == service.name }
        onChange?(peers)
        _ = moreComing
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let address = FlowSyncBonjourBrowser.address(from: sender.addresses ?? []) else { return }
        peers.removeAll { $0.name == sender.name }
        peers.append(FlowSyncPeer(name: sender.name, address: address, port: sender.port))
        onChange?(peers)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        _ = errorDict
    }

    private static func address(from addresses: [Data]) -> String? {
        for data in addresses {
            // The bytes come from a `Data` and are not guaranteed to be sockaddr-aligned, so they
            // are copied into a properly aligned storage before being read as an address.
            var storage = sockaddr_storage()
            let copied = withUnsafeMutableBytes(of: &storage) { destination -> Int in
                let count = min(destination.count, data.count)
                guard let base = destination.baseAddress else { return 0 }
                data.copyBytes(to: base.assumingMemoryBound(to: UInt8.self), count: count)
                return count
            }
            guard copied >= MemoryLayout<sockaddr>.size else { continue }

            let family = withUnsafePointer(to: &storage) { pointer -> UInt8 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0.pointee.sa_family }
            }
            guard family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = withUnsafePointer(to: &storage) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    getnameinfo(socketAddress, socklen_t(copied), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                }
            }
            if result == 0 {
                let value = String(cString: host)
                if FlowSyncNetwork.isLocal(value) {
                    return value
                }
            }
        }
        return nil
    }
}

// MARK: - Payloads

/// Turns the stores into the JSON documents the protocol carries, and merges documents back in.
///
/// Merging never deletes: a collection that arrives adds what is missing and updates what the other
/// device knows better (a later watch position, a renamed playlist). That is what makes it safe to
/// run twice, and it is why the receiving device can offer "merge" without a backup step.
enum FlowSyncPayloadCodec {

    // MARK: - Building

    static func payload(for collection: SyncCollection) -> [String: Any] {
        switch collection {
        case .playlists:
            return playlistsPayload()
        case .watchHistory:
            return historyPayload()
        case .subscriptions:
            return subscriptionsPayload()
        case .notes:
            return notesPayload()
        case .settings:
            return settingsPayload()
        }
    }

    private static func playlistsPayload() -> [String: Any] {
        let store = FlowApp.shared.playlistStore
        let playlists = store.allPlaylists().map { playlist -> [String: Any] in
            let items = store.items(in: playlist.playlistId).map { item -> [String: Any] in
                [
                    "videoId": item.videoId,
                    "title": item.title,
                    "channelName": item.channelName,
                    "thumbnailUrl": item.thumbnailUrl,
                    "duration": item.duration,
                ]
            }
            return [
                "id": playlist.playlistId,
                "title": playlist.title,
                "description": playlist.description,
                "thumbnailUrl": playlist.thumbnailUrl,
                "items": items,
            ]
        }
        return ["playlists": playlists]
    }

    private static func historyPayload() -> [String: Any] {
        let entries = FlowApp.shared.historyStore.recent(limit: 2000).map { entry -> [String: Any] in
            [
                "videoId": entry.videoId,
                "title": entry.title,
                "channelId": entry.channelId,
                "channelName": entry.channelName,
                "thumbnailUrl": entry.thumbnailUrl,
                "duration": entry.duration,
                "position": entry.position,
                "watchedAt": entry.watchedAt.timeIntervalSince1970,
                "isMusic": entry.isMusic,
            ]
        }
        return ["history": entries]
    }

    private static func subscriptionsPayload() -> [String: Any] {
        let items = FlowApp.shared.subscriptionStore.all.map { subscription -> [String: Any] in
            [
                "channelId": subscription.channelId,
                "name": subscription.name,
                "avatarUrl": subscription.avatarUrl,
                "subscriberCount": subscription.subscriberCount,
                "subscribedAt": subscription.subscribedAt.timeIntervalSince1970,
            ]
        }
        return ["subscriptions": items]
    }

    private static func notesPayload() -> [String: Any] {
        let items = FlowApp.shared.noteStore.all().map { note -> [String: Any] in
            [
                "videoId": note.videoId,
                "videoTitle": note.videoTitle,
                "channelName": note.channelName,
                "body": note.body,
                "timestamp": note.timestamp,
                "createdAt": note.createdAt.timeIntervalSince1970,
            ]
        }
        return ["notes": items]
    }

    /// The settings worth carrying between devices. Account-like state (visitor data, cookies) is
    /// deliberately absent: it belongs to a session, not to the viewer.
    private static func settingsKeys() -> [PrefsStore.Key] {
        return [
            .themeMode, .themeVariant, .fontFamily,
            .playbackQuality, .playbackSpeed, .autoplayNext, .resumePlayback, .backgroundPlayback,
            .downloadQuality, .downloadWifiOnly, .downloadAudioOnly,
            .sponsorBlockEnabled, .sponsorBlockAutoSkip,
            .subtitlesEnabled, .subtitleLanguage,
            .gridItemSize, .showShortsShelf,
        ]
    }

    private static func settingsPayload() -> [String: Any] {
        let prefs = FlowApp.shared.prefs
        var values: [String: Any] = [:]
        for key in settingsKeys() {
            if let text = prefs.string(for: key) {
                values[key.rawValue] = ["type": "string", "value": text]
            } else if let number = UserDefaults.standard.object(forKey: key.rawValue) as? NSNumber {
                // A number stored by `set(_:for:)` reads back as a number; booleans are tagged so
                // the receiving device writes them back as booleans rather than 0/1 strings.
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    values[key.rawValue] = ["type": "bool", "value": number.boolValue]
                } else {
                    values[key.rawValue] = ["type": "double", "value": number.doubleValue]
                }
            }
        }
        return ["settings": values]
    }

    // MARK: - Applying

    static func apply(collection: SyncCollection, payload: [String: Any]) -> FlowSyncApplyStats {
        switch collection {
        case .playlists: return applyPlaylists(payload)
        case .watchHistory: return applyHistory(payload)
        case .subscriptions: return applySubscriptions(payload)
        case .notes: return applyNotes(payload)
        case .settings: return applySettings(payload)
        }
    }

    private static func applyPlaylists(_ payload: [String: Any]) -> FlowSyncApplyStats {
        var stats = FlowSyncApplyStats()
        let store = FlowApp.shared.playlistStore
        let existing = store.allPlaylists()
        let playlists = payload["playlists"] as? [[String: Any]] ?? []
        for playlist in playlists {
            guard let title = playlist["title"] as? String, !title.isBlank else { continue }
            let items = playlist["items"] as? [[String: Any]] ?? []
            let match = existing.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
            let playlistId: String
            if let match = match {
                playlistId = match.playlistId
                stats.updated += 1
            } else {
                playlistId = store.createPlaylist(
                    title: title,
                    description: (playlist["description"] as? String) ?? ""
                )
                stats.added += 1
            }
            for item in items {
                guard let videoId = item["videoId"] as? String, !videoId.isEmpty else { continue }
                let inserted = store.addVideo(
                    videoId: videoId,
                    title: (item["title"] as? String) ?? "",
                    channelName: (item["channelName"] as? String) ?? "",
                    thumbnailUrl: (item["thumbnailUrl"] as? String) ?? "",
                    duration: (item["duration"] as? NSNumber)?.doubleValue ?? 0.0,
                    to: playlistId
                )
                if inserted {
                    stats.added += 1
                } else {
                    stats.skipped += 1
                }
            }
        }
        return stats
    }

    private static func applyHistory(_ payload: [String: Any]) -> FlowSyncApplyStats {
        var stats = FlowSyncApplyStats()
        let history = FlowApp.shared.historyStore
        let entries = payload["history"] as? [[String: Any]] ?? []
        for entry in entries {
            guard let videoId = entry["videoId"] as? String, !videoId.isEmpty else { continue }
            let existed = history.contains(videoId: videoId)
            let watchedAt = Date(timeIntervalSince1970: (entry["watchedAt"] as? NSNumber)?.doubleValue ?? 0.0)
            history.record(
                videoId: videoId,
                title: (entry["title"] as? String) ?? "",
                channelId: (entry["channelId"] as? String) ?? "",
                channelName: (entry["channelName"] as? String) ?? "",
                thumbnailUrl: (entry["thumbnailUrl"] as? String) ?? "",
                duration: (entry["duration"] as? NSNumber)?.doubleValue ?? 0.0,
                position: (entry["position"] as? NSNumber)?.doubleValue ?? 0.0,
                isMusic: (entry["isMusic"] as? NSNumber)?.boolValue ?? false,
                watchedAt: watchedAt
            )
            if existed {
                stats.updated += 1
            } else {
                stats.added += 1
            }
        }
        return stats
    }

    private static func applySubscriptions(_ payload: [String: Any]) -> FlowSyncApplyStats {
        var stats = FlowSyncApplyStats()
        let store = FlowApp.shared.subscriptionStore
        let items = payload["subscriptions"] as? [[String: Any]] ?? []
        for item in items {
            guard let channelId = item["channelId"] as? String, !channelId.isEmpty else { continue }
            let name = (item["name"] as? String) ?? ""
            if store.isSubscribed(channelId) {
                stats.skipped += 1
                continue
            }
            store.subscribe(
                channelId: channelId,
                name: name.isEmpty ? channelId : name,
                avatarUrl: (item["avatarUrl"] as? String) ?? "",
                subscriberCount: (item["subscriberCount"] as? NSNumber)?.intValue ?? 0
            )
            stats.added += 1
        }
        return stats
    }

    private static func applyNotes(_ payload: [String: Any]) -> FlowSyncApplyStats {
        var stats = FlowSyncApplyStats()
        let store = FlowApp.shared.noteStore
        let existing = store.all()
        let notes = payload["notes"] as? [[String: Any]] ?? []
        for note in notes {
            guard let videoId = note["videoId"] as? String, !videoId.isEmpty,
                  let body = note["body"] as? String, !body.isBlank else { continue }
            let timestamp = (note["timestamp"] as? NSNumber)?.doubleValue ?? 0.0
            let duplicate = existing.contains {
                $0.videoId == videoId && $0.body == body.trimmed && abs($0.timestamp - timestamp) < 1.0
            }
            if duplicate {
                stats.skipped += 1
                continue
            }
            store.create(
                videoId: videoId,
                videoTitle: (note["videoTitle"] as? String) ?? "",
                channelName: (note["channelName"] as? String) ?? "",
                body: body,
                timestamp: timestamp
            )
            stats.added += 1
        }
        return stats
    }

    private static func applySettings(_ payload: [String: Any]) -> FlowSyncApplyStats {
        var stats = FlowSyncApplyStats()
        let prefs = FlowApp.shared.prefs
        guard let values = payload["settings"] as? [String: Any] else { return stats }
        for key in settingsKeys() {
            guard let entry = values[key.rawValue] as? [String: Any],
                  let type = entry["type"] as? String else { continue }
            switch type {
            case "string":
                guard let text = entry["value"] as? String else { continue }
                if prefs.string(for: key) == text {
                    stats.skipped += 1
                } else {
                    prefs.set(text, for: key)
                    stats.updated += 1
                }
            case "bool":
                let value = (entry["value"] as? NSNumber)?.boolValue ?? false
                if prefs.bool(for: key, fallback: !value) == value {
                    stats.skipped += 1
                } else {
                    prefs.set(value, for: key)
                    stats.updated += 1
                }
            case "double":
                let value = (entry["value"] as? NSNumber)?.doubleValue ?? 0.0
                if abs(prefs.double(for: key, fallback: value + 1.0) - value) < 0.0001 {
                    stats.skipped += 1
                } else {
                    prefs.set(value, for: key)
                    stats.updated += 1
                }
            default:
                stats.skipped += 1
            }
        }
        return stats
    }
}

// MARK: - Session

/// One sync session, from "show a code" to "merged".
///
/// The device showing the code runs the listener; the device that scanned it is the client. Both
/// sides derive the same six-digit verification code from the session id and key, and neither will
/// transfer anything until its viewer says the two codes match. The receiver always confirms the
/// merge before a single item is written.
final class FlowSyncSession {

    // MARK: - State

    enum State {
        case idle
        case preparing
        case showingCode(code: FlowSyncCode, text: String)
        case connecting
        case awaitingVerification(code: String, peerName: String)
        case awaitingConsent(collections: [SyncCollection], peerName: String)
        case waiting(peerName: String)
        case transferring(collection: SyncCollection, done: Int, total: Int)
        case done(peerName: String, stats: [SyncCollection: FlowSyncApplyStats])
        case failed(String)
    }

    /// Called on the main queue whenever the state changes.
    var onState: ((State) -> Void)?

    /// Whether this device is the one that showed the code. Both sides pass through
    /// `.awaitingVerification`, so which confirm action the card runs is tracked here rather than
    /// inferred from the state.
    private(set) var isHost = false

    private(set) var state: State = .idle {
        didSet {
            let snapshot = state
            DispatchQueue.main.async { [weak self] in
                self?.onState?(snapshot)
            }
        }
    }

    // MARK: - Host side

    private let server = FlowSyncHTTPServer()
    private let publisher = FlowSyncBonjourPublisher()
    private var code: FlowSyncCode?
    private var hostRole: FlowSyncRole = .sender
    private var hostCollections: Set<SyncCollection> = Set(SyncCollection.allCases)
    private var peerName: String = "Device"
    private var verificationConfirmed = false
    private var consentGranted = false
    private var hostStats: [SyncCollection: FlowSyncApplyStats] = [:]
    private var hostCompleted: Set<SyncCollection> = []
    private var expiryTimer: Timer?
    private let lock = NSLock()

    // MARK: - Client side

    private var clientCode: FlowSyncCode?
    private var clientCollections: [SyncCollection] = []
    private var clientStats: [SyncCollection: FlowSyncApplyStats] = [:]
    private var clientIndex = 0
    private var clientPeerName = "Device"
    private var clientTask: URLSessionDataTask?

    deinit {
        stop()
    }

    var isActive: Bool {
        switch state {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    // MARK: - Hosting

    /// Opens a listener and produces the code to show. `role` is what *this* device will do.
    func startHosting(role: FlowSyncRole, collections: Set<SyncCollection>) {
        stop()
        isHost = true
        hostRole = role
        hostCollections = collections.isEmpty ? Set(SyncCollection.allCases) : collections
        verificationConfirmed = false
        consentGranted = false
        hostStats = [:]
        hostCompleted = []
        state = .preparing

        guard let address = FlowSyncNetwork.localIPv4Address() else {
            state = .failed("No Wi-Fi or local network connection. Connect both devices to the same network or a hotspot.")
            return
        }

        do {
            let port = try server.start()
            let sessionId = FlowSyncBase64.randomBytes(16)
            let key = FlowSyncBase64.randomBytes(32)
            let deviceName = FlowSyncSession.deviceName()
            let code = FlowSyncCode(
                sessionId: sessionId,
                key: key,
                address: address,
                port: Int(port),
                deviceName: deviceName,
                expiresAt: Date().addingTimeInterval(FlowSyncCode.ttl),
                role: role
            )
            self.code = code
            server.handler = { [weak self] request in
                return self?.handle(request: request) ?? FlowSyncHTTPResponse.message("Unavailable", status: 500)
            }
            publisher.onFailure = { [weak self] message in
                DispatchQueue.main.async {
                    self?.state = .failed(message)
                }
            }
            publisher.publish(name: deviceName, port: Int(port))
            state = .showingCode(code: code, text: code.encoded())
            startExpiryTimer()
        } catch {
            state = .failed((error as? FlowError)?.displayMessage ?? error.localizedDescription)
        }
    }

    private func startExpiryTimer() {
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self, let code = self.code else {
                timer.invalidate()
                return
            }
            if Date() > code.expiresAt {
                timer.invalidate()
                // Once the other device has made contact the code has done its job; only an
                // untouched code lapses.
                if !self.peerEngaged {
                    self.state = .failed("No device connected before the code expired. Check that both devices are on the same Wi-Fi, then try again.")
                    self.stop()
                }
            }
        }
    }

    private var peerEngaged: Bool {
        switch state {
        case .awaitingVerification, .awaitingConsent, .waiting, .transferring, .done:
            return true
        default:
            return false
        }
    }

    /// The host confirms that the six digits on both screens match.
    func confirmVerification() {
        lock.lock()
        verificationConfirmed = true
        lock.unlock()
        if case .awaitingVerification(_, let peer) = state {
            state = .waiting(peerName: peer)
        }
    }

    /// The host declines the codes, which ends the session without transferring anything.
    func rejectVerification() {
        lock.lock()
        verificationConfirmed = false
        lock.unlock()
        state = .failed("The verification codes weren't confirmed, so nothing was transferred.")
        stop()
    }

    /// The receiving host approves the merge.
    func grantConsent() {
        lock.lock()
        consentGranted = true
        lock.unlock()
        if case .awaitingConsent(_, let peer) = state {
            state = .waiting(peerName: peer)
        }
    }

    /// The receiving host declines the merge.
    func declineConsent() {
        state = .failed("The merge was declined. Nothing was transferred.")
        stop()
    }

    // MARK: - Joining

    /// Connects to the device whose code this is.
    func join(codeText: String, collections: Set<SyncCollection>) {
        stop()
        isHost = false
        switch FlowSyncCode.decode(text: codeText) {
        case .failure(let error):
            state = .failed(error.message)
        case .success(let parsed):
            guard FlowSyncNetwork.isLocal(parsed.address) else {
                state = .failed("This code points outside your local network, so Flow won't connect to it. Only use codes shown by your own devices.")
                return
            }
            clientCode = parsed
            clientCollections = SyncCollection.allCases.filter { collections.contains($0) }
            if clientCollections.isEmpty {
                clientCollections = SyncCollection.allCases
            }
            clientStats = [:]
            clientIndex = 0
            state = .connecting
            sendHello(parsed)
        }
    }

    private func sendHello(_ code: FlowSyncCode) {
        guard let url = endpoint(code, path: "/hello", query: ["sid": FlowSyncBase64.encode(code.sessionId)]) else {
            state = .failed("The connection data is missing a valid network address.")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12.0
        request.httpMethod = "GET"
        clientTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.state = .failed(FlowSyncSession.describe(error))
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
                    self.state = .failed("Couldn't reach the other device. Check that both devices are on the same Wi-Fi and that a VPN or firewall isn't blocking the connection.")
                    return
                }
                self.clientPeerName = (root["name"] as? String) ?? "Device"
                let expected = code.verificationCode
                let received = (root["sas"] as? String) ?? ""
                guard received == expected else {
                    self.state = .failed("The two devices couldn't agree on the verification code. Ask the other device for a fresh code.")
                    return
                }
                self.state = .awaitingVerification(code: expected, peerName: self.clientPeerName)
            }
        }
        clientTask?.resume()
    }

    /// The joining device confirms the codes match and starts the transfer.
    func confirmJoin() {
        guard let code = clientCode else { return }
        sendOffer(code)
    }

    func rejectJoin() {
        state = .failed("The verification codes weren't confirmed, so nothing was transferred.")
        stop()
    }

    private func sendOffer(_ code: FlowSyncCode) {
        guard let url = endpoint(code, path: "/offer", query: ["sid": FlowSyncBase64.encode(code.sessionId)]) else {
            state = .failed("The connection data is missing a valid network address.")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "name": FlowSyncSession.deviceName(),
            "collections": clientCollections.map { $0.rawValue },
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        clientTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.state = .failed(FlowSyncSession.describe(error))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.state = .failed("Couldn't reach the other device.")
                    return
                }
                if http.statusCode == 409 {
                    // The host is still showing its verification or consent card. Ask again shortly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        guard let self = self, self.clientCode != nil else { return }
                        self.sendOffer(code)
                    }
                    return
                }
                guard http.statusCode == 200 else {
                    self.state = .failed("The other device closed the connection. Check it for a message, then try again.")
                    return
                }
                _ = data
                self.transferNext()
            }
        }
        clientTask?.resume()
    }

    private func transferNext() {
        guard let code = clientCode else { return }
        guard clientIndex < clientCollections.count else {
            finishClient(code)
            return
        }
        let collection = clientCollections[clientIndex]
        let total = clientCollections.count
        state = .transferring(collection: collection, done: clientIndex, total: total)

        // The device that showed the code is the sender when its role says so; otherwise the
        // joining device pushes its data to it.
        if code.role == .sender {
            fetch(collection: collection, code: code)
        } else {
            push(collection: collection, code: code)
        }
    }

    private func fetch(collection: SyncCollection, code: FlowSyncCode) {
        guard let url = endpoint(code, path: "/collection", query: [
            "sid": FlowSyncBase64.encode(code.sessionId),
            "collection": collection.rawValue,
        ]) else {
            state = .failed("The connection data is missing a valid network address.")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30.0
        clientTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.state = .failed(FlowSyncSession.describe(error))
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
                    self.state = .failed("The data was damaged on the way. Try again.")
                    return
                }
                let payload = (root["payload"] as? [String: Any]) ?? [:]
                self.clientStats[collection] = FlowSyncPayloadCodec.apply(collection: collection, payload: payload)
                self.clientIndex += 1
                self.transferNext()
            }
        }
        clientTask?.resume()
    }

    private func push(collection: SyncCollection, code: FlowSyncCode) {
        guard let url = endpoint(code, path: "/collection", query: [
            "sid": FlowSyncBase64.encode(code.sessionId),
            "collection": collection.rawValue,
        ]) else {
            state = .failed("The connection data is missing a valid network address.")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = FlowSyncPayloadCodec.payload(for: collection)
        let body: [String: Any] = ["payload": payload]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        clientTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.state = .failed(FlowSyncSession.describe(error))
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    self.state = .failed("The other device couldn't save the data. Nothing on it was changed.")
                    return
                }
                _ = data
                self.clientStats[collection] = FlowSyncApplyStats()
                self.clientIndex += 1
                self.transferNext()
            }
        }
        clientTask?.resume()
    }

    private func finishClient(_ code: FlowSyncCode) {
        guard let url = endpoint(code, path: "/finish", query: ["sid": FlowSyncBase64.encode(code.sessionId)]) else {
            state = .done(peerName: clientPeerName, stats: clientStats)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10.0
        clientTask = URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.state = .done(peerName: self.clientPeerName, stats: self.clientStats)
                self.stop()
            }
        }
        clientTask?.resume()
    }

    // MARK: - Server handling

    private func handle(request: FlowSyncHTTPRequest) -> FlowSyncHTTPResponse {
        guard let code = code else {
            return FlowSyncHTTPResponse.message("No session", status: 404)
        }
        guard request.query["sid"] == FlowSyncBase64.encode(code.sessionId) else {
            return FlowSyncHTTPResponse.message("Wrong session", status: 403)
        }
        guard Date() <= code.expiresAt.addingTimeInterval(30.0) else {
            return FlowSyncHTTPResponse.message("Expired", status: 403)
        }

        switch (request.method, request.path) {
        case ("GET", "/flow-sync/hello"):
            return FlowSyncHTTPResponse.json([
                "name": FlowSyncSession.deviceName(),
                "sas": code.verificationCode,
                "role": hostRole.rawValue,
            ])

        case ("POST", "/flow-sync/offer"):
            let body = (try? JSONSerialization.jsonObject(with: request.body, options: [])) as? [String: Any] ?? [:]
            let name = (body["name"] as? String) ?? "Device"
            let keys = (body["collections"] as? [String]) ?? []
            let requested = keys.compactMap { SyncCollection(rawValue: $0) }
            let offered = requested.filter { hostCollections.contains($0) }

            lock.lock()
            let verified = verificationConfirmed
            let consented = consentGranted
            lock.unlock()

            guard verified else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if case .showingCode = self.state {
                        self.peerName = name
                        self.state = .awaitingVerification(code: code.verificationCode, peerName: name)
                    }
                }
                return FlowSyncHTTPResponse.message("sas_pending", status: 409)
            }
            guard hostRole == .sender || consented else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    switch self.state {
                    case .awaitingVerification, .waiting:
                        self.peerName = name
                        self.state = .awaitingConsent(collections: offered, peerName: name)
                    default:
                        break
                    }
                }
                return FlowSyncHTTPResponse.message("consent_pending", status: 409)
            }
            return FlowSyncHTTPResponse.json(["accepted": true, "collections": offered.map { $0.rawValue }])

        case ("GET", "/flow-sync/collection"):
            guard hostRole == .sender else {
                return FlowSyncHTTPResponse.message("This device is receiving", status: 403)
            }
            guard let key = request.query["collection"], let collection = SyncCollection(rawValue: key) else {
                return FlowSyncHTTPResponse.message("Unknown collection", status: 404)
            }
            let payload = FlowSyncPayloadCodec.payload(for: collection)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let index = SyncCollection.allCases.firstIndex(of: collection) ?? 0
                self.state = .transferring(collection: collection, done: index, total: SyncCollection.allCases.count)
            }
            return FlowSyncHTTPResponse.json(["collection": collection.rawValue, "payload": payload])

        case ("POST", "/flow-sync/collection"):
            guard hostRole == .receiver else {
                return FlowSyncHTTPResponse.message("This device is sending", status: 403)
            }
            guard let key = request.query["collection"], let collection = SyncCollection(rawValue: key) else {
                return FlowSyncHTTPResponse.message("Unknown collection", status: 404)
            }
            let body = (try? JSONSerialization.jsonObject(with: request.body, options: [])) as? [String: Any] ?? [:]
            let payload = (body["payload"] as? [String: Any]) ?? [:]
            let stats = FlowSyncPayloadCodec.apply(collection: collection, payload: payload)
            lock.lock()
            hostStats[collection] = stats
            hostCompleted.insert(collection)
            let completed = hostCompleted.count
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.state = .transferring(
                    collection: collection,
                    done: completed,
                    total: max(self.hostCollections.count, completed)
                )
            }
            return FlowSyncHTTPResponse.json(["ok": true])

        case ("POST", "/flow-sync/finish"):
            lock.lock()
            let stats = hostStats
            let completed = hostCompleted
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.state = .done(peerName: self.peerName, stats: stats)
                self.stop(keepingState: true)
            }
            _ = completed
            return FlowSyncHTTPResponse.json(["ok": true])

        default:
            return FlowSyncHTTPResponse.message("Not found", status: 404)
        }
    }

    // MARK: - Teardown

    /// Ends the session and releases the listener. `keepingState` leaves the final card on screen.
    func stop(keepingState: Bool = false) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        clientTask?.cancel()
        clientTask = nil
        server.stop()
        server.handler = nil
        publisher.stop()
        code = nil
        clientCode = nil
        lock.lock()
        verificationConfirmed = false
        consentGranted = false
        lock.unlock()
        if !keepingState {
            if case .done = state {
                return
            }
            if case .failed = state {
                return
            }
            state = .idle
        }
    }

    // MARK: - Helpers

    private func endpoint(_ code: FlowSyncCode, path: String, query: [String: String]) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = code.address
        components.port = code.port
        components.path = FlowSyncCode.path + path
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }

    static func deviceName() -> String {
        let prefs = FlowApp.shared.prefs
        if let stored = prefs.string(for: .syncDeviceName), !stored.isBlank {
            return stored
        }
        let name = UIDevice.current.name
        let trimmed = name.isBlank ? "Flow device" : name
        prefs.set(trimmed, for: .syncDeviceName)
        return trimmed
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost:
            return "Couldn't reach the other device. Check that both devices are on the same Wi-Fi and that a VPN or firewall isn't blocking the connection."
        case NSURLErrorTimedOut:
            return "The other device stopped responding. Keep Flow open on both devices and try again."
        default:
            return nsError.localizedDescription
        }
    }
}

// MARK: - Collection row

/// One collection in the picker: icon, name, what it covers and a switch.
final class SyncCollectionRow: UITableViewCell {

    static let reuseIdentifier = "SyncCollectionRow"

    private let iconContainer = UIView()
    private let iconView = FlowIconView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let toggle = UISwitch()

    var onToggle: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.layer.cornerRadius = 20.0
        iconContainer.layer.masksToBounds = true
        contentView.addSubview(iconContainer)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.iconSize = 20.0
        iconContainer.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FlowTypography.titleSmall
        titleLabel.numberOfLines = 1
        contentView.addSubview(titleLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = FlowTypography.bodySmall
        detailLabel.numberOfLines = 2
        contentView.addSubview(detailLabel)

        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.addTarget(self, action: #selector(handleToggle), for: .valueChanged)
        contentView.addSubview(toggle)

        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: FlowSpacing.screenMargin),
            iconContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 40.0),
            iconContainer.heightAnchor.constraint(equalToConstant: 40.0),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: FlowSpacing.lg),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: FlowSpacing.lg),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -FlowSpacing.md),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -FlowSpacing.md),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2.0),
            detailLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -FlowSpacing.lg),

            toggle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            toggle.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        applyTheme()
    }

    func configure(collection: SyncCollection, isOn: Bool, isEnabled: Bool) {
        titleLabel.text = collection.title
        detailLabel.text = collection.detail
        iconView.icon = collection.icon
        toggle.isOn = isOn
        toggle.isEnabled = isEnabled
        applyTheme()
    }

    @objc private func handleToggle() {
        onToggle?(toggle.isOn)
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        iconContainer.backgroundColor = scheme.surfaceContainerHigh
        iconView.iconColor = scheme.primary
        titleLabel.textColor = scheme.onSurface
        detailLabel.textColor = scheme.onSurfaceVariant
        toggle.onTintColor = scheme.primary
    }
}

// MARK: - Screen

/// Device-to-device sync over the local network: advertise, browse, pair with a QR code, verify the
/// six-digit code, choose what to send, confirm the merge, then watch each collection land.
final class SyncViewController: UIViewController {

    // MARK: - State

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let roleControl = FlowSegmentedControl()
    private let introLabel = UILabel()
    private let table = UITableView(frame: .zero, style: .plain)
    private let startButton = FlowButton.make("Show a code", style: .filled, icon: .sync)
    private let joinButton = FlowButton.make("Enter a code", style: .outlined, icon: .importIcon)
    private let peerLabel = UILabel()
    private let peerStack = UIStackView()

    private let codeCard = FlowCard.make(elevation: .high)
    private let qrImageView = UIImageView()
    private let codeTitleLabel = UILabel()
    private let codeDetailLabel = UILabel()
    private let countdownLabel = UILabel()
    private let addressLabel = UILabel()
    private let copyCodeButton = FlowButton.make("Copy connection data", style: .tonal, icon: .share)
    private let cancelButton = FlowButton.make("Cancel sync", style: .text)
    private let verificationCard = FlowCard.make(elevation: .high)
    private let verificationDigits = UILabel()
    private let verificationBody = UILabel()
    private let verificationMatch = FlowButton.make("They match", style: .filled, icon: .check)
    private let verificationDiffer = FlowButton.make("They differ", style: .text)
    private let consentCard = FlowCard.make(elevation: .high)
    private let consentTitle = UILabel()
    private let consentBody = UILabel()
    private let consentMerge = FlowButton.make("Merge", style: .filled, icon: .check)
    private let consentDecline = FlowButton.make("Decline", style: .text)
    private let progressCard = FlowCard.make(elevation: .standard)
    private let progressLabel = UILabel()
    private let progressBar = UIProgressView(progressViewStyle: .default)
    private let doneCard = FlowCard.make(elevation: .high)
    private let doneTitle = UILabel()
    private let doneBody = UILabel()
    private let doneButton = FlowButton.make("Done", style: .filled)
    private let failureCard = FlowCard.make(elevation: .standard)
    private let failureLabel = UILabel()
    private let retryButton = FlowButton.make("Try again", style: .tonal, icon: .sync)

    private let session = FlowSyncSession()
    private let browser = FlowSyncBonjourBrowser()
    private var selected: Set<SyncCollection> = Set(SyncCollection.allCases)
    private var role: FlowSyncRole = .sender
    private var countdownTimer: Timer?
    private var themeToken: ObservationToken?
    private var tableHeight: NSLayoutConstraint?
    private var pendingCode: String = ""

    deinit {
        themeToken?.cancelObservation()
        countdownTimer?.invalidate()
        browser.stop()
        session.stop()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sync devices"
        view.backgroundColor = FlowTheme.shared.background
        buildLayout()
        bindSession()
        bindBrowser()
        themeToken = FlowEventBus.shared.on("theme") { [weak self] _ in
            self?.applyTheme()
        }
        applyTheme()
        show(.idle)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        browser.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        browser.stop()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return FlowTheme.shared.isDark ? .lightContent : .default
    }

    // MARK: - Layout

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag
        view.addSubview(scrollView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = FlowSpacing.lg
        scrollView.addSubview(contentStack)

        introLabel.font = FlowTypography.bodyMedium
        introLabel.numberOfLines = 0
        introLabel.text = "Sync your library, history and notes with another device over Wi-Fi. Nothing leaves your network."
        contentStack.addArrangedSubview(introLabel)

        roleControl.setTitles([FlowSyncRole.sender.title, FlowSyncRole.receiver.title], selectedIndex: 0)
        roleControl.onSelect = { [weak self] index in
            guard let self = self else { return }
            self.role = index == 1 ? .receiver : .sender
            self.startButton.configure(
                title: self.role == .sender ? "Show a code" : "Show a receive code",
                style: .filled,
                icon: .sync
            )
            self.startButton.applyTheme()
        }
        contentStack.addArrangedSubview(roleControl)

        let header = FlowSectionHeader.make(title: "Choose what to send", subtitle: "Only the selected collections are transferred.")
        contentStack.addArrangedSubview(header)

        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 76.0
        table.isScrollEnabled = false
        table.dataSource = self
        table.delegate = self
        table.register(SyncCollectionRow.self, forCellReuseIdentifier: SyncCollectionRow.reuseIdentifier)
        let height = table.heightAnchor.constraint(equalToConstant: 0.0)
        height.priority = UILayoutPriority(999.0)
        height.isActive = true
        tableHeight = height
        contentStack.addArrangedSubview(table)

        let buttons = UIStackView(arrangedSubviews: [startButton, joinButton])
        buttons.axis = .vertical
        buttons.spacing = FlowSpacing.md
        buttons.distribution = .fillEqually
        startButton.heightAnchor.constraint(equalToConstant: 48.0).isActive = true
        joinButton.heightAnchor.constraint(equalToConstant: 48.0).isActive = true
        startButton.onTap = { [weak self] in
            self?.startHosting()
        }
        joinButton.onTap = { [weak self] in
            self?.presentCodeEntry()
        }
        contentStack.addArrangedSubview(buttons)

        peerStack.axis = .vertical
        peerStack.spacing = FlowSpacing.xs
        peerLabel.font = FlowTypography.bodySmall
        peerLabel.numberOfLines = 0
        peerLabel.text = "Looking for other devices on this network…"
        peerStack.addArrangedSubview(peerLabel)
        contentStack.addArrangedSubview(peerStack)

        buildCodeCard()
        buildVerificationCard()
        buildConsentCard()
        buildProgressCard()
        buildDoneCard()
        buildFailureCard()

        contentStack.addArrangedSubview(codeCard)
        contentStack.addArrangedSubview(verificationCard)
        contentStack.addArrangedSubview(consentCard)
        contentStack.addArrangedSubview(progressCard)
        contentStack.addArrangedSubview(doneCard)
        contentStack.addArrangedSubview(failureCard)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: FlowSpacing.screenMargin),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -FlowSpacing.screenMargin),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: FlowSpacing.md),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -FlowSpacing.xxl),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -FlowSpacing.screenMargin * 2.0),
        ])
    }

    private func buildCodeCard() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = FlowSpacing.md
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        codeCard.contentView.addSubview(stack)

        codeTitleLabel.font = FlowTypography.titleLarge
        codeTitleLabel.textAlignment = .center
        codeTitleLabel.numberOfLines = 2
        codeDetailLabel.font = FlowTypography.bodyMedium
        codeDetailLabel.textAlignment = .center
        codeDetailLabel.numberOfLines = 2

        qrImageView.translatesAutoresizingMaskIntoConstraints = false
        qrImageView.contentMode = .scaleAspectFit
        qrImageView.backgroundColor = .white
        qrImageView.layer.cornerRadius = FlowShapes.small
        qrImageView.layer.masksToBounds = true
        qrImageView.isAccessibilityElement = true
        qrImageView.accessibilityLabel = "Sync QR code"

        countdownLabel.font = FlowTypography.labelLarge
        countdownLabel.textAlignment = .center
        addressLabel.font = FlowTypography.bodySmall
        addressLabel.textAlignment = .center
        addressLabel.numberOfLines = 2

        copyCodeButton.onTap = { [weak self] in
            guard let self = self, !self.pendingCode.isEmpty else { return }
            UIPasteboard.general.string = self.pendingCode
            FlowSnackbar.show("Connection data copied")
        }
        cancelButton.onTap = { [weak self] in
            self?.session.stop()
            self?.show(.idle)
        }

        stack.addArrangedSubview(codeTitleLabel)
        stack.addArrangedSubview(qrImageView)
        stack.addArrangedSubview(codeDetailLabel)
        stack.addArrangedSubview(countdownLabel)
        stack.addArrangedSubview(addressLabel)
        stack.addArrangedSubview(copyCodeButton)
        stack.addArrangedSubview(cancelButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: codeCard.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: codeCard.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: codeCard.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: codeCard.contentView.bottomAnchor),

            qrImageView.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
            qrImageView.widthAnchor.constraint(equalToConstant: 220.0),
            qrImageView.heightAnchor.constraint(equalToConstant: 220.0),
        ])
    }

    private func buildVerificationCard() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = FlowSpacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        verificationCard.contentView.addSubview(stack)

        let title = UILabel()
        title.font = FlowTypography.titleLarge
        title.text = "Do the verification codes match?"
        title.numberOfLines = 2

        verificationDigits.font = FlowTypography.displayMedium
        verificationDigits.textAlignment = .center
        verificationDigits.accessibilityLabel = "Verification code"

        verificationBody.font = FlowTypography.bodyMedium
        verificationBody.numberOfLines = 3
        verificationBody.text = "Make sure both devices show this same 6-digit code."

        let buttons = UIStackView(arrangedSubviews: [verificationDiffer, verificationMatch])
        buttons.axis = .horizontal
        buttons.spacing = FlowSpacing.md
        buttons.distribution = .fillEqually

        verificationMatch.onTap = { [weak self] in
            guard let self = self else { return }
            if self.session.isHost {
                self.session.confirmVerification()
            } else {
                self.session.confirmJoin()
            }
        }
        verificationDiffer.onTap = { [weak self] in
            guard let self = self else { return }
            if self.session.isHost {
                self.session.rejectVerification()
            } else {
                self.session.rejectJoin()
            }
        }

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(verificationDigits)
        stack.addArrangedSubview(verificationBody)
        stack.addArrangedSubview(buttons)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: verificationCard.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: verificationCard.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: verificationCard.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: verificationCard.contentView.bottomAnchor),
        ])
    }

    private func buildConsentCard() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = FlowSpacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        consentCard.contentView.addSubview(stack)

        consentTitle.font = FlowTypography.titleLarge
        consentTitle.text = "Merge incoming data?"
        consentTitle.numberOfLines = 2

        consentBody.font = FlowTypography.bodyMedium
        consentBody.numberOfLines = 6

        let buttons = UIStackView(arrangedSubviews: [consentDecline, consentMerge])
        buttons.axis = .horizontal
        buttons.spacing = FlowSpacing.md
        buttons.distribution = .fillEqually

        consentMerge.onTap = { [weak self] in
            self?.session.grantConsent()
        }
        consentDecline.onTap = { [weak self] in
            self?.session.declineConsent()
        }

        stack.addArrangedSubview(consentTitle)
        stack.addArrangedSubview(consentBody)
        stack.addArrangedSubview(buttons)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: consentCard.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: consentCard.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: consentCard.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: consentCard.contentView.bottomAnchor),
        ])
    }

    private func buildProgressCard() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = FlowSpacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        progressCard.contentView.addSubview(stack)

        progressLabel.font = FlowTypography.titleSmall
        progressLabel.numberOfLines = 2
        progressBar.progressTintColor = FlowTheme.shared.primary
        progressBar.trackTintColor = FlowTheme.shared.scheme.surfaceContainerHighest

        stack.addArrangedSubview(progressLabel)
        stack.addArrangedSubview(progressBar)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: progressCard.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: progressCard.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: progressCard.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: progressCard.contentView.bottomAnchor),
        ])
    }

    private func buildDoneCard() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = FlowSpacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        doneCard.contentView.addSubview(stack)

        doneTitle.font = FlowTypography.titleLarge
        doneTitle.text = "Sync complete"
        doneBody.font = FlowTypography.bodyMedium
        doneBody.numberOfLines = 12
        doneButton.onTap = { [weak self] in
            self?.show(.idle)
        }

        stack.addArrangedSubview(doneTitle)
        stack.addArrangedSubview(doneBody)
        stack.addArrangedSubview(doneButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: doneCard.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doneCard.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doneCard.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doneCard.contentView.bottomAnchor),
        ])
    }

    private func buildFailureCard() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = FlowSpacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        failureCard.contentView.addSubview(stack)

        let title = UILabel()
        title.font = FlowTypography.titleLarge
        title.text = "Sync failed"

        failureLabel.font = FlowTypography.bodyMedium
        failureLabel.numberOfLines = 6
        retryButton.onTap = { [weak self] in
            self?.show(.idle)
        }

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(failureLabel)
        stack.addArrangedSubview(retryButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: failureCard.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: failureCard.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: failureCard.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: failureCard.contentView.bottomAnchor),
        ])
    }

    // MARK: - Binding

    private func bindSession() {
        session.onState = { [weak self] state in
            self?.show(state)
        }
    }

    private func bindBrowser() {
        browser.onChange = { [weak self] peers in
            guard let self = self else { return }
            if peers.isEmpty {
                self.peerLabel.text = "Looking for other devices on this network…"
            } else {
                let names = peers.map { $0.name }.joined(separator: ", ")
                self.peerLabel.text = "On this network: " + names + ". Scan their code to connect."
            }
            self.applyTheme()
        }
    }

    // MARK: - Actions

    private func startHosting() {
        pendingCode = ""
        session.startHosting(role: role, collections: selected)
    }

    private func presentCodeEntry() {
        let content = SyncCodeEntryContent()
        let sheet = FlowSheet(content: content, title: "Enter connection data", detent: .medium, showsGrabber: true)
        content.onCancel = { [weak sheet] in
            sheet?.dismissSheet()
        }
        content.onConnect = { [weak self, weak sheet] text in
            guard let self = self else { return }
            guard !text.isBlank else {
                FlowSnackbar.showError("Paste or type the code first")
                return
            }
            sheet?.dismissSheet()
            self.session.join(codeText: text, collections: self.selected)
        }
        sheet.present(from: self)
    }

    /// Shows the card for `state` and hides every other one.
    private func show(_ state: FlowSyncSession.State) {
        codeCard.isHidden = true
        verificationCard.isHidden = true
        consentCard.isHidden = true
        progressCard.isHidden = true
        doneCard.isHidden = true
        failureCard.isHidden = true
        startButton.isEnabled = true
        joinButton.isEnabled = true
        countdownTimer?.invalidate()
        countdownTimer = nil

        switch state {
        case .idle:
            break

        case .preparing:
            progressCard.isHidden = false
            progressLabel.text = "Preparing…"
            progressBar.progress = 0.1
            startButton.isEnabled = false
            joinButton.isEnabled = false

        case .showingCode(let code, let text):
            pendingCode = text
            codeCard.isHidden = false
            codeTitleLabel.text = role == .sender
                ? "Scan this on the device you're sending to"
                : "Scan this on the device you're receiving from"
            codeDetailLabel.text = "Both devices must be on the same Wi-Fi or hotspot."
            addressLabel.text = "This device: " + code.address + ":" + String(code.port)
            qrImageView.image = FlowSyncQRCodeRenderer.image(for: text, size: 660.0)
            startButton.isEnabled = false
            joinButton.isEnabled = false
            startCountdown(until: code.expiresAt)

        case .connecting:
            progressCard.isHidden = false
            progressLabel.text = "Connecting…"
            progressBar.progress = 0.2
            startButton.isEnabled = false
            joinButton.isEnabled = false

        case .awaitingVerification(let code, let peer):
            verificationCard.isHidden = false
            verificationDigits.text = code
            verificationBody.text = "Make sure both devices show this same 6-digit code. " + peer + " is the other device."
            startButton.isEnabled = false
            joinButton.isEnabled = false

        case .waiting(let peer):
            progressCard.isHidden = false
            progressLabel.text = "Waiting for " + peer + "…"
            progressBar.progress = 0.35
            startButton.isEnabled = false
            joinButton.isEnabled = false

        case .awaitingConsent(let collections, let peer):
            consentCard.isHidden = false
            let names = collections.map { $0.title }.joined(separator: ", ")
            consentBody.text = peer + " wants to merge: " + (names.isEmpty ? "nothing selected" : names) + ". Merging never overwrites or duplicates anything already on this device."
            startButton.isEnabled = false
            joinButton.isEnabled = false

        case .transferring(let collection, let done, let total):
            progressCard.isHidden = false
            progressLabel.text = "Syncing " + collection.title + "… (" + String(done + 1) + " / " + String(max(total, 1)) + ")"
            progressBar.progress = Float(min(max(Double(done) / Double(max(total, 1)), 0.0), 1.0))
            startButton.isEnabled = false
            joinButton.isEnabled = false

        case .done(let peer, let stats):
            doneCard.isHidden = false
            doneTitle.text = "Synced with " + peer
            var lines: [String] = []
            for collection in SyncCollection.allCases {
                if let entry = stats[collection] {
                    lines.append(collection.title + ": " + entry.summary)
                }
            }
            doneBody.text = lines.isEmpty ? "Nothing needed to change." : lines.joined(separator: "\n")
            startButton.isEnabled = true
            joinButton.isEnabled = true

        case .failed(let message):
            failureCard.isHidden = false
            failureLabel.text = message
            startButton.isEnabled = true
            joinButton.isEnabled = true
        }
        applyTheme()
    }

    private func startCountdown(until date: Date) {
        updateCountdown(until: date)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            if Date() >= date {
                timer.invalidate()
                self.countdownLabel.text = "Code expired"
                return
            }
            self.updateCountdown(until: date)
        }
    }

    private func updateCountdown(until date: Date) {
        let remaining = max(0, Int(date.timeIntervalSinceNow.rounded(.up)))
        countdownLabel.text = "Expires in " + String(remaining) + "s"
    }

    // MARK: - Theming

    private func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        view.backgroundColor = scheme.background
        scrollView.backgroundColor = .clear
        introLabel.textColor = scheme.onSurfaceVariant
        peerLabel.textColor = scheme.onSurfaceVariant
        roleControl.applyTheme()
        startButton.applyTheme()
        joinButton.applyTheme()
        copyCodeButton.applyTheme()
        cancelButton.applyTheme()
        verificationMatch.applyTheme()
        verificationDiffer.applyTheme()
        consentMerge.applyTheme()
        consentDecline.applyTheme()
        doneButton.applyTheme()
        retryButton.applyTheme()
        progressBar.progressTintColor = scheme.primary
        progressBar.trackTintColor = scheme.surfaceContainerHighest
        for card in [codeCard, verificationCard, consentCard, progressCard, doneCard, failureCard] {
            card.applyTheme()
        }
        codeTitleLabel.textColor = scheme.onSurface
        codeDetailLabel.textColor = scheme.onSurfaceVariant
        countdownLabel.textColor = scheme.primary
        addressLabel.textColor = scheme.onSurfaceVariant
        verificationDigits.textColor = scheme.primary
        verificationBody.textColor = scheme.onSurfaceVariant
        consentTitle.textColor = scheme.onSurface
        consentBody.textColor = scheme.onSurfaceVariant
        progressLabel.textColor = scheme.onSurface
        doneTitle.textColor = scheme.onSurface
        doneBody.textColor = scheme.onSurfaceVariant
        failureLabel.textColor = scheme.onSurfaceVariant
        table.reloadData()
        table.layoutIfNeeded()
        tableHeight?.constant = table.contentSize.height
    }
}

// MARK: - Data source

extension SyncViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return SyncCollection.allCases.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: SyncCollectionRow.reuseIdentifier, for: indexPath)
        guard let row = cell as? SyncCollectionRow,
              let collection = SyncCollection.allCases.element(at: indexPath.row) else {
            return cell
        }
        row.configure(
            collection: collection,
            isOn: selected.contains(collection),
            isEnabled: !session.isActive
        )
        row.onToggle = { [weak self] isOn in
            guard let self = self else { return }
            if isOn {
                self.selected.insert(collection)
            } else {
                self.selected.remove(collection)
            }
        }
        return row
    }
}

extension SyncViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

// MARK: - Code entry

/// The sheet for pasting a code from a device that cannot show a QR on screen, or for a device
/// whose camera is unavailable.
final class SyncCodeEntryContent: UIView, UITextViewDelegate {

    var onConnect: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let textView = UITextView()
    private let hintLabel = UILabel()
    private let securityLabel = UILabel()
    private let connectButton = FlowButton.make("Connect", style: .filled)
    private let cancelButton = FlowButton.make("Cancel", style: .text)

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = FlowTypography.bodyMedium
        hintLabel.numberOfLines = 2
        hintLabel.text = "Paste the connection data the other device copied."
        addSubview(hintLabel)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = FlowTypography.bodyMedium
        textView.layer.cornerRadius = FlowShapes.small
        textView.textContainerInset = UIEdgeInsets.all(FlowSpacing.md)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.delegate = self
        addSubview(textView)

        securityLabel.translatesAutoresizingMaskIntoConstraints = false
        securityLabel.font = FlowTypography.bodySmall
        securityLabel.numberOfLines = 2
        securityLabel.text = "Contains a temporary key. Only share it with the device you are syncing."
        addSubview(securityLabel)

        let buttons = UIStackView(arrangedSubviews: [cancelButton, connectButton])
        buttons.axis = .horizontal
        buttons.spacing = FlowSpacing.md
        buttons.distribution = .fillEqually
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        connectButton.onTap = { [weak self] in
            guard let self = self else { return }
            self.onConnect?(self.textView.text ?? "")
        }
        cancelButton.onTap = { [weak self] in
            self?.onCancel?()
        }

        NSLayoutConstraint.activate([
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FlowSpacing.xl),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FlowSpacing.xl),
            hintLabel.topAnchor.constraint(equalTo: topAnchor, constant: FlowSpacing.md),

            textView.leadingAnchor.constraint(equalTo: hintLabel.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: hintLabel.trailingAnchor),
            textView.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: FlowSpacing.md),
            textView.heightAnchor.constraint(equalToConstant: 110.0),

            securityLabel.leadingAnchor.constraint(equalTo: hintLabel.leadingAnchor),
            securityLabel.trailingAnchor.constraint(equalTo: hintLabel.trailingAnchor),
            securityLabel.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: FlowSpacing.sm),

            buttons.leadingAnchor.constraint(equalTo: hintLabel.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: hintLabel.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: securityLabel.bottomAnchor, constant: FlowSpacing.md),
            buttons.heightAnchor.constraint(equalToConstant: 48.0),
            buttons.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -FlowSpacing.md),
        ])
        applyTheme()
    }

    func applyTheme() {
        let scheme = FlowTheme.shared.scheme
        hintLabel.textColor = scheme.onSurface
        securityLabel.textColor = scheme.onSurfaceVariant
        textView.backgroundColor = scheme.surfaceContainerHigh
        textView.textColor = scheme.onSurface
        connectButton.applyTheme()
        cancelButton.applyTheme()
    }
}
