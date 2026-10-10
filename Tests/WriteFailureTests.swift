import DiscogsKit
import Foundation
import Testing
@testable import CatalogistaKit

@Suite("Write failures", .serialized)
@MainActor
struct WriteFailureTests {
    /// Stands in for Discogs in the session `makeServices` gives the client. Fails the write once,
    /// then lets it through, so a retry has something different to find.
    final class FlakyProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var writeAttempts = 0
        /// How many writes fail before one is allowed through. A DELETE that meets a 5xx is
        /// retried by the client, so a persistent failure needs every attempt to fail.
        nonisolated(unsafe) static var writesToFail = 1
        /// What a failing write answers with. 403 is a definite rejection; 503 is not.
        nonisolated(unsafe) static var failureStatus = 403
        private static let lock = NSLock()

        /// When true, the collection endpoint fails, so a reconciliation sync cannot run.
        nonisolated(unsafe) static var failReads = false

        /// The path of the latest write, to check which folder it targeted.
        nonisolated(unsafe) static var lastWritePath: String?

        static func reset(failureStatus: Int = 403, writesToFail: Int = 1) {
            lock.withLock {
                writeAttempts = 0
                self.failureStatus = failureStatus
                self.writesToFail = writesToFail
                collectionInstanceIDs = []
                failReads = false
                lastWritePath = nil
            }
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "api.discogs.com"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        /// The copies the collection holds when a reconciliation sync asks. Set per test to model
        /// "the write landed" or "the write did not".
        nonisolated(unsafe) static var collectionInstanceIDs: [Int] = []

        override func startLoading() {
            let isWrite = request.httpMethod == "DELETE" || request.httpMethod == "POST"
            let status: Int
            let body: String
            if request.url?.path.hasSuffix("/oauth/identity") == true {
                status = 200
                body = #"{"id":1,"username":"tester","resource_url":"https://api.discogs.com"}"#
            } else if isWrite {
                let path = request.url?.path
                let shouldFail = Self.lock.withLock { () -> Bool in
                    Self.writeAttempts += 1
                    Self.lastWritePath = path
                    return Self.writeAttempts <= Self.writesToFail
                }
                status = shouldFail ? Self.lock.withLock({ Self.failureStatus }) : 204
                body = shouldFail ? #"{"message":"Nope."}"# : ""
            } else if request.url?.path.hasSuffix("/collection/folders") == true {
                status = 200
                body = #"{"folders":[{"id":1,"name":"Uncategorized","count":0}]}"#
            } else if request.url?.path.hasSuffix("/collection/fields") == true {
                status = 200
                body = #"{"fields":[]}"#
            } else if Self.lock.withLock({ Self.failReads }) {
                status = 500
                body = #"{"message":"Nope."}"#
            } else if request.url?.path.contains("/collection/folders/") == true {
                let ids = Self.lock.withLock { Self.collectionInstanceIDs }
                let releases = ids.map { id in
                    """
                    {"id":500,"instance_id":\(id),"folder_id":1,"rating":0,
                     "basic_information":{"id":500,"title":"Remain In Light","year":1980,
                     "artists":[{"name":"Talking Heads","join":""}],
                     "labels":[],"formats":[],"genres":[],"styles":[]}}
                    """
                }
                status = 200
                body = """
                {"pagination":{"page":1,"pages":1,"per_page":100,"items":\(ids.count)},
                 "releases":[\(releases.joined(separator: ","))]}
                """
            } else {
                status = 200
                body = "{}"
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

    private func makeServices() throws -> (services: AppServices, tokenStore: TokenStore) {
        let tokenStore = TokenStore(service: "com.mlkshkvch.catalogista.tests.\(UUID().uuidString)")
        try tokenStore.save("test-token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlakyProtocol.self]
        let services = AppServices(
            modelContainer: try AppServices.makeModelContainer(inMemory: true),
            tokenStore: tokenStore,
            imageCache: ImageCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString)),
            sessionConfiguration: configuration
        )
        return (services, tokenStore)
    }

    private func makeItem(instanceID: Int) throws -> CollectionItem {
        let json = """
        {
          "id": 500, "instance_id": \(instanceID), "folder_id": 1, "rating": 0,
          "date_added": "2019-05-06T18:32:50-07:00",
          "basic_information": {
            "id": 500, "title": "Remain In Light", "year": 1980,
            "artists": [{ "name": "Talking Heads", "join": "" }],
            "labels": [], "formats": [], "genres": [], "styles": []
          }
        }
        """
        return try DiscogsClient.makeDecoder().decode(CollectionItem.self, from: Data(json.utf8))
    }

    private func makeSearchResult(releaseID: Int = 500) throws -> SearchResult {
        let json = """
        {
          "id": \(releaseID), "title": "Talking Heads - Remain In Light", "year": "1980",
          "thumb": "https://i.discogs.com/thumb.jpeg",
          "cover_image": "https://i.discogs.com/cover.jpeg",
          "format": ["Vinyl"], "label": ["Sire"], "catno": "SRK 6095", "country": "US"
        }
        """
        return try DiscogsClient.makeDecoder().decode(SearchResult.self, from: Data(json.utf8))
    }

    @Test("An unconfirmed add that did land is recognised, even when a copy was already owned")
    func unconfirmedAddThatLandedIsRecognised() async throws {
        FlakyProtocol.reset(failureStatus: 503, writesToFail: .max)
        // Owned one copy before; Discogs ends up holding two, so the write did land.
        FlakyProtocol.collectionInstanceIDs = [111, 222]

        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }
        try await services.store.upsert([try makeItem(instanceID: 111)])

        let editor = services.makeEditor()
        #expect(await editor.add(try makeSearchResult()) == true)
        #expect(editor.failure == nil)
        #expect(try await services.store.itemCount() == 2)
    }

    @Test("An unconfirmed add that did not land is reported, not mistaken for a copy already owned")
    func unconfirmedAddThatDidNotLandIsReported() async throws {
        FlakyProtocol.reset(failureStatus: 503, writesToFail: .max)
        // Owned one copy before, and Discogs still holds exactly that one: the write was rejected.
        FlakyProtocol.collectionInstanceIDs = [111]

        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }
        try await services.store.upsert([try makeItem(instanceID: 111)])

        let editor = services.makeEditor()
        // Finding the release present proves nothing here — it was present before the add.
        #expect(await editor.add(try makeSearchResult()) == false)
        let failure = try #require(editor.failure)
        #expect(failure.retry != nil, "verified absent, so a retry is safe")
        #expect(try await services.store.itemCount() == 1)
    }

