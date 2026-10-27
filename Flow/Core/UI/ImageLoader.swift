import UIKit

/// Loads and caches remote images. Two levels — an `NSCache` in memory and a directory on disk —
/// with request coalescing so a shelf of twenty cards asking for the same thumbnail opens one
/// connection, not twenty.
///
/// Every callback is delivered on the main queue.
final class ImageLoader {

    static let shared = ImageLoader()

    /// The decoded image and the cost it occupies, so the memory cache can evict sensibly.
    private final class Entry {
        let image: UIImage
        let cost: Int

        init(image: UIImage) {
            self.image = image
            let pixels = image.size.width * image.size.height * image.scale * image.scale
            cost = Int(pixels * 4.0)
        }
    }

    private let memory = NSCache<NSString, Entry>()
    private let diskQueue = DispatchQueue(label: "org.flowtube.Flow.imageDisk", qos: .utility)
    private let session: URLSession
    private let directory: URL

    private let lock = NSLock()
    private var inFlight: [String: [(UIImage?) -> Void]] = [:]

    /// The maximum number of bytes kept on disk. Older files are evicted past it.
    var diskLimit: Int64 = 200 * 1024 * 1024

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20.0
        configuration.timeoutIntervalForResource = 60.0
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        self.session = session ?? URLSession(configuration: configuration)

        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        directory = URL(fileURLWithPath: caches).appendingPathComponent("FlowImages", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }

        memory.countLimit = 300
        memory.totalCostLimit = 80 * 1024 * 1024

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    // MARK: - Public API

    /// Returns a cached image synchronously, if there is one. Never touches the network.
    func cachedImage(for urlString: String) -> UIImage? {
        guard !urlString.isEmpty else { return nil }
        if let entry = memory.object(forKey: urlString as NSString) {
            return entry.image
        }
        let path = diskPath(for: urlString)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard let data = try? Data(contentsOf: path), let image = UIImage(data: data) else { return nil }
        memory.setObject(Entry(image: image), forKey: urlString as NSString)
        return image
    }

    /// Loads `urlString`, calling `completion` on the main queue with the image or nil.
    /// A second request for the same URL while the first is in flight joins it.
    func load(_ urlString: String, completion: @escaping (UIImage?) -> Void) {
        guard !urlString.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        if let entry = memory.object(forKey: urlString as NSString) {
            DispatchQueue.main.async { completion(entry.image) }
            return
        }

        lock.lock()
        if var waiting = inFlight[urlString] {
            waiting.append(completion)
            inFlight[urlString] = waiting
            lock.unlock()
            return
        }
        inFlight[urlString] = [completion]
        lock.unlock()

        let path = diskPath(for: urlString)
        diskQueue.async { [weak self] in
            guard let self = self else { return }
            if let data = try? Data(contentsOf: path), let image = UIImage(data: data) {
                self.memory.setObject(Entry(image: image), forKey: urlString as NSString)
                self.finish(urlString: urlString, image: image)
                return
            }
            self.fetch(urlString: urlString, path: path)
        }
    }

    /// Loads an image and decodes it to exactly `size`, so a shelf of thumbnails does not keep
    /// full-resolution bitmaps in memory.
    func load(_ urlString: String, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) {
        let key = "\(urlString)#\(Int(targetSize.width))x\(Int(targetSize.height))"
        if let entry = memory.object(forKey: key as NSString) {
            DispatchQueue.main.async { completion(entry.image) }
            return
        }
        load(urlString) { image in
            guard let source = image else {
                completion(nil)
                return
            }
            guard source.size.width > targetSize.width * 1.5 else {
                completion(source)
                return
            }
            let scaled = ImageLoader.downsample(source, to: targetSize)
            self.memory.setObject(Entry(image: scaled), forKey: key as NSString)
            completion(scaled)
        }
    }

    /// Prefetches images for rows that are about to scroll into view.
    func prefetch(_ urlStrings: [String]) {
        for urlString in urlStrings where !urlString.isEmpty {
            if memory.object(forKey: urlString as NSString) != nil { continue }
            load(urlString) { _ in }
        }
    }

