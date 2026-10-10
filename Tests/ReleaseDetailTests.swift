import DiscogsKit
import Foundation
import SwiftData
import Testing
@testable import CatalogistaKit

@Suite("Release detail cache")
struct ReleaseDetailTests {
    private let testDefaults = TestDefaults()

    private func makeStore() throws -> CollectionStore {
        CollectionStore(modelContainer: try AppServices.makeModelContainer(inMemory: true))
    }

    private func makeRelease(id: Int = 1373891, title: String = "Remain In Light") throws -> Release {
        let json = """
        {
          "id": \(id),
          "title": "\(title)",
          "year": 1980,
          "released": "1980-10-08",
          "country": "US",
          "uri": "https://www.discogs.com/release/\(id)",
          "artists": [{ "name": "Talking Heads", "join": "" }],
          "labels": [{ "name": "Sire", "catno": "SRK 6095" }],
          "formats": [{ "name": "Vinyl", "qty": "1", "descriptions": ["LP"] }],
          "genres": ["Rock"],
          "styles": ["New Wave"],
          "tracklist": [
            { "position": "", "type_": "heading", "title": "Side A", "duration": "" },
            { "position": "A1", "type_": "track", "title": "Born Under Punches", "duration": "5:46" }
          ],
          "images": [
            { "type": "secondary", "uri": "https://i.discogs.com/back.jpeg" },
            { "type": "primary", "uri": "https://i.discogs.com/front.jpeg" }
          ]
        }
        """
        return try DiscogsClient.makeDecoder().decode(Release.self, from: Data(json.utf8))
    }

