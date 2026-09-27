import Foundation
import Testing
@testable import CatalogistaKit

@Suite("Freshness")
struct FreshnessTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Data inside six hours is fresh, and data past it is not")
    func sixHourBoundary() {
        #expect(Freshness.isFresh(now.addingTimeInterval(-(6 * 3600 - 60)), now: now))
        #expect(!Freshness.isFresh(now.addingTimeInterval(-(6 * 3600 + 60)), now: now))
    }

    @Test("A date in the future is stale, so a clock moved back cannot hold off refreshes")
    func futureDateIsStale() {
        let ahead = now.addingTimeInterval(24 * 3600)
        #expect(!Freshness.isFresh(ahead, now: now))
        #expect(Freshness.timeUntilStale(ahead, now: now) == 0)
    }

    @Test("The wait until stale counts down from six hours")
    func timeUntilStale() {
        #expect(Freshness.timeUntilStale(now.addingTimeInterval(-3600), now: now) == 5 * 3600)
        #expect(Freshness.timeUntilStale(now.addingTimeInterval(-7 * 3600), now: now) == 0)
    }

    @Test("Data that was never fetched is never fresh")
    func missingDateIsStale() {
        #expect(!Freshness.isFresh(nil, now: now))
    }
}
