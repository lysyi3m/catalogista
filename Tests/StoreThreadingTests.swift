import Foundation
import Testing
@testable import CatalogistaKit

extension CollectionStore {
    func runsOnMainThread() -> Bool {
        Thread.isMainThread
    }
}

/// The store's context has no queue of its own, so its work runs on the calling thread: on the
/// main thread when a main-actor caller awaits it, off it otherwise. A sync is safe from the main
/// thread only because its store calls come from the `CollectionSyncer` actor.
@Suite("Store threading")
@MainActor
struct StoreThreadingTests {
    @Test("Store work a sync asks for runs off the main thread")
    func syncSideCallsRunOffMain() async throws {
        let store = CollectionStore(modelContainer: try AppServices.makeModelContainer(inMemory: true))
        // The shape of a syncer's call: from an actor that is not the main actor.
        let onMain = await Task.detached { await store.runsOnMainThread() }.value
        #expect(onMain == false)
    }
}
