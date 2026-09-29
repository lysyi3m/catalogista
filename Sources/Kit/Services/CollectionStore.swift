import DiscogsKit
import Foundation
import SwiftData

/// Owns the SwiftData cache. A `@ModelActor` keeps every mutation on one context off the main
/// thread, which a full-collection sync needs.
///
/// Discogs is canonical, so a sync upserts by `instanceID` and then drops every row Discogs no
/// longer reports.
@ModelActor
actor CollectionStore {
    // MARK: - Collection items

    func itemCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<CachedCollectionItem>())
    }

    func items(
        sortedBy option: CollectionSortOption = .default,
        direction: SortDirection = CollectionSortOption.defaultOrder
    ) throws -> [CollectionItemSnapshot] {
        var descriptor = FetchDescriptor<CachedCollectionItem>()
        descriptor.sortBy = option.sortDescriptors(direction)
        return try modelContext.fetch(descriptor).map(\.snapshot)
    }

    /// Every copy of this release the collection holds, for settling an unconfirmed add.
    ///
    /// Owning a copy already is normal — that is what `instance_id` exists for — so "is this
    /// release present" cannot answer whether *another* one was just added. The set of copies can.
    func instanceIDs(ofRelease releaseID: Int) throws -> Set<Int> {
        let descriptor = FetchDescriptor<CachedCollectionItem>(
            predicate: #Predicate { $0.releaseID == releaseID }
        )
        return Set(try modelContext.fetch(descriptor).map(\.instanceID))
    }

    func item(instanceID: Int) throws -> CollectionItemSnapshot? {
        try cachedItem(instanceID: instanceID)?.snapshot
    }

    private func cachedItem(instanceID: Int) throws -> CachedCollectionItem? {
        var descriptor = FetchDescriptor<CachedCollectionItem>(
            predicate: #Predicate { $0.instanceID == instanceID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Inserts new copies and refreshes existing ones in place.
    func upsert(_ items: [CollectionItem]) throws {
        let existing = try existingItemsByInstanceID()
        for item in items {
            if let cached = existing[item.instanceID] {
                cached.update(from: item)
            } else {
                modelContext.insert(CachedCollectionItem(from: item))
            }
        }
        try modelContext.save()
    }

    /// Drops every cached copy whose `instanceID` is absent from `instanceIDs`.
    @discardableResult
    func pruneItems(keeping instanceIDs: Set<Int>) throws -> Int {
        let stale = try modelContext.fetch(FetchDescriptor<CachedCollectionItem>())
            .filter { !instanceIDs.contains($0.instanceID) }
        for item in stale { modelContext.delete(item) }
        try modelContext.save()
        return stale.count
    }

    func deleteItem(instanceID: Int) throws {
        guard let item = try cachedItem(instanceID: instanceID) else { return }
        modelContext.delete(item)
        try modelContext.save()
    }

    // MARK: - Optimistic writes

    /// Inserts a copy the user just added, before Discogs has confirmed it.
    func insert(_ pending: PendingAddition) throws {
        modelContext.insert(CachedCollectionItem(from: pending))
        try modelContext.save()
    }

    /// Puts a removed copy back, after Discogs rejected the delete.
    func restore(_ snapshot: CollectionItemSnapshot) throws {
        guard try cachedItem(instanceID: snapshot.instanceID) == nil else { return }
        modelContext.insert(CachedCollectionItem(from: snapshot))
        try modelContext.save()
    }

    /// Swaps a provisional id for the one Discogs assigned.
    func reassignInstanceID(from provisional: Int, to confirmed: Int) throws {
        guard let item = try cachedItem(instanceID: provisional) else { return }
        item.instanceID = confirmed
        try modelContext.save()
    }

    /// Replaces the search-derived fields with the release's own, once it has been fetched.
    func apply(_ release: Release, toInstanceID instanceID: Int) throws {
        guard let item = try cachedItem(instanceID: instanceID) else { return }
        item.apply(release)
        try modelContext.save()
    }

    // MARK: - Release detail

    func releaseDetail(releaseID: Int) throws -> ReleaseDetailSnapshot? {
        try cachedReleaseDetail(releaseID: releaseID)?.snapshot
    }

    @discardableResult
    func upsertReleaseDetail(_ release: Release) throws -> ReleaseDetailSnapshot {
        let cached: CachedReleaseDetail
        if let existing = try cachedReleaseDetail(releaseID: release.id) {
            existing.update(from: release)
            cached = existing
        } else {
            cached = CachedReleaseDetail(from: release)
            modelContext.insert(cached)
        }
        try modelContext.save()
        return cached.snapshot
    }

    private func cachedReleaseDetail(releaseID: Int) throws -> CachedReleaseDetail? {
        var descriptor = FetchDescriptor<CachedReleaseDetail>(
            predicate: #Predicate { $0.releaseID == releaseID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    // MARK: - Folders

    func folders() throws -> [FolderSnapshot] {
        var descriptor = FetchDescriptor<CachedFolder>()
        descriptor.sortBy = [SortDescriptor(\.id)]
        return try modelContext.fetch(descriptor).map(\.snapshot)
    }

    /// Inserts new folders and refreshes existing ones, dropping none.
    ///
    /// A sync applies this before it fetches the collection, so a copy that arrives in a new
    /// folder has that folder to appear in. Dropping waits for `replaceFolders(_:keeping:)`.
    func upsertFolders(_ folders: [Folder]) throws {
        try applyFolders(folders, dropping: false, keeping: [])
    }

    /// Makes the cached folders `folders`, keeping any other that a cached copy still names.
    ///
    /// Only after a complete collection fetch: a folder dropped earlier would strand the copies
    /// still filed in it if the fetch then failed. Even then the folder list and the collection are
    /// separate requests, and a folder deleted between them is still named by copies from the
    /// earlier one; it stays until a sync sees no copy in it.
    func replaceFolders(_ folders: [Folder], keeping namedFolderIDs: Set<Int>) throws {
        try applyFolders(folders, dropping: true, keeping: namedFolderIDs)
    }

    private func applyFolders(_ folders: [Folder], dropping: Bool, keeping namedFolderIDs: Set<Int>) throws {
        var existing = try Dictionary(
            modelContext.fetch(FetchDescriptor<CachedFolder>()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for folder in folders {
            if let cached = existing.removeValue(forKey: folder.id) {
                cached.update(from: folder)
            } else {
                modelContext.insert(CachedFolder(from: folder))
            }
        }
        if dropping {
            for stale in existing.values where !namedFolderIDs.contains(stale.id) {
                modelContext.delete(stale)
            }
        }
        try modelContext.save()
    }

    // MARK: - Maintenance

    func removeAll() throws {
        try modelContext.delete(model: CachedCollectionItem.self)
        try modelContext.delete(model: CachedReleaseDetail.self)
        try modelContext.delete(model: CachedFolder.self)
        try modelContext.save()
    }

    private func existingItemsByInstanceID() throws -> [Int: CachedCollectionItem] {
        Dictionary(
            try modelContext.fetch(FetchDescriptor<CachedCollectionItem>()).map { ($0.instanceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
