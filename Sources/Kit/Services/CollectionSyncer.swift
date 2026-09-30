import DiscogsKit
import Foundation

/// Drives a full refresh: Discogs pages in, and the SwiftData cache is reconciled against it. The
/// artwork to prefetch goes back to the caller in `Summary.artwork`.
///
/// Reconciliation is by `instanceID`, and anything the server no longer reports is dropped, so a
/// copy removed on discogs.com disappears here on the next refresh.
actor CollectionSyncer {
    struct Progress: Sendable {
        var page: Int
        var totalPages: Int
        var itemsFetched: Int
        var totalItems: Int
    }

    struct ArtworkTarget: Sendable {
        let releaseID: Int
        let url: URL
        let kind: ImageCache.Kind
    }

    struct Summary: Sendable {
        var username: String
        var itemsSynced: Int
        var itemsRemoved: Int
        /// The covers worth having on disk. Handed back rather than downloaded here, so a caller
        /// can call the sync finished the moment the collection is correct.
        var artwork: [ArtworkTarget]
    }

    enum SyncError: LocalizedError {
        case incompleteCollection(seen: Int, expected: Int)

        var errorDescription: String? {
            switch self {
            case .incompleteCollection:
                return "Sync incomplete. Nothing was removed."
            }
        }
    }

    private let client: DiscogsClient
    private let store: CollectionStore
    private let imageCache: ImageCache

    init(client: DiscogsClient, store: CollectionStore, imageCache: ImageCache) {
        self.client = client
        self.store = store
        self.imageCache = imageCache
    }

    /// Reconciles the whole collection against Discogs.
    ///
    /// Artwork is not downloaded here. The collection is correct as soon as this returns, and the
    /// grid loads whatever covers it needs on demand, so holding the sync open for a few hundred
    /// image downloads only makes a finished sync look stuck.
    ///
    /// - Parameter onProgress: called after each page so the UI can fill in during a first sync.
    ///
    /// - Parameter rebuilding: also drop every release detail and cover once the collection is in,
    ///   so they are fetched again (Settings ▸ Reset Cache). Nothing is dropped before the whole
    ///   collection has downloaded and checked out, so a download that fails leaves the cache as it
    ///   was.
    @discardableResult
    func reconcile(
        rebuilding: Bool = false,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Summary {
        // Writes made while the pages come in are recorded, so the reconciliation respects them.
        await store.beginSync()
        do {
            let summary = try await fetchAndReconcile(rebuilding: rebuilding, onProgress: onProgress)
            await store.endSync()
            return summary
        } catch {
            await store.endSync()
            throw error
        }
    }

    private func fetchAndReconcile(
        rebuilding: Bool,
        onProgress: (@Sendable (Progress) -> Void)?
    ) async throws -> Summary {
        let identity = try await client.identity()

        try await store.upsertFolders(try await client.folders(user: identity.username))

        var seenInstanceIDs = Set<Int>()
        var seenFolderIDs = Set<Int>()
        var itemsSynced = 0
        var pagesSeen = 0
        var reportedItems: Int?
        var reportedPages: Int?
        var artworkTargets: [ArtworkTarget] = []

        for try await page in client.collectionPages(user: identity.username) {
            try Task.checkCancellation()
            try await store.upsert(page.releases)

            for item in page.releases {
                seenInstanceIDs.insert(item.instanceID)
                seenFolderIDs.insert(item.folderID)
                // The grid draws cover art, so that is what is worth having on disk before the
                // user scrolls. The thumb is only a fallback for releases with no cover.
                let source = item.basicInformation.coverImage ?? item.basicInformation.thumb
                let kind: ImageCache.Kind = item.basicInformation.coverImage == nil ? .thumb : .cover
                if let source, let url = URL(string: source) {
                    artworkTargets.append(ArtworkTarget(releaseID: item.releaseID, url: url, kind: kind))
                }
            }
            itemsSynced += page.releases.count
            pagesSeen += 1
            reportedItems = page.pagination.items
            reportedPages = page.pagination.pages

            onProgress?(Progress(
                page: page.pagination.page,
                totalPages: page.pagination.pages,
                itemsFetched: itemsSynced,
                totalItems: page.pagination.items
            ))
        }

        // An `AsyncThrowingStream` answers cancellation by finishing, not by throwing, so the loop
        // above exits normally and its `checkCancellation` never runs. Without this, a cancelled
        // fetch is indistinguishable from a collection with nothing in it.
        try Task.checkCancellation()

        // The cache is this device's only copy, so deletion needs more than the absence of an
        // error. A 200 that is short a page, or that carries an empty `releases` array, would
        // otherwise wipe a collection that is still there. Discogs is canonical only when its own
        // item count matches what it actually sent, counted as distinct copies: pages that shift
        // while the collection changes can repeat a copy and skip another, and the rows would
        // still add up.
        guard let reportedItems, let reportedPages,
              pagesSeen >= reportedPages, itemsSynced == reportedItems,
              seenInstanceIDs.count == reportedItems else {
            throw SyncError.incompleteCollection(seen: seenInstanceIDs.count, expected: reportedItems ?? 0)
        }
        // Fetched again, so the list is at least as new as the copies: a folder created while the
        // pages came in is not missing from it. Removed folders go only now, and never one a copy
        // still names. See `replaceFolders(_:keeping:)`.
        let folders = try await client.folders(user: identity.username)

        let itemsRemoved = try await store.pruneItems(keeping: seenInstanceIDs)
        try await store.replaceFolders(folders, keeping: seenFolderIDs)
        if rebuilding {
            try await store.pruneReleaseDetails(keeping: [])
            try await imageCache.removeAll()
        }

        // Only after a complete fetch, like pruning copies. Read from the store rather than the
        // pages, so a copy added on this device while they came in keeps its art and details.
        let keptReleases = try await store.releaseIDs()
        try await store.pruneReleaseDetails(keeping: keptReleases)
        await imageCache.prune(keeping: keptReleases)

        return Summary(
            username: identity.username,
            itemsSynced: itemsSynced,
            itemsRemoved: itemsRemoved,
            artwork: artworkTargets
        )
    }

    /// Downloads any artwork not already on disk. Failures are skipped: a missing cover must not
    /// fail a sync that otherwise succeeded, and the next refresh will try again.
    @discardableResult
    func warmArtwork(_ targets: [ArtworkTarget]) async -> Int {
        await withTaskGroup(of: Bool.self) { group in
            // Two copies of one release share a cover; one download serves both.
            var seen = Set<String>()
            for target in targets where seen.insert("\(target.kind.rawValue)/\(target.releaseID)").inserted {
                group.addTask { [imageCache] in
                    // Checked against the source, so art whose URL changed is downloaded again and
                    // covers follow Discogs on the same schedule as the rest of the collection.
                    if await imageCache.isCached(
                        releaseID: target.releaseID,
                        kind: target.kind,
                        source: target.url
                    ) {
                        return false
                    }
                    do {
                        try await imageCache.localURL(
                            releaseID: target.releaseID,
                            kind: target.kind,
                            remoteURL: target.url
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }

            var fetched = 0
            for await didFetch in group where didFetch { fetched += 1 }
            return fetched
        }
    }
}
