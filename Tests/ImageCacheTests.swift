import CoreGraphics
import Foundation
import Testing
@testable import CatalogistaKit

@Suite("ImageCache")
struct ImageCacheTests {
    @Test("Clearing the cache stops downloads in flight and leaves nothing behind")
    func removeAllCancelsInFlightDownloads() async throws {
        SlowProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowProtocol.self]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let cache = ImageCache(
            directory: directory,
            session: URLSession(configuration: configuration),
            maximumConcurrentDownloads: 2
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        // More downloads than slots, so some are transferring and some are parked waiting.
        let downloads = (1...6).map { id in
            Task {
                try await cache.localURL(
                    releaseID: id,
                    kind: .cover,
                    remoteURL: URL(string: "https://i.discogs.com/\(id).jpeg")!
                )
            }
        }
        try await Task.sleep(for: .milliseconds(120))

        try await cache.removeAll()

        // A parked waiter with no way to wake would hang here; an untracked transfer would write
        // its file after the directory was deleted.
        for download in downloads { _ = try? await download.value }
        #expect(await cache.statistics().fileCount == 0, "the cleared cache must stay cleared")
    }

    @Test("The default directory is durable, not the purgeable caches directory")
    func defaultDirectoryIsApplicationSupport() {
        let directory = ImageCache.defaultDirectory()
        // Library/Caches is purgeable by definition. Cover art living there means an offline user
        // can open the app to a wall of placeholders with no way to get the art back.
        #expect(directory.path.contains("Application Support"))
        #expect(directory.path.contains("/Caches/") == false)
    }

