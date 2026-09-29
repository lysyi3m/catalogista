import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

/// On-disk cache for cover art, keyed by release id.
///
/// Thumbs and covers are stored in separate slots. The cover is Discogs' 600px `cover_image`; the
/// thumb is the fallback for a release with no cover. Each file records the URL it was downloaded
/// from, and a request for a different URL downloads again — so the art follows Discogs, and an
/// app that quits halfway through a sync cannot strand an old image.
///
/// A file with no recorded source is downloaded again, because nothing shows which image it is.
/// Until a download succeeds the file on disk is still served, so the collection stays browsable
/// offline. There is no size-based eviction.
///
/// Image requests do not pass through `RateLimiter`. Measured against the live API, `i.discogs.com`
/// returns no `X-Discogs-Ratelimit*` headers and does not move the counter, so the CDN has its own
/// budget. Concurrency is capped instead, to avoid opening dozens of sockets during a first sync.
actor ImageCache {
    enum Kind: String, Sendable {
        /// ~150px, embedded in every collection item.
        case thumb
        /// `cover_image`, 600px. The grid and the record page both draw it.
        case cover
    }

    enum CacheError: Error, LocalizedError {
        case badResponse(status: Int)
        case notAnImage
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .badResponse(let status): return "Image request failed with HTTP \(status)."
            case .notAnImage: return "The downloaded file was not a decodable image."
            case .tooLarge: return "The image is too large to cache."
            }
        }
    }

    /// Far above any cover or release image Discogs serves (a 600px cover is about 100 KB), and
    /// far below what would strain memory: the whole response is held before it is checked.
    static let maximumBytes = 20 * 1024 * 1024
    /// Checked from the image's header before it is decoded in full. A full decode of a larger
    /// image costs hundreds of megabytes for a picture drawn a few hundred points wide.
    static let maximumPixelDimension = 8000

    private let directory: URL
    private let session: URLSession
    private let maximumConcurrentDownloads: Int
    /// Read synchronously by views as they are drawn, so it sits outside the actor.
    nonisolated let decoded: DecodedImageCache

    private var activeDownloads = 0
    /// Downloads waiting for a slot, first come first served, covers on screen ahead of the
    /// warmer's prefetch. Without the split a cover the user is looking at could queue behind the
    /// whole collection.
    private var visibleWaiters: [Waiter] = []
    private var backgroundWaiters: [Waiter] = []

    private struct Waiter {
        let id: UUID
        let destination: URL
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// Who is waiting for an image, which sets its place in the queue.
    enum Priority: Sendable {
        /// A cover on screen.
        case visible
        /// A prefetch that nobody is looking at yet.
        case background
    }
    /// Coalesces concurrent requests for the same file so a cover is fetched once, not once per
    /// view.
    /// Keyed by destination; the source URL is kept so a request for a newer image never joins the
    /// download of an older one.
    private var inFlight: [URL: (source: URL, task: Task<URL, any Error>)] = [:]

    init(
        directory: URL? = nil,
        // Ephemeral: the files here are the cache, and a second copy in the shared URL cache would
        // survive disconnecting.
        session: URLSession = URLSession(configuration: .ephemeral),
        maximumConcurrentDownloads: Int = 6,
        decoded: DecodedImageCache = DecodedImageCache()
    ) {
        self.directory = directory ?? Self.defaultDirectory()
        self.session = session
        self.maximumConcurrentDownloads = max(maximumConcurrentDownloads, 1)
        self.decoded = decoded
    }

    /// Application Support, not Caches.
    ///
    /// The collection is meant to stay browsable offline, and a wall of placeholder tiles is not
    /// browsable. `Library/Caches` is purgeable by definition — the system may reclaim it whenever
    /// it likes, which is exactly when an offline user would notice. The art is regenerable in
    /// principle but not while the device has no network, so it belongs in Application Support,
    /// excluded from backup because it can always be downloaded again.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        return base.appending(path: "Catalogista/Images", directoryHint: .isDirectory)
    }

    /// Keeps the art out of iCloud and iTunes backups. It is several megabytes of data Discogs can
    /// serve again, so backing it up wastes the user's storage rather than protecting anything.
    private func excludeFromBackup() {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    func fileURL(releaseID: Int, kind: Kind) -> URL {
        directory
            .appending(path: kind.rawValue, directoryHint: .isDirectory)
            .appending(path: "\(releaseID).img", directoryHint: .notDirectory)
    }

    func isCached(releaseID: Int, kind: Kind) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(releaseID: releaseID, kind: kind).path)
    }

    /// Whether the slot holds the image `source` points at. A file with no recorded source does
    /// not count: nothing shows which image it is.
    func isCached(releaseID: Int, kind: Kind, source: URL) -> Bool {
        let file = fileURL(releaseID: releaseID, kind: kind)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        return Self.recordedSource(of: file) == source.absoluteString
    }

    /// Returns the local file for a release's art, downloading it when the slot is empty or holds
    /// an image from a different URL.
    ///
    /// Keyed by release and kind, one file per slot. Discogs serves the same artwork under several
    /// resized URLs, so every caller asks for a slot with the same URL — the grid and the record
    /// page agree on `cover_image` (see `RecordDetailView.coverSource`). A different URL therefore
    /// means Discogs changed the image, and the file is downloaded again. If that download fails,
    /// the file already on disk is returned.
    @discardableResult
    func localURL(
        releaseID: Int,
        kind: Kind,
        remoteURL: URL,
        priority: Priority = .background
    ) async throws -> URL {
        let destination = fileURL(releaseID: releaseID, kind: kind)
        let hasFile = FileManager.default.fileExists(atPath: destination.path)
        if hasFile, Self.recordedSource(of: destination) == remoteURL.absoluteString { return destination }

        do {
            return try await fetch(remoteURL, to: destination, priority: priority)
        } catch {
            // The file on disk is from another URL, or has no recorded source, so nothing vouches
            // for it. It is still what the user saw last: offline, it stays on
            // screen until Discogs is reachable, like the rest of the cache.
            guard hasFile, FileManager.default.fileExists(atPath: destination.path) else { throw error }
            return destination
        }
    }

    /// Downloads `remoteURL` into `destination`, sharing a download already in flight for the same
    /// source.
    private func fetch(_ remoteURL: URL, to destination: URL, priority: Priority) async throws -> URL {
        // A cancelled caller starts nothing. The download below is shared and does not inherit
        // the caller's cancellation, so a cancelled cover warmer would otherwise keep queuing them.
        try Task.checkCancellation()
        if let existing = inFlight[destination] {
            if existing.source == remoteURL {
                // The warmer queued this one; now it is on screen.
                if priority == .visible { promote(destination) }
                return try await existing.task.value
            }
            // Discogs changed the image while the old one was downloading. The newer request wins;
            // the older download must not land.
            existing.task.cancel()
        }

        let task = Task<URL, any Error> {
            try await withConcurrencyLimit(priority: priority, destination: destination) {
                try await download(remoteURL, to: destination)
            }
        }
        inFlight[destination] = (remoteURL, task)
        defer { if inFlight[destination]?.task == task { inFlight[destination] = nil } }
        return try await task.value
    }

    /// Decodes a cached image, downsampled so a grid of hundreds of covers stays memory-bounded.
    func image(releaseID: Int, kind: Kind, remoteURL: URL, maximumPixelSize: CGFloat) async throws -> PlatformImage {
        let url = try await localURL(releaseID: releaseID, kind: kind, remoteURL: remoteURL, priority: .visible)
        // Off the actor, so the covers on screen decode side by side rather than one at a time.
        let downsampled = await Task.detached(priority: .userInitiated) {
            Self.downsample(at: url, maximumPixelSize: maximumPixelSize)
        }.value
        guard let cgImage = downsampled else {
            // An undecodable file is worse than none: it counts as cached until its URL changes.
            // Drop it so the next request downloads again.
            try? FileManager.default.removeItem(at: url)
            throw CacheError.notAnImage
        }
        let image = Self.platformImage(cgImage)
        // Not when the file is an older image served because the new one could not be fetched:
        // held in memory under the new URL, it would stand in for the new image after it arrives.
        if Self.recordedSource(of: url) == remoteURL.absoluteString {
            decoded.insert(
                image,
                byteCount: cgImage.bytesPerRow * cgImage.height,
                releaseID: releaseID,
                kind: kind,
                source: remoteURL,
                maximumPixelSize: maximumPixelSize
            )
        }
        return image
    }

    /// The image `image(releaseID:kind:remoteURL:maximumPixelSize:)` decoded recently for the same
    /// source and size, without touching the disk.
    nonisolated func cachedImage(
        releaseID: Int,
        kind: Kind,
        remoteURL: URL,
        maximumPixelSize: CGFloat
    ) -> PlatformImage? {
        decoded.image(releaseID: releaseID, kind: kind, source: remoteURL, maximumPixelSize: maximumPixelSize)
    }

    struct Statistics: Sendable, Hashable {
        var fileCount: Int
        var byteCount: Int
    }

    /// What is on disk. Used by diagnostics, not by any eviction policy — there is none.
    func statistics() -> Statistics {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return Statistics(fileCount: 0, byteCount: 0) }

        var statistics = Statistics(fileCount: 0, byteCount: 0)
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            statistics.fileCount += 1
            statistics.byteCount += values?.fileSize ?? 0
        }
        return statistics
    }

    func diskUsage() -> Int { statistics().byteCount }

    func removeAll() async throws {
        // Downloads first: otherwise one still in flight writes its file into the deleted
        // directory, and the cache the user asked to clear is not empty.
        await cancelInFlightDownloads()
        decoded.removeAll()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Downloading

    private func download(_ remoteURL: URL, to destination: URL) async throws -> URL {
        var request = URLRequest(url: remoteURL)
        request.setValue(DiscogsUserAgent.value, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CacheError.badResponse(status: http.statusCode)
        }
        guard data.count <= Self.maximumBytes else { throw CacheError.tooLarge }
        // A 200 does not mean an image. CDNs answer with HTML error pages, empty bodies and
        // truncated responses, and a cached file is not fetched again while its URL stands — so
        // anything that is not a complete image must be rejected before it reaches the cache.
        // Off the actor: a full decode takes long enough to hold up every other cover's lookup.
        guard await Task.detached(operation: { Self.isCompleteImage(data) }).value else {
            throw CacheError.notAnImage
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        excludeFromBackup()
        // Write via a temporary file so an interrupted download never leaves a truncated image
        // that the cache would then treat as complete and keep.
        let temporary = destination.deletingLastPathComponent()
            .appending(path: UUID().uuidString, directoryHint: .notDirectory)
        // A download superseded while in flight must not write the old image over the new one.
        try Task.checkCancellation()
        try data.write(to: temporary, options: .atomic)
        // Stamped before the move, so the file never exists without its source.
        Self.recordSource(remoteURL, on: temporary)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            // Swallowing this would return a path with no file behind it and leak the temporary.
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return destination
    }

    /// Whether `data` is an image the system can decode in full.
    ///
    /// The container checks are cheap early-outs: an HTML body has no image type and an empty one
    /// has no frames. They are not sufficient on their own — a source built from a complete `Data`
    /// reports `statusComplete` even when the pixel data is truncated — so the image is decoded
    /// once to be sure. That cost is paid on first download only, and keeping a file until its
    /// URL changes makes a corrupt file expensive to accept.
    nonisolated static func isCompleteImage(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetType(source) != nil,
              CGImageSourceGetCount(source) > 0,
              hasAcceptableSize(source)
        else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    /// Reads the pixel size from the header alone. An image with no readable size is refused too:
    /// the full decode that follows would find out the size the expensive way.
    nonisolated static func hasAcceptableSize(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return width <= maximumPixelDimension && height <= maximumPixelDimension
    }

    /// Waits for a download slot, and gives it up if the caller is cancelled.
    ///
    /// A plain `withCheckedContinuation` parks the caller with nothing able to wake it: a cancelled
    /// task would sit here until some other download happened to finish. Sign-out and Reset Cache
    /// both need waiting work to stop promptly, so the wait is cancellable and the waiter removes
    /// itself.
    private func acquireSlot(priority: Priority, destination: URL) async throws {
        try Task.checkCancellation()
        guard activeDownloads >= maximumConcurrentDownloads else {
            activeDownloads += 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = Waiter(id: id, destination: destination, continuation: continuation)
                switch priority {
                case .visible: visibleWaiters.append(waiter)
                case .background: backgroundWaiters.append(waiter)
                }
            }
        } onCancel: {
            Task { await self.abandonSlot(id) }
        }
        // Resumed by `releaseSlot`, which handed its slot over rather than freeing it, so the
        // active count already accounts for this download.
    }

    private func abandonSlot(_ id: UUID) {
        if let index = visibleWaiters.firstIndex(where: { $0.id == id }) {
            visibleWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if let index = backgroundWaiters.firstIndex(where: { $0.id == id }) {
            backgroundWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves a queued prefetch of `destination` into the visible queue, behind the covers already
    /// there.
    private func promote(_ destination: URL) {
        let promoted = backgroundWaiters.filter { $0.destination == destination }
        guard !promoted.isEmpty else { return }
        backgroundWaiters.removeAll { $0.destination == destination }
        visibleWaiters.append(contentsOf: promoted)
    }

    /// Hands the slot to the next waiter rather than freeing and re-taking it, so the count cannot
    /// drift and a waiter cannot be skipped.
    private func releaseSlot() {
        if !visibleWaiters.isEmpty {
            visibleWaiters.removeFirst().continuation.resume()
        } else if !backgroundWaiters.isEmpty {
            backgroundWaiters.removeFirst().continuation.resume()
        } else {
            activeDownloads -= 1
        }
    }

    private func withConcurrencyLimit<T>(
        priority: Priority,
        destination: URL,
        _ work: () async throws -> T
    ) async throws -> T {
        try await acquireSlot(priority: priority, destination: destination)
        defer { releaseSlot() }
        return try await work()
    }

    /// Stops every download in flight and waits for them to unwind.
    ///
    /// Downloads are shared between callers, so cancelling one caller cannot stop the transfer —
    /// another caller may still be waiting on it. Clearing the cache or signing out has to stop
    /// them explicitly, or files reappear in a directory that was just emptied.
    func cancelInFlightDownloads() async {
        let tasks = inFlight.values.map(\.task)
        inFlight.removeAll()
        for task in tasks { task.cancel() }
        for waiter in visibleWaiters + backgroundWaiters {
            waiter.continuation.resume(throwing: CancellationError())
        }
        visibleWaiters.removeAll()
        backgroundWaiters.removeAll()
        for task in tasks { _ = try? await task.value }
    }

    // MARK: - Recorded source

    /// An extended attribute on each file, holding the URL it was downloaded from. It travels with
    /// the file through the atomic move, so the image and its source can never disagree.
    private static let sourceAttribute = "com.mlkshkvch.catalogista.source"

    nonisolated static func recordedSource(of file: URL) -> String? {
        let length = getxattr(file.path, sourceAttribute, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(file.path, sourceAttribute, &buffer, length, 0, 0) == length else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    nonisolated static func recordSource(_ source: URL, on file: URL) {
        let bytes = Array(source.absoluteString.utf8)
        _ = setxattr(file.path, sourceAttribute, bytes, bytes.count, 0, 0)
    }

    // MARK: - Decoding

    nonisolated static func downsample(at url: URL, maximumPixelSize: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maximumPixelSize, 1),
        ] as [CFString: Any] as CFDictionary

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    nonisolated static func platformImage(_ cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: .zero)
        #endif
    }
}