    @Test("Retrying an unconfirmed add targets the folder the user picked")
    func unconfirmedAddRetryKeepsFolder() async throws {
        FlakyProtocol.reset(failureStatus: 503, writesToFail: .max)
        FlakyProtocol.collectionInstanceIDs = []

        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }

        let editor = services.makeEditor()
        #expect(await editor.add(try makeSearchResult(), folderID: 5) == false)
        let retry = try #require(editor.failure?.retry)

        FlakyProtocol.lastWritePath = nil
        await retry()
        #expect(FlakyProtocol.lastWritePath?.contains("/collection/folders/5/releases/500") == true)
    }

    @Test("A reset whose download fails says so, and keeps the old cache")
    func failedRebuildIsReported() async throws {
        FlakyProtocol.reset()
        FlakyProtocol.failReads = true

        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }
        try await services.store.upsert([try makeItem(instanceID: 111)])

        // The identity check passes; the collection itself does not come down.
        do {
            try await services.syncController.resetAndResync()
            Issue.record("expected the rebuild to fail")
        } catch let error as SyncController.ResetError {
            guard case .failed = error else {
                Issue.record("expected failed, got \(error)")
                return
            }
        }
        #expect(services.syncController.errorMessage != nil, "the collection screen must show it too")
        #expect(try await services.store.itemCount() == 1, "nothing is cleared before the download completes")
    }

    @Test("A reset that completes drops release details, and keeps the collection")
    func completedRebuildDropsDetails() async throws {
        FlakyProtocol.reset()
        FlakyProtocol.collectionInstanceIDs = [111]

        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }
        try await services.store.upsert([try makeItem(instanceID: 111)])
        let release = try DiscogsClient.makeDecoder().decode(Release.self, from: Data("""
            {"id":500,"title":"Remain In Light","artists":[],"labels":[],"formats":[],
             "genres":[],"styles":[],"tracklist":[],"images":[]}
            """.utf8))
        try await services.store.upsertReleaseDetail(release)

        try await services.syncController.resetAndResync()

        #expect(try await services.store.releaseDetail(releaseID: 500) == nil)
        #expect(try await services.store.itemCount() == 1)
    }

    @Test("A removal Discogs has already applied is not undone")
    func removeOfMissingCopyIsSuccess() async throws {
        FlakyProtocol.reset(failureStatus: 404)

        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }
        try await services.store.upsert([try makeItem(instanceID: 111)])

        // A 404, and the sync confirms Discogs no longer lists the copy: what the user asked for.
        // Restoring the row would resurrect a record that is already gone upstream.
        let editor = services.makeEditor()
        #expect(await editor.remove(instanceID: 111) == true)
        #expect(try await services.store.itemCount() == 0)
        #expect(editor.failure == nil)
    }

    @Test("An unconfirmed removal Discogs did not apply is restored, with a retry")
    func unconfirmedRemoveStillUpstream() async throws {
        FlakyProtocol.reset(failureStatus: 503, writesToFail: .max)
        // Discogs still holds the copy, so the delete did not land after all.
        FlakyProtocol.collectionInstanceIDs = [111]

        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }
        try await services.store.upsert([try makeItem(instanceID: 111)])

        let editor = services.makeEditor()
        #expect(await editor.remove(instanceID: 111) == false)
        let failure = try #require(editor.failure)
        #expect(failure.retry != nil, "verified still present, so a retry is safe")
        #expect(try await services.store.itemCount() == 1, "the sync brings the copy back")
    }

    @Test("A removal that cannot be verified offers no retry")
    func unconfirmedRemoveWithNoWayToVerify() async throws {
        FlakyProtocol.reset(failureStatus: 503, writesToFail: .max)
        // The reconciliation sync cannot run either, so the outcome stays genuinely unknown.
        FlakyProtocol.failReads = true

        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }
        try await services.store.upsert([try makeItem(instanceID: 111)])

        let editor = services.makeEditor()
        #expect(await editor.remove(instanceID: 111) == false)
        let failure = try #require(editor.failure)
        #expect(failure.retry == nil, "retrying an unverifiable write can mislead")
        #expect(failure.message.contains("may have been removed"))
    }

    @Test("A move files the copy in its new folder and names its old one to Discogs")
    func moveSucceeds() async throws {
        FlakyProtocol.reset(writesToFail: 0)

        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }
        try await services.store.upsert([try makeItem(instanceID: 111)])

        let editor = services.makeEditor()
        #expect(await editor.move(instanceID: 111, toFolderID: 5) == true)
        #expect(try await services.store.item(instanceID: 111)?.folderID == 5)
        #expect(FlakyProtocol.lastWritePath?.hasSuffix("/collection/folders/1/releases/500/instances/111") == true)
    }

    @Test("A rejected move goes back to its folder and offers a retry that moves it")
    func rejectedMoveRetries() async throws {
        FlakyProtocol.reset()

        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }
        try await services.store.upsert([try makeItem(instanceID: 111)])

        let editor = services.makeEditor()
        #expect(await editor.move(instanceID: 111, toFolderID: 5) == false)
        #expect(try await services.store.item(instanceID: 111)?.folderID == 1, "a rejected move rolls back")
        let retry = try #require(editor.failure?.retry)

        await retry()
        #expect(try await services.store.item(instanceID: 111)?.folderID == 5, "the retry must move the copy")
    }

    @Test("A move whose outcome is unknown takes the folder Discogs reports")
    func unconfirmedMoveFollowsDiscogs() async throws {
        FlakyProtocol.reset(failureStatus: 503, writesToFail: .max)
        FlakyProtocol.collectionInstanceIDs = [111]

        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }
        try await services.store.upsert([try makeItem(instanceID: 111)])

        // Discogs still lists the copy in folder 1, so the move did not land.
        let editor = services.makeEditor()
        #expect(await editor.move(instanceID: 111, toFolderID: 5) == false)
        #expect(try await services.store.item(instanceID: 111)?.folderID == 1)
        #expect(editor.failure?.retry != nil, "a move is safe to repeat")
    }

    @Test("A move that cannot be confirmed goes back to its folder, and its retry asks Discogs again")
    func unconfirmedMoveRetrySendsRequest() async throws {
        // The move answers 503 and the confirming sync fails too: the outcome stays unknown.
        FlakyProtocol.reset(failureStatus: 503, writesToFail: .max)
        FlakyProtocol.failReads = true

        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }
        try await services.store.upsert([try makeItem(instanceID: 111)])

        let editor = services.makeEditor()
        #expect(await editor.move(instanceID: 111, toFolderID: 5) == false)
        #expect(try await services.store.item(instanceID: 111)?.folderID == 1, "back to the last confirmed folder")
        let retry = try #require(editor.failure?.retry)

        FlakyProtocol.reset(writesToFail: 0)
        await retry()
        #expect(FlakyProtocol.lastWritePath != nil, "the retry must reach Discogs, not trust the cache")
        #expect(try await services.store.item(instanceID: 111)?.folderID == 5)
    }

    @Test("A change to a copy another editor is still changing is refused, with a retry")
    func overlappingChangeIsRefused() async throws {
        FlakyProtocol.reset(writesToFail: 0)

        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }
        try await services.store.upsert([try makeItem(instanceID: 111)])

        // Another editor's move of this copy is still under way.
        #expect(services.claimCopy(111))
        let editor = services.makeEditor()
        #expect(await editor.remove(instanceID: 111) == false)
        #expect(try await services.store.itemCount() == 1, "the cache is left alone")
        #expect(FlakyProtocol.writeAttempts == 0, "nothing is sent while the copy is busy")
        let retry = try #require(editor.failure?.retry)

        services.releaseCopy(111)
        await retry()
        #expect(try await services.store.itemCount() == 0)
    }

    @Test("A removal answered 404 for a copy Discogs still has is not reported as done")
    func removalNotFoundButStillListed() async throws {
        // The request named a folder the copy is no longer in, as after an unconfirmed move.
        FlakyProtocol.reset(failureStatus: 404, writesToFail: .max)
        FlakyProtocol.collectionInstanceIDs = [111]

        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }
        try await services.store.upsert([try makeItem(instanceID: 111)])

        let editor = services.makeEditor()
        #expect(await editor.remove(instanceID: 111) == false)
        #expect(try await services.store.itemCount() == 1, "the sync puts back the copy Discogs still has")
        #expect(editor.failure?.message.contains("still in your collection") == true)
        #expect(editor.failure?.retry != nil)
    }

    @Test("Moves of two copies through one editor both land")
    func overlappingMovesOfDifferentCopies() async throws {
        FlakyProtocol.reset(writesToFail: 0)

        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }
        try await services.store.upsert([try makeItem(instanceID: 111), try makeItem(instanceID: 222)])

        // Two drops on the sidebar in quick succession, through the grid's one editor.
        let editor = services.makeEditor()
        async let first = editor.move(instanceID: 111, toFolderID: 5)
        async let second = editor.move(instanceID: 222, toFolderID: 6)
        #expect(await [first, second] == [true, true])
        #expect(try await services.store.item(instanceID: 111)?.folderID == 5)
        #expect(try await services.store.item(instanceID: 222)?.folderID == 6)
        #expect(editor.isWorking == false)
    }

    @Test("A rejected removal offers a retry that actually removes the copy")
    func failedRemoveRetries() async throws {
        FlakyProtocol.reset()

        let (services, tokenStore) = try makeServices()
        defer { try? tokenStore.delete() }
        try await services.store.upsert([try makeItem(instanceID: 111)])

        let editor = services.makeEditor()
        #expect(await editor.remove(instanceID: 111) == false)

        // The copy is back, and the failure carries the way to try again.
        #expect(try await services.store.itemCount() == 1, "a rejected delete rolls back")
        let failure = try #require(editor.failure)
        #expect(failure.message.isEmpty == false)
        let retry = try #require(failure.retry, "a definite rejection is safe to retry")

        await retry()

        #expect(FlakyProtocol.writeAttempts == 2, "the retry must reach Discogs again")
        #expect(try await services.store.itemCount() == 0, "the retry must remove the copy")
        #expect(editor.failure == nil, "a successful retry clears the failure")
    }
}