    /// Serves a valid PNG, slowly, so downloads are still in flight when a test interrupts them.
    final class SlowProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) private static var cancelled = false
        private static let lock = NSLock()

        static func reset() {
            lock.withLock { cancelled = false }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Thread.sleep(forTimeInterval: 0.4)
            guard Self.lock.withLock({ !Self.cancelled }) else { return }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: CountingProtocol.pngBytes)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {
            Self.lock.withLock { Self.cancelled = true }
        }
    }

    /// Serves a 1x1 PNG and counts how many times each URL is requested, so "downloaded once" is a
    /// measurable claim rather than an assumption.
    final class CountingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requestCounts: [String: Int] = [:]
        nonisolated(unsafe) static var statusCode = 200
        nonisolated(unsafe) static var bodyOverride: Data?
        private static let lock = NSLock()

        static let pngBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

        static func reset() {
            lock.withLock {
                requestCounts = [:]
                statusCode = 200
                bodyOverride = nil
            }
        }

        /// Serve something other than a valid PNG, with a 200.
        static func serve(body: Data) {
            lock.withLock {
                requestCounts = [:]
                statusCode = 200
                bodyOverride = body
            }
        }

        static func count(for url: String) -> Int {
            lock.withLock { requestCounts[url] ?? 0 }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let key = request.url?.absoluteString ?? ""
            let (status, body) = Self.lock.withLock { () -> (Int, Data) in
                Self.requestCounts[key, default: 0] += 1
                return (Self.statusCode, Self.bodyOverride ?? Self.pngBytes)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if status == 200 { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeCache(directory: URL) -> ImageCache {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingProtocol.self]
        return ImageCache(
            directory: directory,
            session: URLSession(configuration: configuration),
            // Memory pressure from the rest of the machine must not empty it mid-test.
            decoded: DecodedImageCache(respondsToMemoryPressure: false)
        )
    }

    private func temporaryDirectory() -> URL {
        URL.temporaryDirectory.appending(path: "catalogista-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("An image is downloaded once and served from disk thereafter")
    func cachesPermanently() async throws {
        CountingProtocol.reset()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = makeCache(directory: directory)
        let remote = URL(string: "https://i.discogs.com/cover-1.jpeg")!

        #expect(await cache.isCached(releaseID: 1, kind: .thumb) == false)
        let first = try await cache.localURL(releaseID: 1, kind: .thumb, remoteURL: remote)
        let second = try await cache.localURL(releaseID: 1, kind: .thumb, remoteURL: remote)

        #expect(first == second)
        #expect(await cache.isCached(releaseID: 1, kind: .thumb))
        #expect(CountingProtocol.count(for: remote.absoluteString) == 1, "the second call must not re-fetch")
    }

    @Test("Thumb and cover are cached separately for the same release")
    func kindsAreIndependent() async throws {
        CountingProtocol.reset()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = makeCache(directory: directory)
        let thumb = URL(string: "https://i.discogs.com/1-thumb.jpeg")!
        let cover = URL(string: "https://i.discogs.com/1-cover.jpeg")!

        _ = try await cache.localURL(releaseID: 1, kind: .thumb, remoteURL: thumb)
        #expect(await cache.isCached(releaseID: 1, kind: .cover) == false)

        _ = try await cache.localURL(releaseID: 1, kind: .cover, remoteURL: cover)
        #expect(await cache.isCached(releaseID: 1, kind: .thumb))
        #expect(await cache.isCached(releaseID: 1, kind: .cover))
    }

    @Test("An image requested from a new URL is downloaded again; the same URL is served from disk")
    func newSourceIsFetchedAgain() async throws {
        CountingProtocol.reset()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = makeCache(directory: directory)
        let old = URL(string: "https://i.discogs.com/2-old.jpeg")!
        let new = URL(string: "https://i.discogs.com/2-new.jpeg")!
        _ = try await cache.localURL(releaseID: 2, kind: .cover, remoteURL: old)
        #expect(await cache.isCached(releaseID: 2, kind: .cover, source: old))
        #expect(await cache.isCached(releaseID: 2, kind: .cover, source: new) == false)

        // Nothing was removed first: the recorded source alone tells the file is out of date, so
        // an app that quit between saving the new URL and dropping the old file still recovers.
        _ = try await cache.localURL(releaseID: 2, kind: .cover, remoteURL: new)
        _ = try await cache.localURL(releaseID: 2, kind: .cover, remoteURL: new)
        #expect(CountingProtocol.count(for: new.absoluteString) == 1)
        #expect(await cache.isCached(releaseID: 2, kind: .cover, source: new))
    }

    @Test("A file with no recorded source is downloaded again, since nothing shows which image it is")
    func unrecordedFileIsFetchedAgain() async throws {
        CountingProtocol.reset()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = makeCache(directory: directory)
        let file = try await writeUnrecordedFile(in: cache, releaseID: 3, contents: CountingProtocol.pngBytes)
        let remote = URL(string: "https://i.discogs.com/3-cover.jpeg")!
        #expect(await cache.isCached(releaseID: 3, kind: .cover, source: remote) == false)

        // Discogs may have changed the cover since this file was written, so stamping it with
        // today's URL could vouch for the wrong image forever.
        _ = try await cache.localURL(releaseID: 3, kind: .cover, remoteURL: remote)
        #expect(CountingProtocol.count(for: remote.absoluteString) == 1)
        #expect(ImageCache.recordedSource(of: file) == remote.absoluteString)
    }

    @Test("When a new download fails, the file already on disk is still served")
    func unverifiedFileIsServedWhenDownloadFails() async throws {
        CountingProtocol.serve(body: Data("<html>unavailable</html>".utf8))
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = makeCache(directory: directory)
        let old = Data("old cover".utf8)
        let file = try await writeUnrecordedFile(in: cache, releaseID: 4, contents: old)

        let served = try await cache.localURL(
            releaseID: 4,
            kind: .cover,
            remoteURL: URL(string: "https://i.discogs.com/4-cover.jpeg")!
        )
        #expect(served == file)
        #expect(try Data(contentsOf: file) == old, "offline, the collection stays browsable")
        #expect(ImageCache.recordedSource(of: file) == nil, "and the file is still not vouched for")
    }

    /// A cover in its slot with no recorded source.
    private func writeUnrecordedFile(in cache: ImageCache, releaseID: Int, contents: Data) async throws -> URL {
        let file = await cache.fileURL(releaseID: releaseID, kind: .cover)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file)
        return file
    }

    @Test("Concurrent requests for one image collapse into a single download")
    func coalescesConcurrentRequests() async throws {
        CountingProtocol.reset()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = makeCache(directory: directory)
        let remote = URL(string: "https://i.discogs.com/busy.jpeg")!

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask { _ = try? await cache.localURL(releaseID: 7, kind: .thumb, remoteURL: remote) }
            }
        }

        #expect(CountingProtocol.count(for: remote.absoluteString) == 1)
    }

    @Test("A failed download leaves nothing cached, so the next attempt retries")
    func failureDoesNotPoisonTheCache() async throws {
        CountingProtocol.reset()
        CountingProtocol.statusCode = 404
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = makeCache(directory: directory)
        let remote = URL(string: "https://i.discogs.com/missing.jpeg")!

        await #expect(throws: (any Error).self) {
            try await cache.localURL(releaseID: 9, kind: .thumb, remoteURL: remote)
        }
        #expect(await cache.isCached(releaseID: 9, kind: .thumb) == false)
    }

    @Test("A 200 carrying an HTML error page is not cached as an image")
    func rejectsHTMLServedWith200() async throws {
        CountingProtocol.serve(body: Data("<html><body>Not Found</body></html>".utf8))
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = makeCache(directory: directory)
        let remote = URL(string: "https://i.discogs.com/html-error.jpeg")!

        await #expect(throws: (any Error).self) {
            try await cache.localURL(releaseID: 11, kind: .thumb, remoteURL: remote)
        }
        #expect(await cache.isCached(releaseID: 11, kind: .thumb) == false,
                "an HTML body must never occupy a cover slot permanently")
    }

    @Test("A 200 with an empty body is not cached")
    func rejectsEmptyBody() async throws {
        CountingProtocol.serve(body: Data())
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = makeCache(directory: directory)
        let remote = URL(string: "https://i.discogs.com/empty.jpeg")!

        await #expect(throws: (any Error).self) {
            try await cache.localURL(releaseID: 12, kind: .thumb, remoteURL: remote)
        }
        #expect(await cache.isCached(releaseID: 12, kind: .thumb) == false)
    }

    @Test("A truncated image is rejected rather than cached half-written")
    func rejectsTruncatedImage() async throws {
        CountingProtocol.serve(body: CountingProtocol.pngBytes.prefix(20))
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = makeCache(directory: directory)
        let remote = URL(string: "https://i.discogs.com/truncated.jpeg")!

        await #expect(throws: (any Error).self) {
            try await cache.localURL(releaseID: 13, kind: .thumb, remoteURL: remote)
        }
        #expect(await cache.isCached(releaseID: 13, kind: .thumb) == false)
    }

    @Test("A cached file that will not decode is discarded, so the next attempt re-fetches")
    func discardsUndecodableCachedFile() async throws {
        CountingProtocol.reset()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = makeCache(directory: directory)
        let remote = URL(string: "https://i.discogs.com/corrupt.jpeg")!

        // Simulate a file that went bad on disk after it was cached, with its source recorded, so
        // the cache would otherwise serve it for as long as the URL stands.
        let destination = await cache.fileURL(releaseID: 14, kind: .thumb)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("garbage".utf8).write(to: destination)
        ImageCache.recordSource(remote, on: destination)
        #expect(await cache.isCached(releaseID: 14, kind: .thumb, source: remote))

        await #expect(throws: (any Error).self) {
            try await cache.image(releaseID: 14, kind: .thumb, remoteURL: remote, maximumPixelSize: 150)
        }
        #expect(await cache.isCached(releaseID: 14, kind: .thumb) == false,
                "the corrupt file must be removed, not kept forever")

        // With the bad file gone the next request downloads a real image.
        let image = try await cache.image(releaseID: 14, kind: .thumb, remoteURL: remote, maximumPixelSize: 150)
        #expect(image.size.width > 0)
    }

    @Test("A decoded image is kept in memory for its source and size, and nothing else")
    func keepsDecodedImagesInMemory() async throws {
        CountingProtocol.reset()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = makeCache(directory: directory)
        let remote = URL(string: "https://i.discogs.com/memory.jpeg")!
        #expect(cache.cachedImage(releaseID: 20, kind: .cover, remoteURL: remote, maximumPixelSize: 320) == nil)

        _ = try await cache.image(releaseID: 20, kind: .cover, remoteURL: remote, maximumPixelSize: 320)
        #expect(cache.cachedImage(releaseID: 20, kind: .cover, remoteURL: remote, maximumPixelSize: 320) != nil)

        // A replaced cover must go back through the disk cache, which fetches the new image.
        let replaced = URL(string: "https://i.discogs.com/memory-v2.jpeg")!
        #expect(cache.cachedImage(releaseID: 20, kind: .cover, remoteURL: replaced, maximumPixelSize: 320) == nil)
        // A small decode is too coarse for a larger cell.
        #expect(cache.cachedImage(releaseID: 20, kind: .cover, remoteURL: remote, maximumPixelSize: 560) == nil)
        #expect(cache.cachedImage(releaseID: 20, kind: .thumb, remoteURL: remote, maximumPixelSize: 320) == nil)
    }

    @Test("An older file served offline is not kept in memory as the new image")
    func offlineFallbackIsNotKeptInMemory() async throws {
        CountingProtocol.serve(body: Data("<html>unavailable</html>".utf8))
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = makeCache(directory: directory)
        _ = try await writeUnrecordedFile(in: cache, releaseID: 21, contents: CountingProtocol.pngBytes)
        let remote = URL(string: "https://i.discogs.com/21-new.jpeg")!

        // The old cover is still drawn while Discogs is unreachable...
        _ = try await cache.image(releaseID: 21, kind: .cover, remoteURL: remote, maximumPixelSize: 150)
        // ...but held in memory under the new URL it would outlive the download of the new one.
        #expect(cache.cachedImage(releaseID: 21, kind: .cover, remoteURL: remote, maximumPixelSize: 150) == nil)
    }

    @Test("Clearing the cache empties memory as well as disk")
    func removeAllClearsMemory() async throws {
        CountingProtocol.reset()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = makeCache(directory: directory)
        let remote = URL(string: "https://i.discogs.com/cleared.jpeg")!
        _ = try await cache.image(releaseID: 22, kind: .cover, remoteURL: remote, maximumPixelSize: 150)

        try await cache.removeAll()
        #expect(cache.cachedImage(releaseID: 22, kind: .cover, remoteURL: remote, maximumPixelSize: 150) == nil)
    }

    @Test("Over its byte limit, memory drops the least recently drawn image first")
    func evictsLeastRecentlyUsed() throws {
        let decoded = DecodedImageCache(byteLimit: 10, respondsToMemoryPressure: false)
        let image = try #require(Self.onePixelImage())
        func url(_ name: String) -> URL { URL(string: "https://i.discogs.com/\(name).jpeg")! }
        func insert(_ id: Int) {
            decoded.insert(image, byteCount: 4, releaseID: id, kind: .cover, source: url("\(id)"), maximumPixelSize: 150)
        }
        func isKept(_ id: Int) -> Bool {
            decoded.image(releaseID: id, kind: .cover, source: url("\(id)"), maximumPixelSize: 150) != nil
        }

        insert(1)
        insert(2)
        #expect(isKept(1), "drawing 1 again makes 2 the oldest")
        insert(3)

        #expect(isKept(1))
        #expect(isKept(2) == false)
        #expect(isKept(3))
    }

    @Test("An image larger than the whole memory budget is not kept")
    func skipsOversizedImages() throws {
        let decoded = DecodedImageCache(byteLimit: 10, respondsToMemoryPressure: false)
        let image = try #require(Self.onePixelImage())
        let source = URL(string: "https://i.discogs.com/huge.jpeg")!
        decoded.insert(image, byteCount: 11, releaseID: 1, kind: .cover, source: source, maximumPixelSize: 150)
        #expect(decoded.image(releaseID: 1, kind: .cover, source: source, maximumPixelSize: 150) == nil)
    }

    private static func onePixelImage() -> PlatformImage? {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context?.makeImage().map(ImageCache.platformImage)
    }

    @Test("Cached images decode, downsampled to the requested size")
    func downsamples() async throws {
        CountingProtocol.reset()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = makeCache(directory: directory)
        let remote = URL(string: "https://i.discogs.com/decodable.jpeg")!

        let image = try await cache.image(releaseID: 3, kind: .thumb, remoteURL: remote, maximumPixelSize: 150)
        #expect(image.size.width > 0)
    }
}
