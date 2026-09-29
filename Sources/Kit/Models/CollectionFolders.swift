import DiscogsKit
import Foundation

/// The folders the sidebar and the add confirmation list, and which one a stored choice resolves to.
///
/// Folder 0 is Discogs' "All" pseudo-folder, which the app shows as Collection, so it is never
/// listed as a folder. Uncategorized is pinned first, as on discogs.com; the rest sort the way
/// Finder sorts, so "Shelf 2" comes before "Shelf 10".
enum CollectionFolders {
    static func ordered(_ folders: [FolderSnapshot]) -> [FolderSnapshot] {
        folders
            .filter { $0.id != DiscogsFolder.all }
            .sorted { lhs, rhs in
                let lhsPinned = lhs.id == DiscogsFolder.uncategorized
                let rhsPinned = rhs.id == DiscogsFolder.uncategorized
                if lhsPinned != rhsPinned { return lhsPinned }
                switch lhs.name.localizedStandardCompare(rhs.name) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.id < rhs.id
                }
            }
    }

    /// The folder to show for a stored choice: that folder while it exists, Collection otherwise.
    ///
    /// Resolved on every read and never written back. A folder removed on discogs.com falls back to
    /// Collection, and a remembered folder comes back once a first sync has cached it.
    static func resolved(_ folderID: Int, among folders: [FolderSnapshot]) -> Int {
        folders.contains { $0.id == folderID && $0.id != DiscogsFolder.all } ? folderID : DiscogsFolder.all
    }

    /// Copies per folder, counted from the cache rather than taken from Discogs: the reported count
    /// is only as fresh as the last sync, and an add or remove on this device changes it at once.
    static func counts(of folderIDs: some Sequence<Int>) -> [Int: Int] {
        folderIDs.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    /// The folders an add can target. Uncategorized is always among them: it exists on every
    /// Discogs account, even before a first sync has cached it.
    static func addTargets(_ folders: [FolderSnapshot]) -> [FolderSnapshot] {
        let listed = ordered(folders)
        guard !listed.contains(where: { $0.id == DiscogsFolder.uncategorized }) else { return listed }
        return [FolderSnapshot(id: DiscogsFolder.uncategorized, name: "Uncategorized", count: 0)] + listed
    }

    /// The folder an add preselects: the folder on screen, or Uncategorized from Collection.
    static func addTarget(for folderID: Int, among targets: [FolderSnapshot]) -> Int {
        targets.contains { $0.id == folderID } ? folderID : DiscogsFolder.uncategorized
    }
}
