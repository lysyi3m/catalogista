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

    @Test("A slow earlier search cannot overwrite a newer one's results")
    func staleResponseIsDiscarded() async throws {
        let slowPage = try page(titles: ["Stale Result"])
        let fastPage = try page(titles: ["Fresh Result"])

        let controller = ReleaseSearchController { query, _ in
            if query == "slow" {
                // Lands after the second search has already finished.
                try await Task.sleep(for: .milliseconds(300))
                return slowPage
            }
            return fastPage
        }

        controller.search("slow")
        controller.search("fast")

        try await waitUntil { controller.results.first?.title == "Fresh Result" }
        // Give the slow response time to land and do damage, if it still can.
        try await Task.sleep(for: .milliseconds(400))

        #expect(controller.results.map(\.title) == ["Fresh Result"],
                "the superseded search must not replace newer results")
    }

    @Test("A failure from a superseded search does not clear newer results")
    func staleFailureIsDiscarded() async throws {
        struct Boom: Error {}
        let fastPage = try page(titles: ["Fresh Result"])

        let controller = ReleaseSearchController { query, _ in
            if query == "doomed" {
                try await Task.sleep(for: .milliseconds(300))
                throw Boom()
            }
            return fastPage
        }

        controller.search("doomed")
        controller.search("fast")

        try await waitUntil { controller.results.first?.title == "Fresh Result" }
        try await Task.sleep(for: .milliseconds(400))

        #expect(controller.results.map(\.title) == ["Fresh Result"])
        #expect(controller.state == .loaded(total: 1), "a stale failure must not become the state")
    }

    @Test("The newest search's results and total are the ones shown")
    func newestSearchWins() async throws {
        let controller = ReleaseSearchController { query, _ in
            try await Task.sleep(for: .milliseconds(query == "first" ? 200 : 10))
            return try self.page(titles: ["\(query) hit"], total: query == "first" ? 999 : 7)
        }

        controller.search("first")
        controller.search("second")

        try await waitUntil { controller.state == .loaded(total: 7) }
        try await Task.sleep(for: .milliseconds(300))

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
