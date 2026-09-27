import DiscogsKit
import Foundation
import Testing
@testable import CatalogistaKit

@Suite("Optimistic add")
@MainActor
struct OptimisticAddTests {
    private func makeStore() throws -> CollectionStore {
        CollectionStore(modelContainer: try AppServices.makeModelContainer(inMemory: true))
    }

    private func makeSearchResult(
        id: Int = 116491,
        title: String = "Talking Heads - Remain In Light"
    ) throws -> SearchResult {
        let json = """
        {
          "id": \(id),
          "type": "release",
          "title": "\(title)",
          "year": "1980",
          "country": "US",
          "thumb": "https://i.discogs.com/thumb.jpeg",
          "cover_image": "https://i.discogs.com/cover.jpeg",
          "format": ["Vinyl", "LP", "Album"],
          "label": ["Sire"],
          "catno": "SRK 6095",
          "genre": ["Rock"],
          "style": ["New Wave"]
        }
        """
        return try DiscogsClient.makeDecoder().decode(SearchResult.self, from: Data(json.utf8))
    }

    private func makeRelease(id: Int = 116491) throws -> Release {
        let json = """
        {
          "id": \(id),
          "title": "Remain In Light",
          "year": 1980,
          "artists": [{ "name": "Talking Heads", "join": "" }],
          "labels": [{ "name": "Sire", "catno": "SRK 6095" }],
          "formats": [{ "name": "Vinyl", "qty": "1", "descriptions": ["LP", "Album"] }],
          "genres": ["Rock"],
          "styles": ["New Wave"],
          "images": [{ "type": "primary", "uri": "https://i.discogs.com/front.jpeg" }]
        }
        """
        return try DiscogsClient.makeDecoder().decode(Release.self, from: Data(json.utf8))
    }

    @Test("A pending addition splits the combined search title")
    func pendingFromSearchResult() throws {
        let pending = PendingAddition(from: try makeSearchResult(), instanceID: -1, folderID: 1)

        #expect(pending.title == "Remain In Light")
        #expect(pending.artistName == "Talking Heads")
        #expect(pending.releaseID == 116491)
        #expect(pending.folderID == 1)
        #expect(pending.year == 1980)
        #expect(pending.catalogNumber == "SRK 6095")
        #expect(pending.formatSummary == "Vinyl, LP, Album")
    }

    @Test("Provisional ids are negative and never repeat, even in a tight burst")
    func provisionalIDsAreNegativeAndUnique() {
        // A unique attribute means a repeat would overwrite a row rather than add one.
        let ids = (0..<1000).map { _ in PendingAddition.provisionalInstanceID() }
        #expect(ids.allSatisfy { $0 < 0 })
        #expect(Set(ids).count == ids.count)
    }

    @Test("An optimistic insert shows up in the grid immediately")
    func optimisticInsert() async throws {
        let store = try makeStore()
        let provisionalID = PendingAddition.provisionalInstanceID()
        try await store.insert(PendingAddition(from: try makeSearchResult(), instanceID: provisionalID, folderID: 1))

        #expect(try await store.itemCount() == 1)
        let item = try #require(try await store.item(instanceID: provisionalID))
        #expect(item.title == "Remain In Light")
    }

    @Test("The confirmed instance id replaces the provisional one")
    func reassignInstanceID() async throws {
        let store = try makeStore()
        let provisionalID = PendingAddition.provisionalInstanceID()
        try await store.insert(PendingAddition(from: try makeSearchResult(), instanceID: provisionalID, folderID: 1))

        try await store.reassignInstanceID(from: provisionalID, to: 447829291)

        #expect(try await store.itemCount() == 1, "reassigning must not duplicate the row")
        #expect(try await store.item(instanceID: provisionalID) == nil)
        #expect(try await store.item(instanceID: 447829291) != nil)
    }

    @Test("The release fetch corrects search-derived text")
    func releaseRefinesTheRow() async throws {
        let store = try makeStore()
        // A title Discogs' search could not split, so the artist landed empty.
        let result = try makeSearchResult(title: "Remain In Light")
        try await store.insert(PendingAddition(from: result, instanceID: -5, folderID: 1))
        #expect(try await store.item(instanceID: -5)?.artistName == "")

        try await store.apply(try makeRelease(), toInstanceID: -5)

        let item = try #require(try await store.item(instanceID: -5))
        #expect(item.artistName == "Talking Heads")
        // The search result already carried `cover_image`, and that is what the grid and the
        // record page both draw. The release's full-size original would give an added record a
        // different URL than the same record arriving from a sync. They share one cache slot, so
        // each would read the other as a changed image and download it again.
        #expect(item.coverURL == "https://i.discogs.com/cover.jpeg")
    }

    @Test("A result with no cover falls back to the release's own image")
    func releaseImageFillsAMissingCover() async throws {
        let store = try makeStore()
        var pending = PendingAddition(from: try makeSearchResult(), instanceID: -6, folderID: 1)
        pending.coverURL = nil
        try await store.insert(pending)

        try await store.apply(try makeRelease(), toInstanceID: -6)

        #expect(try await store.item(instanceID: -6)?.coverURL == "https://i.discogs.com/front.jpeg")
    }

    @Test("Rolling back a failed add leaves no trace")
    func rollback() async throws {
        let store = try makeStore()
        let provisionalID = PendingAddition.provisionalInstanceID()
        try await store.insert(PendingAddition(from: try makeSearchResult(), instanceID: provisionalID, folderID: 1))

        try await store.deleteItem(instanceID: provisionalID)

        #expect(try await store.itemCount() == 0)
    }
}
