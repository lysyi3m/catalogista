import DiscogsKit
import Foundation
import SwiftData
import Testing
@testable import CatalogistaKit

@Suite("Folders")
@MainActor
struct FolderTests {
    private func folder(_ id: Int, _ name: String) -> FolderSnapshot {
        FolderSnapshot(id: id, name: name, count: 0)
    }

    private func item(instanceID: Int, folderID: Int, title: String, artist: String = "Talking Heads") -> CachedCollectionItem {
        CachedCollectionItem(from: CollectionItemSnapshot(
            instanceID: instanceID,
            releaseID: 100 + instanceID,
            folderID: folderID,
            dateAdded: nil,
            rating: 0,
            title: title,
            artistName: artist,
            year: nil,
            thumbURL: nil,
            coverURL: nil,
            formatSummary: "Vinyl",
            labelName: nil,
            catalogNumber: nil,
            genres: [],
            styles: []
        ))
    }

    @Test("The sidebar drops All, pins Uncategorized, and sorts the rest the way Finder does")
    func ordering() {
        let ordered = CollectionFolders.ordered([
            folder(0, "All"),
            folder(7, "Shelf 10"),
            folder(1, "Uncategorized"),
            folder(5, "shelf 2"),
            folder(9, "Ambient"),
        ])
        #expect(ordered.map(\.id) == [1, 9, 5, 7])
    }

    @Test("Folders with the same name keep a stable order")
    func duplicateNames() {
        let ordered = CollectionFolders.ordered([folder(8, "Jazz"), folder(3, "Jazz")])
        #expect(ordered.map(\.id) == [3, 8])
    }

    @Test("A remembered folder resolves to itself while it exists, and to Collection once it is gone")
    func resolution() {
        let folders = [folder(0, "All"), folder(1, "Uncategorized"), folder(5, "Jazz")]
        #expect(CollectionFolders.resolved(5, among: folders) == 5)
        #expect(CollectionFolders.resolved(6, among: folders) == DiscogsFolder.all)
        #expect(CollectionFolders.resolved(DiscogsFolder.all, among: folders) == DiscogsFolder.all)
        // Before a first sync has cached any folder.
        #expect(CollectionFolders.resolved(5, among: []) == DiscogsFolder.all)
    }

    @Test("Counts come from the cached copies")
    func counts() {
        #expect(CollectionFolders.counts(of: [1, 5, 5, 1, 5]) == [1: 2, 5: 3])
    }

    @Test("An add preselects the folder on screen, and Uncategorized from Collection")
    func addTarget() {
        let targets = CollectionFolders.addTargets([folder(0, "All"), folder(1, "Uncategorized"), folder(5, "Jazz")])
        #expect(targets.map(\.id) == [1, 5])
        #expect(CollectionFolders.addTarget(for: 5, among: targets) == 5)
        #expect(CollectionFolders.addTarget(for: DiscogsFolder.all, among: targets) == DiscogsFolder.uncategorized)
    }

    @Test("Uncategorized is an add target even before a first sync")
    func addTargetsWithoutSync() {
        #expect(CollectionFolders.addTargets([]).map(\.id) == [DiscogsFolder.uncategorized])
    }

    @Test("Search narrows the folder on screen, and Collection searches every folder")
    func scopedSearch() throws {
        let context = ModelContext(try AppServices.makeModelContainer(inMemory: true))
        context.insert(item(instanceID: 1, folderID: 1, title: "Remain In Light"))
        context.insert(item(instanceID: 2, folderID: 5, title: "Fear of Music"))
        context.insert(item(instanceID: 3, folderID: 5, title: "Blue Train", artist: "John Coltrane"))
        try context.save()

        func titles(inFolder folderID: Int, matching query: String) throws -> Set<String> {
            let descriptor = FetchDescriptor(
                predicate: CachedCollectionItem.predicate(inFolder: folderID, matching: query)
            )
            return Set(try context.fetch(descriptor).map(\.title))
        }

        #expect(try titles(inFolder: DiscogsFolder.all, matching: "").count == 3)
        #expect(try titles(inFolder: 5, matching: "") == ["Fear of Music", "Blue Train"])
        #expect(try titles(inFolder: 5, matching: "talking") == ["Fear of Music"])
        #expect(try titles(inFolder: DiscogsFolder.all, matching: "talking") == ["Remain In Light", "Fear of Music"])
        #expect(try titles(inFolder: 1, matching: "coltrane").isEmpty)
    }

    @Test("The add confirmation's credit links to the release on discogs.com")
    func releaseCreditURL() {
        #expect(DiscogsNotice.releaseURL(id: 116491).absoluteString == "https://www.discogs.com/release/116491")
    }

    @Test("A folder's credit links to that folder on discogs.com")
    func creditURL() {
        #expect(
            DiscogsNotice.collectionURL(username: "digger", folderID: 5).absoluteString
                == "https://www.discogs.com/user/digger/collection?folder_id=5"
        )
        #expect(
            DiscogsNotice.collectionURL(username: "digger").absoluteString
                == "https://www.discogs.com/user/digger/collection"
        )
    }
}
