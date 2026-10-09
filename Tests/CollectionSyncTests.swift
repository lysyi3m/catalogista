import DiscogsKit
import Foundation
import Testing
@testable import CatalogistaKit

@Suite("Collection sync", .serialized)
struct CollectionSyncTests {
    /// Answers every call a sync makes. The collection page's `releases` array and its
    /// `pagination.items` are set independently, so a response can claim more than it sends.
    final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var releaseInstanceIDs: [Int] = []
        nonisolated(unsafe) static var reportedItems = 0
        nonisolated(unsafe) static var reportedPages = 1
        /// The folders Discogs reports, and the one every copy is filed in.
        nonisolated(unsafe) static var folders: [(id: Int, name: String)] = [(1, "Uncategorized")]
        nonisolated(unsafe) static var copiesFolderID = 1
        /// What the folder list says once the pages are in, when it changed on discogs.com
        /// between the two requests.
        nonisolated(unsafe) static var foldersAfterPages: [(id: Int, name: String)]?
        nonisolated(unsafe) static var pagesServed = false
        /// The custom fields Discogs reports; nil answers that request with a 404, which is not
        /// retried.
        nonisolated(unsafe) static var fieldsJSON: String?
        /// Each copy's `notes`, the values of those fields.
        nonisolated(unsafe) static var fieldValuesJSON = "[]"
        private static let lock = NSLock()

