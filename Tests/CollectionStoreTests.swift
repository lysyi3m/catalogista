import DiscogsKit
import Foundation
import SwiftData
import Testing
@testable import CatalogistaKit

@Suite("CollectionStore")
struct CollectionStoreTests {
    private func makeStore() throws -> CollectionStore {
        CollectionStore(modelContainer: try AppServices.makeModelContainer(inMemory: true))
    }

    private func makeItem(
        instanceID: Int,
        releaseID: Int = 100,
        title: String = "Remain In Light",
        artist: String = "Talking Heads",
        year: Int? = 1980,
        dateAdded: String = "2019-05-06T18:32:50-07:00"
    ) throws -> CollectionItem {
        let yearJSON = year.map(String.init) ?? "0"
        let json = """
        {
          "id": \(releaseID),
          "instance_id": \(instanceID),
          "folder_id": 1,
          "rating": 0,
          "date_added": "\(dateAdded)",
          "basic_information": {
            "id": \(releaseID),
            "title": "\(title)",
            "year": \(yearJSON),
            "thumb": "https://i.discogs.com/\(releaseID)-thumb.jpeg",
            "cover_image": "https://i.discogs.com/\(releaseID)-cover.jpeg",
            "artists": [{ "name": "\(artist)", "join": "" }],
            "labels": [{ "name": "Sire", "catno": "SRK 6095" }],
            "formats": [{ "name": "Vinyl", "qty": "1", "descriptions": ["LP"] }],
            "genres": ["Rock"],
            "styles": ["New Wave"]
          }
        }
        """
        return try DiscogsClient.makeDecoder().decode(CollectionItem.self, from: Data(json.utf8))
    }

    private func makePending(instanceID: Int) throws -> PendingAddition {
        let json = """
        {"id": 600, "title": "Talking Heads - Fear of Music", "year": "1979", "format": ["Vinyl"]}
        """
        let result = try DiscogsClient.makeDecoder().decode(SearchResult.self, from: Data(json.utf8))
        return PendingAddition(from: result, instanceID: instanceID, folderID: 1)
    }

    @Test("A copy added while a sync runs survives that sync's prune")
    func addDuringSyncIsNotPruned() async throws {
        let store = try makeStore()
        try await store.upsert([try makeItem(instanceID: 1)])

        await store.beginSync()
        // Added after the sync fetched its pages, which therefore do not list it.
        try await store.insert(try makePending(instanceID: -5))
        try await store.reassignInstanceID(from: -5, to: 9)
        let removed = try await store.pruneItems(keeping: [1])
        await store.endSync()

        #expect(removed == 0)
        #expect(try await store.item(instanceID: 9) != nil, "the add must not vanish")
    }

    @Test("A copy removed while a sync runs is not put back by an earlier page")
    func removeDuringSyncIsNotReinserted() async throws {
        let store = try makeStore()
        try await store.upsert([try makeItem(instanceID: 1), try makeItem(instanceID: 2)])

        await store.beginSync()
        try await store.deleteItem(instanceID: 2)
        // A page fetched before the removal still lists the copy.
        try await store.upsert([try makeItem(instanceID: 1), try makeItem(instanceID: 2)])
        await store.endSync()

        #expect(try await store.item(instanceID: 2) == nil, "the removal must stick")
    }

    @Test("An add already in flight when a sync starts survives it, and a later sync settles it")
    func addInFlightBeforeSync() async throws {
        let store = try makeStore()
        try await store.upsert([try makeItem(instanceID: 1)])

        // Inserted before the sync starts; Discogs has not confirmed it yet.
        try await store.insert(try makePending(instanceID: -7))
        await store.beginSync()
        #expect(try await store.pruneItems(keeping: [1]) == 0, "the pending add must not be pruned")
        await store.endSync()
        try await store.reassignInstanceID(from: -7, to: 9)
        #expect(try await store.item(instanceID: 9) != nil, "the confirmed id must land on the row")

        // Settled, then a sync that began afterwards and does not list it: Discogs is canonical.
        await store.settleWrites([-7, 9])
        await store.beginSync()
        #expect(try await store.pruneItems(keeping: [1]) == 1)
        await store.endSync()
    }

    @Test("A removal already in flight when a sync starts is not put back by its pages")
    func removalInFlightBeforeSync() async throws {
        let store = try makeStore()
        try await store.upsert([try makeItem(instanceID: 1), try makeItem(instanceID: 2)])

        try await store.deleteItem(instanceID: 2)
        await store.beginSync()
        try await store.upsert([try makeItem(instanceID: 1), try makeItem(instanceID: 2)])
        await store.endSync()
        #expect(try await store.item(instanceID: 2) == nil, "the pending removal must stick")

        // Settled, then a later sync that still lists it: Discogs kept it, so it comes back.
        await store.settleWrites([2])
        await store.beginSync()
        try await store.upsert([try makeItem(instanceID: 1), try makeItem(instanceID: 2)])
        await store.endSync()
        #expect(try await store.item(instanceID: 2) != nil)
    }

    @Test("Outside a sync, writes leave no trace in later reconciliation")
    func writesOutsideSyncAreNotRecorded() async throws {
        let store = try makeStore()
        try await store.insert(try makePending(instanceID: -6))
        #expect(try await store.pruneItems(keeping: []) == 1)

        try await store.upsert([try makeItem(instanceID: 3)])
        try await store.deleteItem(instanceID: 3)
        try await store.upsert([try makeItem(instanceID: 3)])
        #expect(try await store.item(instanceID: 3) != nil)
    }

