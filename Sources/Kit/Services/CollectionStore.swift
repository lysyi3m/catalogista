import DiscogsKit
import Foundation
import SwiftData

/// Owns the SwiftData cache: every fetch and mutation on one context, serialised by the actor.
///
/// The context has no queue of its own, so the work runs on the calling thread — on the main
/// thread when a main-actor caller awaits it. A sync stays off the main thread because its calls
/// come from the `CollectionSyncer` actor; main-actor callers should touch a few rows at most.
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
    ///
    /// During a sync, a copy removed or moved on this device that the sync could still undo is
    /// skipped: the page that lists it may predate the write. See `writes`.
    func upsert(_ items: [CollectionItem]) throws {
        // Only this page's copies: fetching the whole collection for every page made a sync
        // quadratic in the collection's size.
        let incoming = items.map(\.instanceID)
        let descriptor = FetchDescriptor<CachedCollectionItem>(
            predicate: #Predicate { incoming.contains($0.instanceID) }
        )
        let existing = Dictionary(
            try modelContext.fetch(descriptor).map { ($0.instanceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let skipped = respectedWrites(.removed).union(respectedWrites(.moved))
        for item in items where !skipped.contains(item.instanceID) {
            if let cached = existing[item.instanceID] {
                cached.update(from: item)
            } else {
                modelContext.insert(CachedCollectionItem(from: item))
            }
        }
        try saveOrRollback()
    }

    /// Drops every cached copy whose `instanceID` is absent from `instanceIDs`, except those added
    /// on this device that the sync could still undo: its pages may predate them. See `writes`.
    @discardableResult
    func pruneItems(keeping instanceIDs: Set<Int>) throws -> Int {
        let kept = instanceIDs.union(respectedWrites(.added))
        let stale = try modelContext.fetch(FetchDescriptor<CachedCollectionItem>())
            .filter { !kept.contains($0.instanceID) }
        for item in stale { modelContext.delete(item) }
        try saveOrRollback()
        return stale.count
    }

    func deleteItem(instanceID: Int) throws {
        guard let item = try cachedItem(instanceID: instanceID) else { return }
        modelContext.delete(item)
        try saveOrRollback()
        mark(instanceID, .removed)
    }

    // MARK: - Optimistic writes

    /// Inserts a copy the user just added, before Discogs has confirmed it.
    func insert(_ pending: PendingAddition) throws {
        modelContext.insert(CachedCollectionItem(from: pending))
        try saveOrRollback()
        mark(pending.instanceID, .added)
    }

    /// Puts a removed copy back, after Discogs rejected the delete.
    func restore(_ snapshot: CollectionItemSnapshot) throws {
        guard try cachedItem(instanceID: snapshot.instanceID) == nil else { return }
        modelContext.insert(CachedCollectionItem(from: snapshot))
        try saveOrRollback()
        unmark(snapshot.instanceID, .removed)
    }

    /// Files a copy under another folder, before Discogs has confirmed it, and returns the folder it
    /// was in; nil when the cache has no such copy. Also how a rejected move is put back.
    @discardableResult
    func moveItem(instanceID: Int, toFolderID folderID: Int) throws -> Int? {
        guard let item = try cachedItem(instanceID: instanceID) else { return nil }
        let previous = item.folderID
        item.folderID = folderID
        try saveOrRollback()
        mark(instanceID, .moved)
        return previous
    }

    /// Swaps a provisional id for the one Discogs assigned.
    func reassignInstanceID(from provisional: Int, to confirmed: Int) throws {
        guard let item = try cachedItem(instanceID: provisional) else { return }
        item.instanceID = confirmed
        try saveOrRollback()
        unmark(provisional, .added)
        mark(confirmed, .added)
    }

    /// Replaces the search-derived fields with the release's own, once it has been fetched.
    func apply(_ release: Release, toInstanceID instanceID: Int) throws {
        guard let item = try cachedItem(instanceID: instanceID) else { return }
        item.apply(release)
        try saveOrRollback()
    }

    // MARK: - Release detail

    /// Every release the cache still holds a copy of, for dropping details and art of the rest.
    func releaseIDs() throws -> Set<Int> {
        Set(try modelContext.fetch(FetchDescriptor<CachedCollectionItem>()).map(\.releaseID))
    }

    /// Drops details of releases no cached copy belongs to: removed records, and releases opened
    /// from search but never added.
    @discardableResult
    func pruneReleaseDetails(keeping releaseIDs: Set<Int>) throws -> Int {
        let stale = try modelContext.fetch(FetchDescriptor<CachedReleaseDetail>())
            .filter { !releaseIDs.contains($0.releaseID) }
        for detail in stale { modelContext.delete(detail) }
        try saveOrRollback()
        return stale.count
    }

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
        try saveOrRollback()
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
        try saveOrRollback()
    }

    // MARK: - Custom fields

    /// The owner's custom fields, in the order discogs.com shows them.
    func fields() throws -> [CustomField] {
        var descriptor = FetchDescriptor<CachedField>()
        descriptor.sortBy = [SortDescriptor(\.position), SortDescriptor(\.id)]
        return try modelContext.fetch(descriptor).map(\.field)
    }

    /// Makes the cached fields exactly `fields`. Unlike folders, nothing refers to a field that
    /// would be stranded: a value whose field is gone is simply not shown.
    func replaceFields(_ fields: [CustomField]) throws {
        var existing = try Dictionary(
            modelContext.fetch(FetchDescriptor<CachedField>()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for field in fields {
            if let cached = existing.removeValue(forKey: field.id) {
                cached.update(from: field)
            } else {
                modelContext.insert(CachedField(from: field))
            }
        }
        for stale in existing.values { modelContext.delete(stale) }
        try saveOrRollback()
    }

    // MARK: - Writes during a sync

    /// Copies added, removed or moved on this device, for as long as a sync could still undo them.
    ///
    /// A sync reads Discogs over many requests, so its pages can predate a write: pruning would
    /// delete a copy just added, and a page would put back a copy just removed or file a moved
    /// copy back in its old folder. That holds for a write already in flight when the sync starts
    /// as much as for one made during it. So a write is marked from the moment it touches the
    /// cache, stays marked while in flight, and after it settles is still respected by any sync
    /// that began before it settled. A sync that begins later fetched its pages after the write
    /// landed, and drops the mark. Kept on this actor, so a write and a sync's use of the marks
    /// cannot interleave.
    ///
    /// Marked per kind: a copy added and then moved needs both protections, and the move must not
    /// end the add's.
    private var writes: [WriteKey: WriteMark] = [:]
    /// Counts sync starts, to tell which syncs began before a write settled.
    private var syncEpoch = 0
    /// The epoch of the sync in progress, if any.
    private var runningSync: Int?

    private struct WriteKey: Hashable {
        enum Kind { case added, removed, moved }
        let instanceID: Int
        let kind: Kind
    }

    private struct WriteMark {
        /// The epoch when the write finished; nil while it is in flight.
        var settledAt: Int?
    }

    private func mark(_ instanceID: Int, _ kind: WriteKey.Kind) {
        writes[WriteKey(instanceID: instanceID, kind: kind)] = WriteMark()
    }

    private func unmark(_ instanceID: Int, _ kind: WriteKey.Kind) {
        writes[WriteKey(instanceID: instanceID, kind: kind)] = nil
    }

    private func respectedWrites(_ kind: WriteKey.Kind) -> Set<Int> {
        guard let runningSync else { return [] }
        return Set(writes.filter { $0.key.kind == kind && ($0.value.settledAt ?? .max) >= runningSync }.map(\.key.instanceID))
    }

    /// Ends the in-flight period of the writes to these copies. Settling twice is harmless.
    func settleWrites(_ instanceIDs: Set<Int>) {
        for key in writes.keys where instanceIDs.contains(key.instanceID) && writes[key]?.settledAt == nil {
            writes[key]?.settledAt = syncEpoch
        }
    }

    func beginSync() {
        syncEpoch += 1
        runningSync = syncEpoch
        // Settled before this sync started: its pages reflect them.
        writes = writes.filter { ($0.value.settledAt ?? .max) >= syncEpoch }
    }

    func endSync() {
        runningSync = nil
    }

    // MARK: - Maintenance

    func removeAll() throws {
        try modelContext.delete(model: CachedCollectionItem.self)
        try modelContext.delete(model: CachedReleaseDetail.self)
        try modelContext.delete(model: CachedFolder.self)
        try modelContext.delete(model: CachedField.self)
        try saveOrRollback()
    }

    /// Saves, or discards every unsaved change if the save fails. The context lives as long as the
    /// app, so a change left pending would be saved by the next unrelated write — an optimistic
    /// insert whose request never went out, for one.
    private func saveOrRollback() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