    /// Drops the in-memory cache. Called on a memory warning and by the storage screen.
    func clearMemory() {
        memory.removeAllObjects()
        FlowEventBus.shared.broadcast("images", notification: .flowImageCacheDidClear)
    }

    /// Drops the disk cache.
    func clearDisk() {
        diskQueue.async { [weak self] in
            guard let self = self else { return }
            let manager = FileManager.default
            if let files = try? manager.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) {
                for file in files {
                    try? manager.removeItem(at: file)
                }
            }
            self.memory.removeAllObjects()
            DispatchQueue.main.async {
                FlowEventBus.shared.broadcast("images", notification: .flowImageCacheDidClear)
            }
        }
    }

    /// The number of bytes the disk cache occupies.
    func diskSize() -> Int64 {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for file in files {
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Fetching

    private func fetch(urlString: String, path: URL) {
        guard let url = URL(string: urlString) else {
            finish(urlString: urlString, image: nil)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.setValue("Flow/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self = self else { return }
            guard
                let payload = data,
                let http = response as? HTTPURLResponse,
                http.statusCode >= 200,
                http.statusCode < 300,
                let image = UIImage(data: payload)
            else {
                self.finish(urlString: urlString, image: nil)
                return
            }
            try? payload.write(to: path, options: .atomic)
            self.memory.setObject(Entry(image: image), forKey: urlString as NSString)
            self.finish(urlString: urlString, image: image)
        }
        task.resume()
    }

    private func finish(urlString: String, image: UIImage?) {
        lock.lock()
        let waiting = inFlight.removeValue(forKey: urlString) ?? []
        lock.unlock()
        DispatchQueue.main.async {
            for completion in waiting {
                completion(image)
            }
        }
    }

    // MARK: - Disk

    /// A stable file name for a URL, so the same image is never stored twice.
    private func diskPath(for urlString: String) -> URL {
        let name = String(urlString.stableHash, radix: 16)
        return directory.appendingPathComponent(name)
    }

    /// Trims the disk cache to `diskLimit`, deleting the oldest files first.
    func trimDiskCache() {
        diskQueue.async { [weak self] in
            guard let self = self else { return }
            let manager = FileManager.default
            guard let files = try? manager.contentsOfDirectory(
                at: self.directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            ) else {
                return
            }
            var entries: [(url: URL, size: Int64, date: Date)] = []
            var total: Int64 = 0
            for file in files {
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
                let size = Int64(values.fileSize ?? 0)
                let date = values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                entries.append((file, size, date))
                total += size
            }
            guard total > self.diskLimit else { return }
            entries.sort { $0.date < $1.date }
            for entry in entries {
                if total <= self.diskLimit { break }
                try? manager.removeItem(at: entry.url)
                total -= entry.size
            }
        }
    }

    @objc private func handleMemoryWarning() {
        memory.removeAllObjects()
    }

    // MARK: - Downsampling

    /// Redraws `image` into a bitmap no larger than `size`, preserving aspect ratio.
    static func downsample(_ image: UIImage, to size: CGSize) -> UIImage {
        guard size.width > 0, size.height > 0 else { return image }
        let widthRatio = size.width / max(image.size.width, 1.0)
        let heightRatio = size.height / max(image.size.height, 1.0)
        let ratio = min(widthRatio, heightRatio)
        if ratio >= 1.0 { return image }
        let target = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        UIGraphicsBeginImageContextWithOptions(target, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: target))
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }

    /// A deterministic placeholder colour for a URL, so a failing thumbnail still reads as a shape
    /// rather than a hole. Derived from the palette, never an arbitrary hex.
    static func placeholderColor(for urlString: String, in scheme: FlowColorScheme) -> UIColor {
        let hash = urlString.stableHash
        let step = CGFloat(hash % 3) / 2.0
        return scheme.surfaceContainerHigh.mixed(with: scheme.surfaceContainerHighest, amount: step)
    }
}