    @Test("Records with no year sort last in both directions")
    func yearlessRecordsSortLast() async throws {
        let store = try makeStore()
        try await store.upsert([
            try makeItem(instanceID: 1, title: "Dated", year: 1980),
            try makeItem(instanceID: 2, title: "Undated", year: nil),
            try makeItem(instanceID: 3, title: "Later", year: 2001),
        ])

        // A record with no year at the top of a year sort reads like the sort failed, so the
        // yearless record belongs at the end whichever way the years run.
        for direction in SortDirection.allCases {
            let titles = try await store.items(sortedBy: .year, direction: direction).map(\.title)
            #expect(titles.last == "Undated", "yearless record must sort last when \(direction.rawValue)")
        }

        let ascending = try await store.items(sortedBy: .year, direction: .ascending).map(\.title)
        #expect(ascending == ["Dated", "Later", "Undated"])
        let descending = try await store.items(sortedBy: .year, direction: .descending).map(\.title)
        #expect(descending == ["Later", "Dated", "Undated"])
    }

    @Test("Upsert inserts new copies and flattens basic_information")
    func upsertInserts() async throws {
        let store = try makeStore()
        try await store.upsert([makeItem(instanceID: 1), makeItem(instanceID: 2, releaseID: 200)])

        #expect(try await store.itemCount() == 2)
        let cached = try #require(try await store.item(instanceID: 1))
        #expect(cached.title == "Remain In Light")
        #expect(cached.artistName == "Talking Heads")
        #expect(cached.catalogNumber == "SRK 6095")
        #expect(cached.formatSummary == "Vinyl, LP")
        #expect(cached.thumbURL == "https://i.discogs.com/100-thumb.jpeg")
    }

    @Test("Upsert updates an existing copy in place rather than duplicating it")
    func upsertUpdates() async throws {
        let store = try makeStore()
        try await store.upsert([makeItem(instanceID: 1, title: "Old Title")])
        try await store.upsert([makeItem(instanceID: 1, title: "New Title")])

        #expect(try await store.itemCount() == 1, "the same instance must not be duplicated")
        let cached = try #require(try await store.item(instanceID: 1))
        #expect(cached.title == "New Title", "Discogs wins on conflict")
    }

    @Test("Two copies of one release are independent")
    func distinctInstancesOfSameRelease() async throws {
        let store = try makeStore()
        try await store.upsert([
            makeItem(instanceID: 1, releaseID: 500),
            makeItem(instanceID: 2, releaseID: 500),
        ])
        #expect(try await store.itemCount() == 2)
    }

    @Test("Pruning drops copies Discogs no longer reports")
    func prune() async throws {
        let store = try makeStore()
        try await store.upsert([
            makeItem(instanceID: 1),
            makeItem(instanceID: 2, releaseID: 200),
            makeItem(instanceID: 3, releaseID: 300),
        ])

        let removed = try await store.pruneItems(keeping: [1, 3])
        #expect(removed == 1)
        #expect(try await store.itemCount() == 2)
        #expect(try await store.item(instanceID: 2) == nil)
    }

    @Test("Default sort is date added, descending")
    func defaultSort() async throws {
        let store = try makeStore()
        try await store.upsert([
            makeItem(instanceID: 1, releaseID: 1, title: "Oldest", dateAdded: "2019-01-01T00:00:00-00:00"),
            makeItem(instanceID: 2, releaseID: 2, title: "Newest", dateAdded: "2024-01-01T00:00:00-00:00"),
            makeItem(instanceID: 3, releaseID: 3, title: "Middle", dateAdded: "2021-01-01T00:00:00-00:00"),
        ])

        let titles = try await store.items().map(\.title)
        #expect(titles == ["Newest", "Middle", "Oldest"])
    }

    @Test("Artist, title and year sort in both directions")
    func sortDimensions() async throws {
        let store = try makeStore()
        try await store.upsert([
            makeItem(instanceID: 1, releaseID: 1, title: "Bravo", artist: "The Zombies", year: 1968),
            makeItem(instanceID: 2, releaseID: 2, title: "Alpha", artist: "Aphex Twin", year: 1992),
            makeItem(instanceID: 3, releaseID: 3, title: "Charlie", artist: "Miles Davis", year: 1959),
        ])

        let artistsAscending = try await store.items(sortedBy: .artist, direction: .ascending).map(\.artistName)
        #expect(artistsAscending == ["Aphex Twin", "Miles Davis", "The Zombies"], "leading article is ignored")

        let artistsDescending = try await store.items(sortedBy: .artist, direction: .descending).map(\.artistName)
        #expect(artistsDescending == ["The Zombies", "Miles Davis", "Aphex Twin"])

        let titlesAscending = try await store.items(sortedBy: .title, direction: .ascending).map(\.title)
        #expect(titlesAscending == ["Alpha", "Bravo", "Charlie"])

        let yearsDescending = try await store.items(sortedBy: .year, direction: .descending).map(\.year)
        #expect(yearsDescending == [1992, 1968, 1959])
    }

    @Test("Folders are replaced wholesale, dropping ones that disappeared")
    func replaceFolders() async throws {
        let store = try makeStore()
        let decoder = DiscogsClient.makeDecoder()
        let first = try decoder.decode([Folder].self, from: Data("""
        [{ "id": 0, "name": "All", "count": 70 }, { "id": 1, "name": "Uncategorized", "count": 70 }]
        """.utf8))
        try await store.replaceFolders(first, keeping: [])
        #expect(try await store.folders().count == 2)

        let second = try decoder.decode([Folder].self, from: Data("""
        [{ "id": 0, "name": "All", "count": 71 }]
        """.utf8))
        try await store.replaceFolders(second, keeping: [])

        let folders = try await store.folders()
        #expect(folders.map(\.id) == [0])
        #expect(folders.first?.count == 71)
    }
}
