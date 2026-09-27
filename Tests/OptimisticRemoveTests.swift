import DiscogsKit
import Foundation
import Testing
@testable import CatalogistaKit

@Suite("Optimistic remove")
@MainActor
struct OptimisticRemoveTests {
    private func makeStore() throws -> CollectionStore {
        CollectionStore(modelContainer: try AppServices.makeModelContainer(inMemory: true))
    }

    private func makeItem(instanceID: Int, releaseID: Int, folderID: Int = 1) throws -> CollectionItem {
        let json = """
        {
          "id": \(releaseID),
          "instance_id": \(instanceID),
          "folder_id": \(folderID),
          "rating": 0,
          "date_added": "2019-05-06T18:32:50-07:00",
          "basic_information": {
            "id": \(releaseID),
            "title": "Remain In Light",
            "year": 1980,
            "thumb": "https://i.discogs.com/thumb.jpeg",
            "artists": [{ "name": "Talking Heads", "join": "" }],
            "labels": [{ "name": "Sire", "catno": "SRK 6095" }],
            "formats": [{ "name": "Vinyl", "qty": "1", "descriptions": ["LP"] }],
            "genres": ["Rock"],
            "styles": ["New Wave"]
          }
        }
        """
        return try DiscogsClient.makeDecoder().decode(CollectionItem.self, from: Data(json.utf8))
    }

    @Test("Removing one copy leaves the other copy of the same release")
    func removesOnlyTheChosenInstance() async throws {
        let store = try makeStore()
        // Two copies of one release: exactly the case instance_id exists for.
        try await store.upsert([
            try makeItem(instanceID: 111, releaseID: 500),
            try makeItem(instanceID: 222, releaseID: 500),
        ])

        try await store.deleteItem(instanceID: 111)

        #expect(try await store.itemCount() == 1)
        #expect(try await store.item(instanceID: 111) == nil)
        #expect(try await store.item(instanceID: 222) != nil, "the other copy must survive")
    }

    @Test("A rolled-back removal restores the row exactly")
    func restoreAfterFailure() async throws {
        let store = try makeStore()
        try await store.upsert([try makeItem(instanceID: 111, releaseID: 500)])
        let before = try #require(try await store.item(instanceID: 111))

        try await store.deleteItem(instanceID: 111)
        #expect(try await store.itemCount() == 0)

        try await store.restore(before)

        let after = try #require(try await store.item(instanceID: 111))
        #expect(after == before, "rollback must restore every field, not just the ids")
        #expect(try await store.itemCount() == 1)
    }

    @Test("Restoring a copy that is already present does not duplicate it")
    func restoreIsIdempotent() async throws {
        let store = try makeStore()
        try await store.upsert([try makeItem(instanceID: 111, releaseID: 500)])
        let snapshot = try #require(try await store.item(instanceID: 111))

        try await store.restore(snapshot)

        #expect(try await store.itemCount() == 1)
    }

    @Test("The snapshot carries the folder the delete has to target")
    func snapshotKeepsFolder() async throws {
        let store = try makeStore()
        // Folder 0 is the read-only "All" pseudo-folder; a delete must use the real one.
        try await store.upsert([try makeItem(instanceID: 111, releaseID: 500, folderID: 1)])

        let snapshot = try #require(try await store.item(instanceID: 111))
        #expect(snapshot.folderID == 1)
        #expect(snapshot.releaseID == 500)
    }
}
