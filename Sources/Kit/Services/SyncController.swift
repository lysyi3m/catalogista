import DiscogsKit
import Foundation

/// Drives refreshes on behalf of the UI and publishes their state.
///
/// Kept separate from `AppServices` so views observe only what changes during a sync, and so the
/// progress and error handling live outside the view body.
@MainActor
@Observable
final class SyncController {
    private(set) var isSyncing = false
    private(set) var progress: CollectionSyncer.Progress?
    private(set) var errorMessage: String?
    private(set) var lastSummary: CollectionSyncer.Summary?
    /// Set when the last attempt never reached Discogs. The cache is still good, so this is a
    /// status rather than a failure.
    private(set) var isOffline = false
    private(set) var lastSyncedAt: Date?
    /// Bumped when any sync ends, applied or not: a sync that fails late has already written its
    /// pages, so what the cache holds may have changed either way.
    private(set) var syncsEnded = 0
    /// What the current operation is doing, for a progress label. Nil when idle.
    private(set) var activity: String?

    private unowned let services: AppServices
    /// The sync currently in flight, so work tied to the account can be stopped before the account
    /// goes away, and so `syncAfterWrite` can tell whether it started after a write. Held because
    /// `start` deliberately shields the work from its caller.
    private var running: (number: Int, task: Task<Bool, Never>)?
    /// Counts sync starts; `running.number` is the count when it started.
    private var syncCount = 0
    /// Cover downloads, which outlive the sync that scheduled them. Tracked so sign-out can stop
    /// them: they write files for whichever account asked for them.
    private var warmingArtwork: Task<Void, Never>?
    nonisolated static let lastSyncedKey = "lastSyncedAt"

    init(services: AppServices) {
        self.services = services
        lastSyncedAt = services.defaults.object(forKey: Self.lastSyncedKey) as? Date
    }

    /// A refresh on launch is wanted, but not on every window that opens seconds apart.
    var shouldSyncOnLaunch: Bool {
        guard services.hasToken else { return false }
        guard let lastSyncedAt else { return true }
        return Date().timeIntervalSince(lastSyncedAt) > 300
    }

