import DiscogsKit
import Foundation

/// Runs release searches so that only the newest one can change what is on screen.
///
/// Submitting repeatedly, or editing mid-request, puts several requests in flight with no ordering
/// between them, so a slower earlier response could replace newer results. Each search takes a new
/// `generation`, and a response is applied only while its generation is still current.
@MainActor
@Observable
final class ReleaseSearchController {
    enum State: Equatable {
        case idle
        case searching
        case loaded(total: Int)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var results: [SearchResult] = []
    /// The query the results are for. The field can change after submitting; the credit's link and
    /// the next page follow what was searched, not what is typed.
    private(set) var submittedQuery = ""
    /// Whether Discogs has more pages of results for `submittedQuery`.
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    private var loadedPage = 0

    /// Fetches one page of a search. Injected so the ordering can be tested without a network.
    private let performSearch: (String, Int) async throws -> SearchPage

    /// Increments per search; a response may only be applied if its generation is still current.
    private var generation = 0
    private var task: Task<Void, Never>?

    init(performSearch: @escaping (String, Int) async throws -> SearchPage) {
        self.performSearch = performSearch
    }

    convenience init(client: DiscogsClient, perPage: Int = 50) {
        self.init { query, page in
            try await client.searchReleases(query: query, page: page, perPage: perPage)
        }
    }

    var isSearching: Bool { state == .searching }

    func search(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        task?.cancel()
        generation += 1
        let generation = generation
        state = .searching
        submittedQuery = query
        isLoadingMore = false

        task = Task { [weak self] in
            await self?.run(query, generation: generation)
        }
    }

    /// Appends the next page of the current search. A new search supersedes it like any other.
    func loadMore() {
        guard hasMore, !isLoadingMore, case .loaded = state else { return }
        isLoadingMore = true
        let generation = generation
        let query = submittedQuery
        let page = loadedPage + 1

        task = Task { [weak self] in
            await self?.runMore(query, page: page, generation: generation)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run(_ query: String, generation: Int) async {
        do {
            let page = try await performSearch(query, 1)
            // A superseded search must not write over the newer one's results.
            guard generation == self.generation else { return }
            results = page.results
            loadedPage = 1
            hasMore = page.pagination.hasNextPage
            state = .loaded(total: page.pagination.items)
        } catch is CancellationError {
            // A newer search owns the state now.
        } catch {
            guard generation == self.generation else { return }
            results = []
            hasMore = false
            state = .failed(error.localizedDescription)
        }
    }

    private func runMore(_ query: String, page: Int, generation: Int) async {
        defer { if generation == self.generation { isLoadingMore = false } }
        do {
            let next = try await performSearch(query, page)
            guard generation == self.generation else { return }
            // Discogs can shift results between pages while it is searched; a release already
            // shown is not shown twice.
            let shown = Set(results.map(\.id))
            results += next.results.filter { !shown.contains($0.id) }
            loadedPage = page
            hasMore = next.pagination.hasNextPage
            state = .loaded(total: next.pagination.items)
        } catch {
            // The results already shown stay; the button stays to try again.
        }
    }
}
