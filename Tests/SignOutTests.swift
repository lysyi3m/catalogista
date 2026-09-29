import DiscogsKit
import Foundation
import Testing
@testable import CatalogistaKit

@Suite("Sign out", .serialized)
@MainActor
struct SignOutTests {
    /// Serves a two-page collection slowly, so a sign-out lands while the sync is mid-stream.
    final class SlowCollectionProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "api.discogs.com"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/oauth/identity") {
                body = #"{"id":1,"username":"tester","resource_url":"https://api.discogs.com"}"#
            } else if path.hasSuffix("/collection/folders") {
                body = #"{"folders":[{"id":1,"name":"Uncategorized","count":0}]}"#
            } else if path.hasPrefix("/releases/") {
                Thread.sleep(forTimeInterval: 0.3)
                body = """
                {"id":500,"title":"Remain In Light","year":1980,
                 "artists":[{"name":"Talking Heads","join":""}],
                 "labels":[],"formats":[],"genres":[],"styles":[]}
                """
            } else {
                let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "page" }?.value ?? "1"
                Thread.sleep(forTimeInterval: 0.3)
                body = """
                {"pagination":{"page":\(page),"pages":2,"per_page":1,"items":2},
                 "releases":[{"id":500,"instance_id":\(page),"folder_id":1,"rating":0,
                 "basic_information":{"id":500,"title":"Remain In Light","year":1980,
                 "cover_image":"https://i.discogs.com/\(page)-cover.jpeg",
                 "artists":[{"name":"Talking Heads","join":""}],
                 "labels":[],"formats":[],"genres":[],"styles":[]}}]}
                """
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// Covers come from a slow server, one at a time, so a cover warmer always has a backlog.
    private func makeServices() throws -> (services: AppServices, tokenStore: TokenStore) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowCollectionProtocol.self]
        let imageConfiguration = URLSessionConfiguration.ephemeral
        imageConfiguration.protocolClasses = [ImageCacheTests.SlowProtocol.self]
        let tokenStore = TokenStore(service: "com.mlkshkvch.catalogista.tests.\(UUID().uuidString)")
        try tokenStore.save("test-token")
        let services = AppServices(
            modelContainer: try AppServices.makeModelContainer(inMemory: true),
            tokenStore: tokenStore,
            imageCache: ImageCache(
                directory: URL.temporaryDirectory.appending(path: UUID().uuidString),
                session: URLSession(configuration: imageConfiguration),
                maximumConcurrentDownloads: 1
            ),
            sessionConfiguration: configuration
        )
        return (services, tokenStore)
    }

    @Test("Signing out does not wait for the cover backlog")
    func signOutDoesNotDrainCovers() async throws {
        ImageCacheTests.SlowProtocol.reset()
        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }

        // The sync ends with two covers queued behind a single slow slot: about 0.8 s to drain.
        #expect(await services.syncController.sync())

        let started = ContinuousClock.now
        try await services.signOut()
        #expect(ContinuousClock.now - started < .milliseconds(350), "sign-out must cancel the covers, not wait for them")
        #expect(await services.imageCache.statistics().fileCount == 0)
    }

    @Test("A record page that finishes loading after sign-out writes nothing")
    func detailAfterSignOutIsDropped() async throws {
        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }

        let loader = ReleaseDetailLoader(services: services)
        let load = Task { await loader.load(releaseID: 500) }
        // The release request is still out when the account disconnects.
        try await Task.sleep(for: .milliseconds(100))
        try await services.signOut()
        await load.value

        #expect(try await services.store.releaseDetail(releaseID: 500) == nil,
                "the old account's release must not reappear in the cleared cache")
    }

    @Test("Signing out forgets the old account's sync state")
    func signOutForgetsSyncState() async throws {
        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }

        #expect(await services.syncController.sync())
        #expect(services.syncController.lastSyncedAt != nil)

        try await services.signOut()
        // A new sign-in in the same session would otherwise show the old account's sync time and
        // judge the new collection fresh.
        #expect(services.syncController.lastSyncedAt == nil)
        #expect(services.syncController.lastSummary == nil)
    }

    @Test("Signing out mid-sync leaves nothing of the old account behind")
    func signOutDuringSyncLeavesNoRecords() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowCollectionProtocol.self]

        let tokenStore = TokenStore(service: "com.mlkshkvch.catalogista.tests.\(UUID().uuidString)")
        try tokenStore.save("test-token")
        defer { try? tokenStore.delete() }
        let services = AppServices(
            modelContainer: try AppServices.makeModelContainer(inMemory: true),
            tokenStore: tokenStore,
            imageCache: ImageCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString)),
            sessionConfiguration: configuration
        )

        let sync = Task { await services.syncController.sync() }
        // Long enough to be mid-stream, short enough that neither page has finished the fetch.
        try await Task.sleep(for: .milliseconds(150))
        try await services.signOut()

        // The sync is shielded from its caller's cancellation, so it outlives the request that
        // started it. Sign-out has to stop it, or it writes the old account back into the store.
        _ = await sync.result
        #expect(try await services.store.itemCount() == 0, "no record of the old account may survive")
        #expect(services.hasToken == false)
    }
}
