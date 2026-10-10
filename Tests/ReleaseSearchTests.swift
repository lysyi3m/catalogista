import DiscogsKit
import Foundation
import Testing
@testable import CatalogistaKit

@Suite("Release search ordering")
@MainActor
struct ReleaseSearchTests {
    private func page(
        titles: [String],
        total: Int? = nil,
        number: Int = 1,
        pages: Int = 1,
        firstID: Int = 1
    ) throws -> SearchPage {
        let results = titles.enumerated().map { index, title in
            #"{ "id": \#(firstID + index), "title": "\#(title)" }"#
        }.joined(separator: ",")
        let json = """
        {
          "pagination": { "page": \(number), "pages": \(pages), "per_page": 50, "items": \(total ?? titles.count) },
          "results": [\(results)]
        }
        """
        return try DiscogsClient.makeDecoder().decode(SearchPage.self, from: Data(json.utf8))
    }

    /// Waits until `condition` holds, so tests do not depend on fixed sleeps.
    private func waitUntil(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition never became true")
    }

    @Test("More results append the next page of the searched query, not of what is typed")
    func loadMoreAppendsNextPage() async throws {
        let first = try page(titles: ["A", "B"], total: 3, number: 1, pages: 2)
        // Repeats B: results can shift between pages while Discogs is searched.
        let second = try page(titles: ["B", "C"], total: 3, number: 2, pages: 2, firstID: 2)
        var requests: [(String, Int)] = []
        let controller = ReleaseSearchController { query, number in
            requests.append((query, number))
            return number == 1 ? first : second
        }

        controller.search("heads")
        try await waitUntil { controller.results.count == 2 }
        #expect(controller.hasMore)
        #expect(controller.submittedQuery == "heads")

        controller.loadMore()
        try await waitUntil { controller.results.count == 3 }
        #expect(controller.results.map(\.releaseTitle) == ["A", "B", "C"])
        #expect(controller.hasMore == false)
        #expect(requests.map(\.0) == ["heads", "heads"])
        #expect(requests.map(\.1) == [1, 2])
    }

    /// Holds a request until the test opens it, then lets it answer as a late response would: the
    /// wait ignores cancellation, as a network response already on its way does.
    @MainActor
    final class Gate {
        private(set) var isWaiting = false
        private(set) var hasAnswered = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }

        func markAnswered() { hasAnswered = true }
    }

    /// Starts `old` and holds it at the gate, runs `new` to completion, then lets `old` answer
    /// late. Returns once the old answer has had its chance to land.
    private func runOldAfterNew(
        _ controller: ReleaseSearchController,
        old: String,
        new: String,
        gate: Gate,
        newIsDone: () -> Bool
    ) async throws {
        controller.search(old)
        try await waitUntil { gate.isWaiting }
        controller.search(new)
        try await waitUntil(newIsDone)
        gate.open()
        try await waitUntil { gate.hasAnswered }
        // The controller applies an answer on the main actor right after it arrives.
        for _ in 0..<10 { await Task.yield() }
    }

    @Test("A slow earlier search cannot overwrite a newer one's results")
    func staleResponseIsDiscarded() async throws {
        let slowPage = try page(titles: ["Stale Result"])
        let fastPage = try page(titles: ["Fresh Result"])
        let gate = Gate()

        let controller = ReleaseSearchController { query, _ in
            guard query == "slow" else { return fastPage }
            await gate.wait()
            await gate.markAnswered()
            return slowPage
        }

        try await runOldAfterNew(controller, old: "slow", new: "fast", gate: gate) {
            controller.results.first?.title == "Fresh Result"
        }

        #expect(controller.results.map(\.title) == ["Fresh Result"],
                "the superseded search must not replace newer results")
    }

    @Test("A failure from a superseded search does not clear newer results")
    func staleFailureIsDiscarded() async throws {
        struct Boom: Error {}
        let fastPage = try page(titles: ["Fresh Result"])
        let gate = Gate()

        let controller = ReleaseSearchController { query, _ in
            guard query == "doomed" else { return fastPage }
            await gate.wait()
            await gate.markAnswered()
            throw Boom()
        }

        try await runOldAfterNew(controller, old: "doomed", new: "fast", gate: gate) {
            controller.results.first?.title == "Fresh Result"
        }

        #expect(controller.results.map(\.title) == ["Fresh Result"])
        #expect(controller.state == .loaded(total: 1), "a stale failure must not become the state")
    }

    @Test("The newest search's results and total are the ones shown")
    func newestSearchWins() async throws {
        let gate = Gate()
        let controller = ReleaseSearchController { query, _ in
            if query == "first" {
                await gate.wait()
                await gate.markAnswered()
            }
            return try self.page(titles: ["\(query) hit"], total: query == "first" ? 999 : 7)
        }

        try await runOldAfterNew(controller, old: "first", new: "second", gate: gate) {
            controller.state == .loaded(total: 7)
        }

        #expect(controller.state == .loaded(total: 7))
        #expect(controller.results.first?.title == "second hit")
    }

    @Test("A blank query starts nothing")
    func blankQueryIsIgnored() async throws {
        let controller = ReleaseSearchController { _, _ in
            Issue.record("a blank query must not reach the network")
            return try self.page(titles: [])
        }

        controller.search("   ")
        #expect(controller.state == .idle)
    }
}
