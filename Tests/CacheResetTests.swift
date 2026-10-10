import DiscogsKit
import Foundation
import Testing
@testable import CatalogistaKit

/// A reset that reaches Discogs and fails is covered with the other failures, in
/// `WriteFailureTests.failedRebuildIsReported`.
@Suite("Cache reset")
@MainActor
struct CacheResetTests {
    @Test("A reset without a token fails with a message that names the cause, and deletes nothing")
    func failureMessageIsReassuring() async throws {
        let services = AppServices(
            modelContainer: try AppServices.makeModelContainer(inMemory: true),
            tokenStore: TokenStore(service: "com.mlkshkvch.catalogista.tests.\(UUID().uuidString)"),
            imageCache: ImageCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString))
        )
        let json = """
        {"id":500,"instance_id":1,"folder_id":1,"rating":0,
         "basic_information":{"id":500,"title":"Remain In Light","year":1980,
         "artists":[{"name":"Talking Heads","join":""}],"labels":[],"formats":[],"genres":[],"styles":[]}}
        """
        try await services.store.upsert([try DiscogsClient.makeDecoder().decode(CollectionItem.self, from: Data(json.utf8))])

        do {
            try await services.syncController.resetAndResync()
            Issue.record("expected the reset to fail without a token")
        } catch let error as SyncController.ResetError {
            #expect(error.localizedDescription.contains("Connect to Discogs"))
        }
        #expect(try await services.store.itemCount() == 1)
    }
}