        static func serve(
            instanceIDs: [Int],
            claimingItems: Int,
            pages: Int = 1,
            folders: [(id: Int, name: String)] = [(1, "Uncategorized")],
            copiesIn folderID: Int = 1,
            foldersAfterPages: [(id: Int, name: String)]? = nil,
            fields: String? = "[]",
            fieldValues: String = "[]"
        ) {
            lock.withLock {
                fieldsJSON = fields
                fieldValuesJSON = fieldValues
                releaseInstanceIDs = instanceIDs
                reportedItems = claimingItems
                reportedPages = pages
                self.folders = folders
                copiesFolderID = folderID
                self.foldersAfterPages = foldersAfterPages
                pagesServed = false
            }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            let body: String
            var status = 200
            if path.hasSuffix("/collection/fields") {
                if let fields = Self.lock.withLock({ Self.fieldsJSON }) {
                    body = #"{"fields":\#(fields)}"#
                } else {
                    status = 404
                    body = #"{"message":"Not found"}"#
                }
            } else if path.hasSuffix("/oauth/identity") {
                body = #"{"id":1,"username":"tester","resource_url":"https://api.discogs.com"}"#
            } else if path.hasSuffix("/collection/folders") {
                let folders = Self.lock.withLock {
                    Self.pagesServed ? Self.foldersAfterPages ?? Self.folders : Self.folders
                }
                    .map { #"{"id":\#($0.id),"name":"\#($0.name)","count":0}"# }
                body = #"{"folders":[\#(folders.joined(separator: ","))]}"#
            } else {
                let (ids, items, pages, folderID, notes) = Self.lock.withLock {
                    Self.pagesServed = true
                    return (Self.releaseInstanceIDs, Self.reportedItems, Self.reportedPages, Self.copiesFolderID, Self.fieldValuesJSON)
                }
                let releases = ids.map { id in
                    """
                    {"id":500,"instance_id":\(id),"folder_id":\(folderID),"rating":0,"notes":\(notes),
                     "basic_information":{"id":500,"title":"Remain In Light","year":1980,
                     "cover_image":"https://i.discogs.com/\(id)-cover.jpeg",
                     "artists":[{"name":"Talking Heads","join":""}],
                     "labels":[],"formats":[],"genres":[],"styles":[]}}
                    """
                }
                // Echoes the page asked for: a fixed page number never reaches the last page, and
                // the fetch would ask for the next one forever.
                let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "page" }?.value ?? "1"
                body = """
                {"pagination":{"page":\(page),"pages":\(pages),"per_page":100,"items":\(items)},
                 "releases":[\(releases.joined(separator: ","))]}
                """
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
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

    @Test("A sync stores each copy's custom field values and the fields' names in order")
    func syncStoresCustomFields() async throws {
        StubProtocol.serve(
            instanceIDs: [1],
            claimingItems: 1,
            fields: """
            [{"name":"Notes","id":3,"position":3,"type":"textarea","public":true},
             {"name":"Media","id":1,"position":1,"type":"dropdown","public":true}]
            """,
            fieldValues: #"[{"field_id":1,"value":"Very Good Plus (VG+)"}]"#
        )
        let store = try makeStore()
        try await makeSyncer(store: store).reconcile()

        #expect(try await store.fields().map(\.name) == ["Media", "Notes"])
        #expect(try await store.item(instanceID: 1)?.fieldValues == [FieldValue(fieldID: 1, value: "Very Good Plus (VG+)")])
    }

    @Test("A sync whose fields request fails still succeeds and keeps the names it had")
    func failedFieldsKeepPreviousNames() async throws {
        let store = try makeStore()
        try await store.replaceFields([CustomField(id: 1, name: "Media", type: "dropdown", position: 1)])

        StubProtocol.serve(instanceIDs: [1], claimingItems: 1, fields: nil)
        try await makeSyncer(store: store).reconcile()

        #expect(try await store.itemCount() == 1)
        #expect(try await store.fields().map(\.name) == ["Media"])
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

    @Test("A folder removed on discogs.com stays cached while the collection fetch is incomplete")
    func incompleteFetchKeepsRemovedFolder() async throws {
        let store = try makeStore()
        let syncer = makeSyncer(store: store)

        StubProtocol.serve(
            instanceIDs: [1, 2],
            claimingItems: 2,
            folders: [(1, "Uncategorized"), (7, "Jazz")],
            copiesIn: 7
        )
        _ = try await syncer.reconcile()

        // Jazz is gone from the folder list and a new folder appears, but the page is short. The
        // copies still say Jazz, so dropping it now would leave them in no folder the sidebar
        // lists; the new folder is added at once, since copies may already be filed in it.
        StubProtocol.serve(
            instanceIDs: [],
            claimingItems: 2,
            folders: [(1, "Uncategorized"), (8, "Soul")],
            copiesIn: 7
        )
        await #expect(throws: CollectionSyncer.SyncError.self) {
            _ = try await syncer.reconcile()
        }
        #expect(try await store.folders().map(\.id).sorted() == [1, 7, 8])

        // A complete fetch settles it.
        StubProtocol.serve(
            instanceIDs: [1, 2],
            claimingItems: 2,
            folders: [(1, "Uncategorized"), (8, "Soul")],
            copiesIn: 8
        )
        _ = try await syncer.reconcile()
        #expect(try await store.folders().map(\.id).sorted() == [1, 8])
    }

    @Test("A folder created while the pages come in is not missing once the sync completes")
    func folderCreatedMidSyncIsCached() async throws {
        let store = try makeStore()
        let syncer = makeSyncer(store: store)

        // The folder list is fetched before the pages and does not have Soul yet; the pages
        // already file the copies in it.
        StubProtocol.serve(
            instanceIDs: [1, 2],
            claimingItems: 2,
            folders: [(1, "Uncategorized")],
            copiesIn: 8,
            foldersAfterPages: [(1, "Uncategorized"), (8, "Soul")]
        )
        _ = try await syncer.reconcile()
        #expect(try await store.folders().map(\.id).sorted() == [1, 8])
    }

    @Test("A folder deleted while the pages come in stays while copies still name it")
    func folderDeletedMidSyncStaysWhileNamed() async throws {
        let store = try makeStore()
        let syncer = makeSyncer(store: store)

        // The pages still file the copies in Jazz, but by the second folder fetch it is gone.
        StubProtocol.serve(
            instanceIDs: [1, 2],
            claimingItems: 2,
            folders: [(1, "Uncategorized"), (7, "Jazz")],
            copiesIn: 7,
            foldersAfterPages: [(1, "Uncategorized")]
        )
        _ = try await syncer.reconcile()
        #expect(try await store.folders().map(\.id).sorted() == [1, 7])

        // Once the copies have moved, the next sync drops it.
        StubProtocol.serve(instanceIDs: [1, 2], claimingItems: 2, folders: [(1, "Uncategorized")], copiesIn: 1)
        _ = try await syncer.reconcile()
        #expect(try await store.folders().map(\.id).sorted() == [1])
    }

    @Test("Pages that repeat one copy and skip another do not pass as complete")
    func repeatedCopiesAreIncomplete() async throws {
        let store = try makeStore()
        let syncer = makeSyncer(store: store)

        StubProtocol.serve(instanceIDs: [1, 2, 3, 4], claimingItems: 4)
        _ = try await syncer.reconcile()

        // Two pages of [1, 2]: four rows for four reported copies, but 3 and 4 were never seen.
        // Counting rows would call this complete and prune them.
        StubProtocol.serve(instanceIDs: [1, 2], claimingItems: 4, pages: 2)
        await #expect(throws: CollectionSyncer.SyncError.self) {
            _ = try await syncer.reconcile()
        }
        #expect(try await store.itemCount() == 4, "copies that were never seen must not be pruned")
    }

    @Test("A complete sync drops art and details of releases no longer in the collection")
    func completeSyncPrunesUnusedFiles() async throws {
        let store = try makeStore()
        let (syncer, cache) = makeSyncerAndCache(store: store)

        StubProtocol.serve(instanceIDs: [1], claimingItems: 1)
        _ = try await syncer.reconcile()
        // Release 500 is in the collection; 900 was only looked at in search.
        for releaseID in [500, 900] {
            let file = await cache.fileURL(releaseID: releaseID, kind: .cover)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("art".utf8).write(to: file)
        }

        _ = try await syncer.reconcile()
        #expect(await cache.isCached(releaseID: 500, kind: .cover))
        #expect(await cache.isCached(releaseID: 900, kind: .cover) == false)
    }

    @Test("An incomplete sync deletes no art")
    func incompleteSyncKeepsFiles() async throws {
        let store = try makeStore()
        let (syncer, cache) = makeSyncerAndCache(store: store)
        StubProtocol.serve(instanceIDs: [1], claimingItems: 1)
        _ = try await syncer.reconcile()
        let file = await cache.fileURL(releaseID: 900, kind: .cover)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("art".utf8).write(to: file)

        StubProtocol.serve(instanceIDs: [], claimingItems: 1)
        await #expect(throws: CollectionSyncer.SyncError.self) { _ = try await syncer.reconcile() }
        #expect(await cache.isCached(releaseID: 900, kind: .cover))
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
