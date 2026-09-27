import DiscogsKit
import Foundation
import Testing
@testable import CatalogistaKit

@Suite("Release detail cache")
struct ReleaseDetailTests {
    private func makeStore() throws -> CollectionStore {
        CollectionStore(modelContainer: try AppServices.makeModelContainer(inMemory: true))
    }

    private func makeRelease(id: Int = 1373891, title: String = "Remain In Light") throws -> Release {
        let json = """
        {
          "id": \(id),
          "title": "\(title)",
          "year": 1980,
          "released": "1980-10-08",
          "country": "US",
          "uri": "https://www.discogs.com/release/\(id)",
          "artists": [{ "name": "Talking Heads", "join": "" }],
          "labels": [{ "name": "Sire", "catno": "SRK 6095" }],
          "formats": [{ "name": "Vinyl", "qty": "1", "descriptions": ["LP"] }],
          "genres": ["Rock"],
          "styles": ["New Wave"],
          "tracklist": [
            { "position": "", "type_": "heading", "title": "Side A", "duration": "" },
            { "position": "A1", "type_": "track", "title": "Born Under Punches", "duration": "5:46" }
          ],
          "images": [
            { "type": "secondary", "uri": "https://i.discogs.com/back.jpeg" },
            { "type": "primary", "uri": "https://i.discogs.com/front.jpeg" }
          ]
        }
        """
        return try DiscogsClient.makeDecoder().decode(Release.self, from: Data(json.utf8))
    }

    @Test("A stale page loads again on the next call instead of keeping its first copy")
    @MainActor
    func stalePageReloads() async throws {
        // No token, so a stale copy cannot be refreshed from Discogs and the cached one is shown.
        let services = AppServices(
            modelContainer: try AppServices.makeModelContainer(inMemory: true),
            tokenStore: TokenStore(service: "com.mlkshkvch.catalogista.tests.\(UUID().uuidString)"),
            imageCache: ImageCache(directory: URL.temporaryDirectory.appending(path: UUID().uuidString))
        )
        try await services.store.upsertReleaseDetail(makeRelease(title: "First"))
        let sevenHoursLater = Date.now.addingTimeInterval(7 * 3600)
        let loader = ReleaseDetailLoader(services: services, now: { sevenHoursLater })

        await loader.load(releaseID: 1373891)
        #expect(loader.snapshot?.title == "First", "offline, a stale copy is still shown")
        #expect(loader.staleSince != nil, "and the page discloses its own age")

        try await services.store.upsertReleaseDetail(makeRelease(title: "Second"))
        await loader.load(releaseID: 1373891)
        #expect(loader.snapshot?.title == "Second", "a loaded page must not stay on its first copy")
    }

    @Test("A release detail round-trips through the cache")
    func roundTrip() async throws {
        let store = try makeStore()
        #expect(try await store.releaseDetail(releaseID: 1373891) == nil)

        try await store.upsertReleaseDetail(makeRelease())

        let cached = try #require(try await store.releaseDetail(releaseID: 1373891))
        #expect(cached.title == "Remain In Light")
        #expect(cached.catalogNumber == "SRK 6095")
        #expect(cached.country == "US")
        #expect(cached.coverURL == "https://i.discogs.com/front.jpeg", "the primary image is kept")
        #expect(cached.discogsURL == "https://www.discogs.com/release/1373891")
    }

    @Test("Headings are stored but excluded from the playable tracks")
    func headingsAreNotTracks() async throws {
        let store = try makeStore()
        try await store.upsertReleaseDetail(makeRelease())

        let cached = try #require(try await store.releaseDetail(releaseID: 1373891))
        #expect(cached.tracks.count == 2, "the heading is kept so the list renders as Discogs shows it")
        #expect(cached.playableTracks.count == 1)
        #expect(cached.playableTracks.first?.position == "A1")
        #expect(cached.playableTracks.first?.duration == "5:46")
    }

    @Test("Re-fetching a release updates it in place")
    func upsertUpdates() async throws {
        let store = try makeStore()
        try await store.upsertReleaseDetail(makeRelease(title: "Old Title"))
        try await store.upsertReleaseDetail(makeRelease(title: "New Title"))

        let cached = try #require(try await store.releaseDetail(releaseID: 1373891))
        #expect(cached.title == "New Title")
    }

    @Test("Two copies of one release share a single detail record")
    func sharedAcrossInstances() async throws {
        let store = try makeStore()
        try await store.upsertReleaseDetail(makeRelease(id: 500))

        // Whichever copy is opened, the lookup is by release, not by instance.
        #expect(try await store.releaseDetail(releaseID: 500) != nil)
        #expect(try await store.releaseDetail(releaseID: 501) == nil)
    }
}
