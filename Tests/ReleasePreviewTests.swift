import DiscogsKit
import Foundation
import SwiftData
import Testing
@testable import CatalogistaKit

/// The add confirmation's release page: fetched, shown, and stored only when the release is added.
@Suite("Release preview", .serialized)
@MainActor
struct ReleasePreviewTests {
    private let testDefaults = TestDefaults()

    /// Stands in for Discogs: the identity, the release, and the add. Counts release requests.
    final class PreviewProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var releaseRequestCount = 0
        /// When true, the add answers 503: Discogs may have applied it, and a sync must settle it.
        nonisolated(unsafe) private static var addIsUnconfirmed = false
        static var releaseRequests: Int { lock.withLock { releaseRequestCount } }
        static func reset(addIsUnconfirmed: Bool = false) {
            lock.withLock {
                releaseRequestCount = 0
                self.addIsUnconfirmed = addIsUnconfirmed
            }
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "api.discogs.com"
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            let status: Int
            let body: String
            if path.hasSuffix("/oauth/identity") {
                status = 200
                body = #"{"id":1,"username":"tester","resource_url":"https://api.discogs.com"}"#
            } else if request.httpMethod == "POST" {
                let unconfirmed = Self.lock.withLock { Self.addIsUnconfirmed }
                status = unconfirmed ? 503 : 201
                body = unconfirmed ? #"{"message":"Try later."}"# : #"{"instance_id":9001,"resource_url":"https://api.discogs.com"}"#
            } else if path.hasSuffix("/collection/folders") {
                status = 200
                body = #"{"folders":[{"id":1,"name":"Uncategorized","count":1}]}"#
            } else if path.hasSuffix("/collection/fields") {
                status = 200
                body = #"{"fields":[]}"#
            } else if path.contains("/collection/folders/") {
                // The add landed: the collection holds the new copy.
                status = 200
                body = """
                {"pagination":{"page":1,"pages":1,"per_page":100,"items":1},
                 "releases":[{"id":600,"instance_id":9001,"folder_id":1,"rating":0,
                  "basic_information":{"id":600,"title":"Fear of Music","year":1979,
                  "artists":[{"name":"Talking Heads","join":""}],"labels":[],"formats":[],"genres":[],"styles":[]}}]}
                """
            } else if path == "/releases/600" {
                Self.lock.withLock { Self.releaseRequestCount += 1 }
                status = 200
                body = """
                {"id":600,"title":"Fear of Music","year":1979,"released":"1979-08-03","country":"US",
                 "uri":"https://www.discogs.com/release/600",
                 "artists":[{"name":"Talking Heads","join":""}],"labels":[{"name":"Sire","catno":"SRK 6076"}],
                 "formats":[],"genres":["Rock"],"styles":[],
                 "tracklist":[{"position":"A1","type_":"track","title":"I Zimbra","duration":"3:09"}]}
                """
            } else {
                status = 404
                body = #"{"message":"Not found."}"#
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeServices() throws -> (services: AppServices, container: ModelContainer, tokenStore: TokenStore) {
        let tokenStore = TokenStore(service: "com.mlkshkvch.catalogista.tests.\(UUID().uuidString)")
        try tokenStore.save("test-token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreviewProtocol.self]
        let container = try AppServices.makeModelContainer(inMemory: true)
        let services = AppServices(
            modelContainer: container,
            tokenStore: tokenStore,
            imageCache: ImageCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString)),
            sessionConfiguration: configuration,
            clientConfiguration: DiscogsConfiguration(userAgent: DiscogsUserAgent.value, maxRetries: 0),
            defaults: testDefaults.defaults
        )
        return (services, container, tokenStore)
    }

    private func makeSearchResult() throws -> SearchResult {
        let json = """
        {"id":600,"title":"Talking Heads - Fear of Music","year":"1979",
         "thumb":"https://i.discogs.com/thumb.jpeg","cover_image":"https://i.discogs.com/cover.jpeg",
         "format":["Vinyl"],"label":["Sire"],"catno":"SRK 6076","country":"US"}
        """
        return try DiscogsClient.makeDecoder().decode(SearchResult.self, from: Data(json.utf8))
    }

    @Test("A previewed release is shown in full and nothing of it is stored")
    func previewStoresNothing() async throws {
        PreviewProtocol.reset()
        let (services, container, tokenStore) = try makeServices()
        defer {
            try? tokenStore.delete()
            testDefaults.discard()
        }

        let preview = ReleaseDetailLoader(services: services, persists: false)
        await preview.load(releaseID: 600)

        #expect(preview.snapshot?.releasedDisplay != nil, "the full release date comes from the fetch")
        #expect(preview.snapshot?.tracks.count == 1)
        #expect(preview.fetched?.release.id == 600)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<CachedReleaseDetail>()) == 0)

        await preview.load(releaseID: 600)
        #expect(PreviewProtocol.releaseRequests == 1, "a second look at the same preview does not fetch again")
    }

    @Test("Adding a previewed release stores what the preview fetched, with no second request")
    func addStoresPreview() async throws {
        PreviewProtocol.reset()
        let (services, container, tokenStore) = try makeServices()
        defer {
            try? tokenStore.delete()
            testDefaults.discard()
        }
        let preview = ReleaseDetailLoader(services: services, persists: false)
        await preview.load(releaseID: 600)
        let fetched = try #require(preview.fetched)

        let editor = services.makeEditor()
        #expect(await editor.add(try makeSearchResult(), fetched: fetched))

        // Read the way the record page reads it, before its first frame.
        let stored = try #require(ReleaseDetailLoader.cachedDetail(releaseID: 600, in: container.mainContext))
        #expect(stored.tracks.count == 1)
        #expect(stored.fetchedAt == fetched.at, "its age counts from the fetch, not from the add")
        #expect(try await services.store.item(instanceID: 9001)?.title == "Fear of Music")
        #expect(PreviewProtocol.releaseRequests == 1)
    }

    @Test("Closing the sheet deletes the images of listed releases outside the collection")
    func closingDiscardsPreviewImages() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageCacheTests.CountingProtocol.self]
        let imageCache = ImageCache(directory: directory, session: URLSession(configuration: configuration))
        let services = AppServices(
            modelContainer: try AppServices.makeModelContainer(inMemory: true),
            tokenStore: TokenStore(service: "com.mlkshkvch.catalogista.tests.\(UUID().uuidString)"),
            imageCache: imageCache,
            defaults: testDefaults.defaults
        )
        defer { testDefaults.discard() }
        let owned = try DiscogsClient.makeDecoder().decode(CollectionItem.self, from: Data("""
        {"id":8,"instance_id":80,"folder_id":1,"rating":0,
         "basic_information":{"id":8,"title":"Owned","year":1980,
         "artists":[{"name":"Talking Heads","join":""}],"labels":[],"formats":[],"genres":[],"styles":[]}}
        """.utf8))
        try await services.store.upsert([owned])
        for releaseID in [7, 8] {
            try await imageCache.localURL(releaseID: releaseID, kind: .thumb, remoteURL: URL(string: "https://i.discogs.com/t\(releaseID).jpeg")!)
        }

