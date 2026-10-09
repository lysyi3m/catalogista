import DiscogsKit
import Foundation
import SwiftData

/// A Discogs collection folder, refreshed with every sync. The app moves copies between folders;
/// folders themselves are created, renamed and deleted on discogs.com. `count` is Discogs' own;
/// the sidebar counts the cached copies instead (`CollectionFolders.counts`).
@Model
final class CachedFolder {
    @Attribute(.unique) var id: Int
    var name: String
    var count: Int

    init(from folder: Folder) {
        id = folder.id
        name = folder.name
        count = folder.count
    }

    func update(from folder: Folder) {
        name = folder.name
        count = folder.count
    }
}
