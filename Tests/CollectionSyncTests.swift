import DiscogsKit
import Foundation
import Testing
@testable import CatalogistaKit

@Suite("Collection sync", .serialized)
struct CollectionSyncTests {
    /// Answers the three calls a sync makes. The collection page's `releases` array and its
    /// `pagination.items` are set independently, so a response can claim more than it sends.
    final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var releaseInstanceIDs: [Int] = []
        nonisolated(unsafe) static var reportedItems = 0
        nonisolated(unsafe) static var reportedPages = 1
        private static let lock = NSLock()

        static func serve(instanceIDs: [Int], claimingItems: Int, pages: Int = 1) {
            lock.withLock {
                releaseInstanceIDs = instanceIDs
                reportedItems = claimingItems
                reportedPages = pages
            }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/oauth/identity") {
                body = #"{"id":1,"username":"tester","resource_url":"https://api.discogs.com"}"#
            } else if path.hasSuffix("/collection/folders") {
                body = #"{"folders":[{"id":1,"name":"Uncategorized","count":0}]}"#
            } else {
                let (ids, items, pages) = Self.lock.withLock {
                    (Self.releaseInstanceIDs, Self.reportedItems, Self.reportedPages)
                }
                let releases = ids.map { id in
                    """
                    {"id":500,"instance_id":\(id),"folder_id":1,"rating":0,
                     "basic_information":{"id":500,"title":"Remain In Light","year":1980,
                     "cover_image":"https://i.discogs.com/\(id)-cover.jpeg",
                     "artists":[{"name":"Talking Heads","join":""}],
                     "labels":[],"formats":[],"genres":[],"styles":[]}}
                    """
                }
                body = """
                {"pagination":{"page":1,"pages":\(pages),"per_page":100,"items":\(items)},
                 "releases":[\(releases.joined(separator: ","))]}
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

    private func makeSyncer(store: CollectionStore) -> CollectionSyncer {
        makeSyncerAndCache(store: store).syncer
    }

    private func makeSyncerAndCache(store: CollectionStore) -> (syncer: CollectionSyncer, cache: ImageCache) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let client = DiscogsClient(
            token: "test",
            configuration: DiscogsConfiguration(userAgent: "Catalogista/1.0 +tests"),
            session: URLSession(configuration: configuration)
        )
        let cache = ImageCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString))
        return (CollectionSyncer(client: client, store: store, imageCache: cache), cache)
    }

    @Test("Reconciling hands back the covers to fetch rather than waiting for them")
    func reconcileDoesNotWaitForArtwork() async throws {
        let store = try makeStore()
        let (syncer, cache) = makeSyncerAndCache(store: store)

        StubProtocol.serve(instanceIDs: [1, 2, 3], claimingItems: 3)
        let summary = try await syncer.reconcile()

        // A sync is finished when the collection is correct. Covers load on demand, so making the
        // user wait for every one of them only makes a finished sync look stuck.
        #expect(summary.artwork.count == 3)
        #expect(try await store.itemCount() == 3)
        for target in summary.artwork {
            #expect(await cache.isCached(releaseID: target.releaseID, kind: target.kind) == false,
                    "reconciliation must not download artwork")
        }
    }

    private func makeStore() throws -> CollectionStore {
        CollectionStore(modelContainer: try AppServices.makeModelContainer(inMemory: true))
    }

    @Test("A page that sends fewer records than it claims deletes nothing")
    func shortPageKeepsTheCache() async throws {
        let store = try makeStore()
        let syncer = makeSyncer(store: store)

        StubProtocol.serve(instanceIDs: [1, 2, 3], claimingItems: 3)
        _ = try await syncer.reconcile()
        #expect(try await store.itemCount() == 3)

        // The same collection, but Discogs answers with an empty page while still reporting three
        // records. Treating that as authoritative would wipe the only copy this device has.
        StubProtocol.serve(instanceIDs: [], claimingItems: 3)
        await #expect(throws: CollectionSyncer.SyncError.self) {
            _ = try await syncer.reconcile()
        }
        #expect(try await store.itemCount() == 3, "an inconsistent response must not prune")
    }

    @Test("A copy removed on discogs.com still disappears locally")
    func consistentShrinkStillPrunes() async throws {
        let store = try makeStore()
        let syncer = makeSyncer(store: store)

        StubProtocol.serve(instanceIDs: [1, 2, 3], claimingItems: 3)
        _ = try await syncer.reconcile()

        StubProtocol.serve(instanceIDs: [1, 2], claimingItems: 2)
        let summary = try await syncer.reconcile()
        #expect(summary.itemsRemoved == 1)
        #expect(try await store.itemCount() == 2)
    }

    @Test("A cancelled fetch is not mistaken for an empty collection")
    func cancelledSyncKeepsTheCache() async throws {
        let store = try makeStore()
        let syncer = makeSyncer(store: store)

        StubProtocol.serve(instanceIDs: [1, 2, 3], claimingItems: 3)
        _ = try await syncer.reconcile()

        // A stream that is cancelled finishes rather than throwing, so the fetch yields no pages
        // at all. That must not read as "Discogs reports nothing in this collection".
        let task = Task { try await syncer.reconcile() }
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(try await store.itemCount() == 3, "a cancelled sync must not prune")
    }

    @Test("An emptied collection is still an emptied collection")
    func genuinelyEmptyCollectionPrunes() async throws {
        let store = try makeStore()
        let syncer = makeSyncer(store: store)

        StubProtocol.serve(instanceIDs: [1, 2], claimingItems: 2)
        _ = try await syncer.reconcile()

        StubProtocol.serve(instanceIDs: [], claimingItems: 0)
        _ = try await syncer.reconcile()
        #expect(try await store.itemCount() == 0)
    }
}