    @Test("A stale page loads again on the next call instead of keeping its first copy")
    @MainActor
    func stalePageReloads() async throws {
        // No token, so a stale copy cannot be refreshed from Discogs and the cached one is shown.
        let services = AppServices(
            modelContainer: try AppServices.makeModelContainer(inMemory: true),
            tokenStore: TokenStore(service: "com.mlkshkvch.catalogista.tests.\(UUID().uuidString)"),
            imageCache: ImageCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString))
        )
        try await services.store.upsertReleaseDetail(makeRelease(title: "First"))
        let sevenHoursLater = Date.now.addingTimeInterval(7 * 3600)
        let loader = ReleaseDetailLoader(services: services, now: { sevenHoursLater })

        await loader.load(releaseID: 1373891)
        #expect(loader.snapshot?.title == "First", "offline, a stale copy is still shown")
        #expect(loader.staleSince != nil, "and the page discloses its own age")

        try await services.store.upsertReleaseDetail(makeRelease(title: "Second"))
        await loader.load(releaseID: 1373891)
        #expect(loader.snapshot?.title == "Second", "a loaded page must not stay on its first copy")
    }

    @Test("A record opened before shows its cached details from the start, with no request")
    @MainActor
    func cachedCopyShowsAtOnce() async throws {
        let container = try AppServices.makeModelContainer(inMemory: true)
        // No token: a load that tried to fetch would fail rather than keep the cached copy.
        let services = AppServices(
            modelContainer: container,
            tokenStore: TokenStore(service: "com.mlkshkvch.catalogista.tests.\(UUID().uuidString)"),
            imageCache: ImageCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString))
        )
        try await services.store.upsertReleaseDetail(makeRelease(title: "Cached"))

        // The record page reads on the main context, which sees what the store saved.
        let cached = try #require(ReleaseDetailLoader.cachedDetail(releaseID: 1373891, in: container.mainContext))
        let loader = ReleaseDetailLoader(services: services, cached: cached)
        #expect(loader.snapshot?.title == "Cached", "shown before any load runs")

        await loader.load(releaseID: 1373891)
        #expect(loader.state == .loaded(cached), "a fresh copy is kept without asking Discogs")
        #expect(ReleaseDetailLoader.cachedDetail(releaseID: 42, in: container.mainContext) == nil)
    }

    @Test("A fresh copy stored before the app kept images is fetched again")
    @MainActor
    func copyWithoutImagesIsFetchedAgain() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SignOutTests.SlowCollectionProtocol.self]
        let tokenStore = TokenStore(service: "com.mlkshkvch.catalogista.tests.\(UUID().uuidString)")
        try tokenStore.save("test-token")
        defer { try? tokenStore.delete() }
        let container = try AppServices.makeModelContainer(inMemory: true)
        let services = AppServices(
            modelContainer: container,
            tokenStore: tokenStore,
            imageCache: ImageCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString)),
            sessionConfiguration: configuration
        )
        try await services.store.upsertReleaseDetail(makeRelease(id: 500, title: "Cached"))
        let stored = try #require(try container.mainContext.fetch(FetchDescriptor<CachedReleaseDetail>()).first)
        stored.imageURLs = nil
        try container.mainContext.save()
        let loader = ReleaseDetailLoader(services: services, cached: stored.snapshot)

        await loader.load(releaseID: 500)
        #expect(loader.snapshot?.title == "Remain In Light", "the copy is replaced by a fetch")
        #expect(loader.snapshot?.imageURLs == [])
    }

    @Test("A stale copy is on screen while its refresh is still out")
    @MainActor
    func staleCopyShowsDuringRefresh() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SignOutTests.SlowCollectionProtocol.self]
        let tokenStore = TokenStore(service: "com.mlkshkvch.catalogista.tests.\(UUID().uuidString)")
        try tokenStore.save("test-token")
        defer {
            try? tokenStore.delete()
            testDefaults.discard()
        }
        let services = AppServices(
            modelContainer: try AppServices.makeModelContainer(inMemory: true),
            tokenStore: tokenStore,
            imageCache: ImageCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString)),
            sessionConfiguration: configuration,
            defaults: testDefaults.defaults
        )
        try await services.store.upsertReleaseDetail(makeRelease(id: 500, title: "Cached"))
        let sevenHoursLater = Date.now.addingTimeInterval(7 * 3600)
        let loader = ReleaseDetailLoader(services: services, now: { sevenHoursLater })

        // The stub answers the release request after 0.3 s.
        let load = Task { await loader.load(releaseID: 500) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(loader.snapshot?.title == "Cached", "the cached copy must not wait for the refresh")
        await load.value
    }

    @Test("A release detail round-trips through the cache")
    func roundTrip() async throws {
        let store = try makeStore()
        #expect(try await store.releaseDetail(releaseID: 1373891) == nil)

        try await store.upsertReleaseDetail(makeRelease())

        let cached = try #require(try await store.releaseDetail(releaseID: 1373891))
        #expect(cached.title == "Remain In Light")
        #expect(cached.catalogNumber == "SRK 6095")
        #expect(cached.country == "US")
        #expect(cached.coverURL == "https://i.discogs.com/front.jpeg", "the primary image is kept")
        #expect(
            cached.imageURLs == ["https://i.discogs.com/front.jpeg", "https://i.discogs.com/back.jpeg"],
            "every image is kept, the cover first"
        )
        #expect(cached.discogsURL == "https://www.discogs.com/release/1373891")
    }

    @Test("Headings are stored but excluded from the playable tracks")
    func headingsAreNotTracks() async throws {
        let store = try makeStore()
        try await store.upsertReleaseDetail(makeRelease())

        let cached = try #require(try await store.releaseDetail(releaseID: 1373891))
        #expect(cached.tracks.count == 2, "the heading is kept so the list renders as Discogs shows it")
        #expect(cached.playableTracks.count == 1)
        #expect(cached.playableTracks.first?.position == "A1")
        #expect(cached.playableTracks.first?.duration == "5:46")
    }

    @Test("Re-fetching a release updates it in place")
    func upsertUpdates() async throws {
        let store = try makeStore()
        try await store.upsertReleaseDetail(makeRelease(title: "Old Title"))
        try await store.upsertReleaseDetail(makeRelease(title: "New Title"))

        let cached = try #require(try await store.releaseDetail(releaseID: 1373891))
        #expect(cached.title == "New Title")
    }

    /// Answers release requests and counts them.
    final class CountingReleaseProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var releaseRequests = 0
        static var requests: Int { lock.withLock { releaseRequests } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.withLock { Self.releaseRequests += 1 }
            let body = """
            {"id":600,"title":"Fear of Music","year":1979,"uri":"https://www.discogs.com/release/600",
             "artists":[{"name":"Talking Heads","join":""}],"labels":[],"formats":[],"genres":[],"styles":[]}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @Test("Two copies of one release share one detail record and one request")
    @MainActor
    func sharedAcrossInstances() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingReleaseProtocol.self]
        let tokenStore = TokenStore(service: "com.mlkshkvch.catalogista.tests.\(UUID().uuidString)")
        try tokenStore.save("test-token")
        defer {
            try? tokenStore.delete()
            testDefaults.discard()
        }
        let container = try AppServices.makeModelContainer(inMemory: true)
        let services = AppServices(
            modelContainer: container,
            tokenStore: tokenStore,
            imageCache: ImageCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString)),
            sessionConfiguration: configuration,
            defaults: testDefaults.defaults
        )
        let copies = try [1, 2].map { instanceID in
            let json = """
            {"id":600,"instance_id":\(instanceID),"folder_id":1,"rating":0,
             "basic_information":{"id":600,"title":"Fear of Music","year":1979,
             "artists":[{"name":"Talking Heads","join":""}],"labels":[],"formats":[],"genres":[],"styles":[]}}
            """
            return try DiscogsClient.makeDecoder().decode(CollectionItem.self, from: Data(json.utf8))
        }
        try await services.store.upsert(copies)
        let before = CountingReleaseProtocol.requests

        // Each copy's page has a loader of its own, and both look the release up by its id.
        for _ in copies {
            let loader = ReleaseDetailLoader(services: services)
            await loader.load(releaseID: 600)
            #expect(loader.snapshot?.title == "Fear of Music")
        }

        #expect(CountingReleaseProtocol.requests - before == 1, "the second copy reuses the first one's details")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<CachedReleaseDetail>()) == 1)
    }
}
