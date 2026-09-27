import DiscogsKit
import Foundation
import Testing
@testable import CatalogistaKit

@Suite("Cache reset")
@MainActor
struct CacheResetTests {
    /// Services with no usable token, so a reset cannot reach Discogs.
    private func makeServices() throws -> AppServices {
        AppServices(
            modelContainer: try AppServices.makeModelContainer(inMemory: true),
            tokenStore: TokenStore(service: "com.mlkshkvch.catalogista.tests.\(UUID().uuidString)"),
            imageCache: ImageCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString))
        )
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

    @Test("A reset that cannot reach Discogs deletes nothing")
    func failedResetKeepsTheCache() async throws {
        let services = try makeServices()
        try await services.store.upsert([try makeItem(instanceID: 1), try makeItem(instanceID: 2)])
        #expect(try await services.store.itemCount() == 2)

        await #expect(throws: SyncController.ResetError.self) {
            try await services.syncController.resetAndResync()
        }

        // The cache is this device's only copy of the collection. A reset that cannot rebuild it
        // must leave it alone.
        #expect(try await services.store.itemCount() == 2, "the cache must survive a failed reset")
    }

    @Test("A reset without a token fails with a message that names the cause")
    func failureMessageIsReassuring() async throws {
        let services = try makeServices()
        do {
            try await services.syncController.resetAndResync()
            Issue.record("expected the reset to fail without a token")
        } catch let error as SyncController.ResetError {
            #expect(error.localizedDescription.contains("No Discogs token"))
        }
    }

    @Test("A failed reset leaves the controller idle, not stuck mid-sync")
    func failedResetDoesNotLeaveSyncingStuck() async throws {
        let services = try makeServices()
        try? await services.syncController.resetAndResync()
        #expect(services.syncController.isSyncing == false)
        #expect(services.syncController.activity == nil)
    }
}