        let session = AddRecordSession()
        session.noteListed([7, 8])
        session.close(services: services)

        for _ in 0..<50 where await imageCache.isCached(releaseID: 7, kind: .thumb) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await imageCache.isCached(releaseID: 7, kind: .thumb) == false, "a release only looked at goes")
        #expect(await imageCache.isCached(releaseID: 8, kind: .thumb), "a release in the collection keeps its images")
    }

    @Test("A preview older than the freshness limit is fetched again after the add")
    func stalePreviewIsNotStored() async throws {
        PreviewProtocol.reset()
        let (services, container, tokenStore) = try makeServices()
        defer {
            try? tokenStore.delete()
            testDefaults.discard()
        }
        let preview = ReleaseDetailLoader(services: services, persists: false)
        await preview.load(releaseID: 600)
        let fetched = try #require(preview.fetched)
        let stale = (release: fetched.release, at: fetched.at.addingTimeInterval(-Freshness.maximumAge - 60))

        let editor = services.makeEditor()
        #expect(await editor.add(try makeSearchResult(), fetched: stale))

        let stored = try await storedDetail(releaseID: 600, in: container)
        #expect(PreviewProtocol.releaseRequests == 2)
        #expect(Freshness.isFresh(stored.fetchedAt), "a stale preview is never stored as fresh")
    }

    @Test("An unconfirmed add that landed still stores the release, fetched again when the preview is stale")
    func unconfirmedAddStoresRelease() async throws {
        PreviewProtocol.reset()
        let (services, container, tokenStore) = try makeServices()
        defer {
            try? tokenStore.delete()
            testDefaults.discard()
        }
        let preview = ReleaseDetailLoader(services: services, persists: false)
        await preview.load(releaseID: 600)
        let fetched = try #require(preview.fetched)
        let stale = (release: fetched.release, at: fetched.at.addingTimeInterval(-Freshness.maximumAge - 60))
        PreviewProtocol.reset(addIsUnconfirmed: true)

        let editor = services.makeEditor()
        #expect(await editor.add(try makeSearchResult(), fetched: stale), "the sync finds the copy the add left")

        let stored = try await storedDetail(releaseID: 600, in: container)
        #expect(PreviewProtocol.releaseRequests == 1, "the stale preview is replaced by one fetch")
        #expect(Freshness.isFresh(stored.fetchedAt))
    }

    /// The release details once the background fetch after an add has stored them.
    private func storedDetail(releaseID: Int, in container: ModelContainer) async throws -> ReleaseDetailSnapshot {
        for _ in 0..<50 where ReleaseDetailLoader.cachedDetail(releaseID: releaseID, in: container.mainContext) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(ReleaseDetailLoader.cachedDetail(releaseID: releaseID, in: container.mainContext))
    }
}