    /// Keeps the collection inside `Freshness.maximumAge` for as long as the caller runs.
    ///
    /// Sleeps until the last sync falls due, syncs, and retries every `Freshness.retryInterval`
    /// while that fails. Offline, the cache stays on screen with its age, and catches up once
    /// Discogs is reachable.
    ///
    /// The sleep runs on the continuous clock, so a device that slept through the deadline syncs
    /// as soon as it wakes.
    func keepFresh() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(Freshness.timeUntilStale(lastSyncedAt)))
                if services.hasToken, !Freshness.isFresh(lastSyncedAt), !isSyncing {
                    await sync()
                }
                if !Freshness.isFresh(lastSyncedAt) {
                    try await Task.sleep(for: .seconds(Freshness.retryInterval))
                }
            } catch {
                return
            }
        }
    }

    /// Runs a full refresh. Concurrent calls are ignored, so pull-to-refresh cannot stack syncs.
    @discardableResult
    func sync() async -> Bool {
        guard !isSyncing else { return false }
        return await start(activity: "Syncing…").value
    }

    /// Runs a sync that is guaranteed to have started *after* this call, and reports whether it
    /// finished successfully.
    ///
    /// `sync()` returns immediately when one is already in flight, which is fine for a refresh but
    /// useless for settling a write: that sync began before the write and cannot have seen it.
    /// Reading `errorMessage` afterwards is worse still, because the in-flight sync may have set
    /// it. So an older sync is waited out, and a sync that started after this call is joined
    /// rather than competed with: two writes settling at once share one sync.
    func syncAfterWrite() async -> Bool {
        let startedBefore = syncCount
        while let running {
            if running.number > startedBefore { return await running.task.value }
            _ = await running.task.value
        }
        return await start(activity: "Syncing…").value
    }

    /// Starts a sync in a task of its own, so whoever asked for it cannot cancel it half-done.
    ///
    /// `.refreshable` cancels its task the moment the refresh control retracts, and a collection
    /// fetch that is cancelled mid-stream returns no pages at all. A refresh the user asked for is
    /// worth finishing. The task is kept so `cancelAndWait` can still stop it deliberately — being
    /// shielded from the caller is not the same as being unstoppable.
    ///
    /// The task also returns the controller to idle before it finishes, so whoever its result
    /// wakes finds no sync in flight.
    private func start(rebuilding: Bool = false, activity: String) -> Task<Bool, Never> {
        syncCount += 1
        isSyncing = true
        self.activity = activity
        let task = Task {
            let succeeded = await self.performSync(rebuilding: rebuilding)
            self.isSyncing = false
            self.activity = nil
            self.progress = nil
            self.running = nil
            return succeeded
        }
        running = (syncCount, task)
        return task
    }

    /// Stops any sync in flight and waits for it to finish unwinding.
    ///
    /// Sign-out clears the token and the cache; a sync still running would otherwise write the old
    /// account's records back into the store behind it. A cancelled fetch throws rather than
    /// pruning, so nothing is half-applied.
    func cancelAndWait() async {
        warmingArtwork?.cancel()
        let running = running?.task
        running?.cancel()
        // Before waiting: the warmer's children wait on downloads the image cache shares between
        // callers, which cancelling the warmer does not reach. Waiting first would wait for the
        // whole cover backlog.
        await services.imageCache.cancelInFlightDownloads()
        await warmingArtwork?.value
        _ = await running?.value
        warmingArtwork = nil
    }

    /// Clears everything learned from the disconnected account, so a new sign-in in the same
    /// session starts as a first run: no sync date, summary, error or offline state carried over.
    func forgetAccount() {
        lastSyncedAt = nil
        lastSummary = nil
        errorMessage = nil
        isOffline = false
        progress = nil
        services.defaults.removeObject(forKey: Self.lastSyncedKey)
    }

    enum ResetError: LocalizedError {
        case noToken
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noToken:
                return "Connect to Discogs to continue."
            case .failed(let reason):
                return ["Your cache has not been cleared.", reason].filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
    }

    /// Syncs, then drops every release detail and cover so they are fetched again.
    ///
    /// The cache is the only copy of the collection this device has, so nothing is dropped until
    /// the whole collection has downloaded and checked out (`CollectionSyncer.reconcile(rebuilding:)`).
    /// A download that fails, offline most likely, leaves the cache browsable and says so.
    func resetAndResync() async throws {
        guard !isSyncing else { return }
        guard services.client != nil else { throw ResetError.noToken }

        guard await start(rebuilding: true, activity: "Downloading collection…").value else {
            let reason = errorMessage ?? ""
            // The cache is intact, so on the collection screen being offline is a status line, as
            // after any failed sync.
            if isOffline { errorMessage = nil }
            throw ResetError.failed(reason)
        }
    }

    private func performSync(rebuilding: Bool = false) async -> Bool {
        guard let syncer = services.makeSyncer() else { return false }
        errorMessage = nil
        defer { syncsEnded += 1 }

        do {
            let summary = try await syncer.reconcile(rebuilding: rebuilding) { update in
                Task { @MainActor in self.progress = update }
            }
            lastSummary = summary
            services.rememberUsername(summary.username)
            isOffline = false
            lastSyncedAt = Date()
            services.defaults.set(lastSyncedAt, forKey: Self.lastSyncedKey)

            // The collection is correct now. Covers are a pre-fetch — the grid loads what it shows
            // on demand — so they warm in the background rather than holding the sync open.
            startWarmingArtwork(summary.artwork, using: syncer)
            return true
        } catch is CancellationError {
            // The caller went away; not a failure worth surfacing.
            return false
        } catch {
            isOffline = (error as? DiscogsError)?.isOffline ?? false
            // Always recorded here; callers for which being offline is merely a status clear it.
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Replaces the previous warmer, cancelling it.
    ///
    /// Not drained: its children may be waiting on downloads a visible cover shares, and those
    /// run to the end whoever cancels. Cancelled, it starts no new downloads. Sign-out and Reset
    /// Cache stop the downloads themselves (`cancelAndWait`, `ImageCache.removeAll`), so nothing is
    /// written for an account that is gone.
    private func startWarmingArtwork(
        _ targets: [CollectionSyncer.ArtworkTarget],
        using syncer: CollectionSyncer
    ) {
        warmingArtwork?.cancel()
        warmingArtwork = Task {
            let fetched = await syncer.warmArtwork(targets)
            if fetched > 0, !Task.isCancelled { services.noteImagesChanged() }
        }
    }
}
