import DiscogsKit
import Foundation
import SwiftData

/// Loads a release detail cache-first, fetching from Discogs on a miss or once the cached copy
/// passes `Freshness.maximumAge`.
///
/// Tracklist, notes and the edition's country all arrive together from `GET /releases/{id}` —
/// there is no lighter call for any of them — so opening a record fetches once and keeps the
/// result. Another visit within six hours costs nothing against the rate limit. A stale copy that
/// cannot be refreshed, because Discogs is unreachable, is still shown.
@MainActor
@Observable
final class ReleaseDetailLoader {
    enum State: Equatable {
        case loading
        case loaded(ReleaseDetailSnapshot)
        case failed(String)
    }

    private(set) var state: State = .loading

    var snapshot: ReleaseDetailSnapshot? {
        if case .loaded(let snapshot) = state { return snapshot }
        return nil
    }

    /// When the shown copy was fetched, if it is past `Freshness.maximumAge` — a refresh failed and
    /// the cached copy is standing in. The page shows this age itself: the collection's sync time
    /// says nothing about how old this release's details are.
    var staleSince: Date? {
        guard let snapshot, !Freshness.isFresh(snapshot.fetchedAt, now: now()) else { return nil }
        return snapshot.fetchedAt
    }

    private let services: AppServices
    /// The clock freshness is judged by. Injectable so tests can age a copy without waiting.
    private let now: () -> Date

    /// - Parameter cached: the copy already on this device, shown from the start. See
    ///   `cachedDetail(releaseID:in:)`.
    init(services: AppServices, cached: ReleaseDetailSnapshot? = nil, now: @escaping () -> Date = Date.init) {
        self.services = services
        self.now = now
        if let cached { state = .loaded(cached) }
    }

    /// The cached copy of a release, read on `context` without leaving the caller's thread.
    ///
    /// A record page reads it on the main context before its first frame. A read through
    /// `CollectionStore` hops to the store's actor and lands a frame or two later, so every open
    /// flashed "Loading details…" and the tracklist popped in, cached copy or not.
    static func cachedDetail(releaseID: Int, in context: ModelContext?) -> ReleaseDetailSnapshot? {
        guard let context else { return nil }
        var descriptor = FetchDescriptor<CachedReleaseDetail>(
            predicate: #Predicate { $0.releaseID == releaseID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first?.snapshot
    }

    /// Fresh, and stored by a version of the app that keeps the release's images.
    private func isCurrent(_ snapshot: ReleaseDetailSnapshot) -> Bool {
        Freshness.isFresh(snapshot.fetchedAt, now: now()) && snapshot.imageURLs != nil
    }

    /// Shows the release, fetching it when there is no copy or the copy is past
    /// `Freshness.maximumAge`. A stale page stays on screen while it refreshes.
    func load(releaseID: Int) async {
        if let snapshot, isCurrent(snapshot) { return }
        if snapshot == nil { state = .loading }
        let generation = services.accountGeneration
        var cached = snapshot
        do {
            if let stored = try await services.store.releaseDetail(releaseID: releaseID) {
                cached = stored
            }
            if let cached, isCurrent(cached) {
                state = .loaded(cached)
                return
            }
            // A stale copy goes up at once and is replaced when the refresh lands. Held back, the
            // page stays blank for as long as the request takes, rate-limit waits included.
            if let cached { state = .loaded(cached) }
            guard let client = services.client else {
                state = cached.map(State.loaded) ?? .failed("Connect to Discogs to continue.")
                return
            }
            let release = try await client.release(id: releaseID)
            // Disconnected while the request was out: the cache is cleared, and this release
            // belongs to the account that is gone.
            guard services.accountGeneration == generation else { return }
            state = .loaded(try await services.store.upsertReleaseDetail(release))
        } catch is CancellationError {
            // The record page was dismissed before the fetch finished.
        } catch {
            state = cached.map(State.loaded) ?? .failed(error.localizedDescription)
        }
    }

    /// Keeps an open page inside `Freshness.maximumAge`: reloads when the shown copy falls due,
    /// and retries every `Freshness.retryInterval` while that fails.
    func keepFresh(releaseID: Int) async {
        while !Task.isCancelled {
            let wait = Freshness.timeUntilStale(snapshot?.fetchedAt, now: now())
            do {
                try await Task.sleep(for: .seconds(wait > 0 ? wait : Freshness.retryInterval))
            } catch {
                return
            }
            await load(releaseID: releaseID)
        }
    }
}
