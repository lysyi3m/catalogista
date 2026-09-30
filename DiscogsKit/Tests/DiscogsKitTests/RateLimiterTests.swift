import Foundation
import Testing
@testable import DiscogsKit

@Suite("RateLimiter")
struct RateLimiterTests {
    private func response(limit: String?, used: String?, remaining: String?, status: Int = 200) throws -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let limit { headers["X-Discogs-Ratelimit"] = limit }
        if let used { headers["X-Discogs-Ratelimit-Used"] = used }
        if let remaining { headers["X-Discogs-Ratelimit-Remaining"] = remaining }
        return try #require(HTTPURLResponse(
            url: URL(string: "https://api.discogs.com/oauth/identity")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ))
    }

    @Test("Rate-limit headers are absorbed")
    func absorbsHeaders() async throws {
        let limiter = RateLimiter(limit: 60, safetyMargin: 5)
        await limiter.update(from: try response(limit: "60", used: "12", remaining: "48"))

        let state = await limiter.state
        #expect(state.limit == 60)
        #expect(state.used == 12)
        #expect(state.remaining == 48)
    }

    @Test("A response missing the headers leaves the previous state intact")
    func toleratesMissingHeaders() async throws {
        let limiter = RateLimiter(limit: 60, safetyMargin: 5)
        await limiter.update(from: try response(limit: "60", used: "1", remaining: "59"))
        await limiter.update(from: try response(limit: nil, used: nil, remaining: nil))

        let state = await limiter.state
        #expect(state.remaining == 59)
    }

    @Test("Requests inside the budget are not delayed")
    func fastPath() async throws {
        let limiter = RateLimiter(limit: 60, safetyMargin: 5)
        let start = ContinuousClock.now
        for _ in 0..<10 { try await limiter.waitForSlot() }
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(250))
        let state = await limiter.state
        #expect(state.requestsInWindow == 10)
    }

    @Test("Local budget stops at limit minus safety margin")
    func budgetHoldsBackTheMargin() async throws {
        let limiter = RateLimiter(limit: 10, safetyMargin: 4)
        for _ in 0..<6 { try await limiter.waitForSlot() }

        // The 7th slot would exceed limit - margin, so it must wait for the window to roll.
        let task = Task { try await limiter.waitForSlot() }
        try await Task.sleep(for: .milliseconds(200))
        let state = await limiter.state
        #expect(state.requestsInWindow == 6, "the extra request is parked, not recorded")
        task.cancel()
    }

    @Test("Backoff grows exponentially and honours Retry-After")
    func backoffDelay() async {
        let limiter = RateLimiter(limit: 60, safetyMargin: 5, baseBackoff: 1, maximumBackoff: 60)

        let first = await limiter.backoffDelay(retryAfter: nil, attempt: 0)
        let third = await limiter.backoffDelay(retryAfter: nil, attempt: 2)
        #expect(first >= 0.8 && first <= 1.2)
        #expect(third >= 3.2 && third <= 4.8)

        let honoured = await limiter.backoffDelay(retryAfter: 30, attempt: 0)
        #expect(honoured == 30, "a longer Retry-After wins over the computed delay")

        let capped = await limiter.backoffDelay(retryAfter: nil, attempt: 20)
        #expect(capped <= 60)

        let serverSays = await limiter.backoffDelay(retryAfter: 120, attempt: 0)
        #expect(serverSays == 120, "the cap bounds the computed delay, not the server's Retry-After")
    }

    @Test("A success that lands during a 429 block does not lift it")
    func lateSuccessKeepsTheBlock() async throws {
        let limiter = RateLimiter(limit: 60, safetyMargin: 5, baseBackoff: 0.01, maximumBackoff: 0.02)
        let blocked = Task { try await limiter.noteRateLimited(retryAfter: 0.5, attempt: 0) }
        try await Task.sleep(for: .milliseconds(50))

        // The answer to a request sent before the 429.
        await limiter.update(from: try response(limit: "60", used: "30", remaining: "30"))
        guard case .wait = await limiter.decision(at: Date()) else {
            Issue.record("the block must hold until its deadline")
            return
        }
        _ = try await blocked.value
    }
}

@Suite("RateLimiter deadlocks")
struct RateLimiterDeadlockTests {
    private func response(remaining: Int, status: Int = 200) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(
            url: URL(string: "https://api.discogs.com/oauth/identity")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "X-Discogs-Ratelimit": "60",
                "X-Discogs-Ratelimit-Used": String(60 - remaining),
                "X-Discogs-Ratelimit-Remaining": String(remaining),
            ]
        ))
    }

    @Test("A low remaining count stops gating once its window has passed")
    func staleRemainingExpires() async throws {
        let limiter = RateLimiter(limit: 60, safetyMargin: 5)
        await limiter.update(from: try response(remaining: 1))

        let observed = Date()
        // Inside the window the reading still applies, and the wait is bounded rather than a
        // fixed retry that could repeat forever.
        let duringWindow = await limiter.decision(at: observed.addingTimeInterval(5))
        #expect(duringWindow != .send)
        if case .wait(let until) = duringWindow {
            #expect(until.timeIntervalSince(observed) <= 61)
        }

        // Past the window the reading is meaningless: a request must go out to refresh it.
        let afterWindow = await limiter.decision(at: observed.addingTimeInterval(61))
        #expect(afterWindow == .send, "a stale reading must not gate requests forever")
    }

    @Test("A 429 does not leave the limiter permanently blocked")
    func rateLimitedThenRecovers() async throws {
        let limiter = RateLimiter(limit: 60, safetyMargin: 5, baseBackoff: 0.01, maximumBackoff: 0.02)
        // A 429 reports no remaining requests; that count must not outlive the backoff.
        await limiter.update(from: try response(remaining: 0, status: 429))
        try await limiter.noteRateLimited(retryAfter: nil, attempt: 0)

        let state = await limiter.state
        #expect(state.remaining == nil, "counts from the 429 describe a window that has passed")

        let decision = await limiter.decision(at: Date())
        #expect(decision == .send, "the next request must be allowed to refresh the headers")
    }

    @Test("waitForSlot returns promptly after a 429 rather than hanging")
    func waitForSlotRecoversAfterRateLimit() async throws {
        let limiter = RateLimiter(limit: 60, safetyMargin: 5, baseBackoff: 0.01, maximumBackoff: 0.02)
        await limiter.update(from: try response(remaining: 0, status: 429))
        try await limiter.noteRateLimited(retryAfter: nil, attempt: 0)

        let start = ContinuousClock.now
        try await limiter.waitForSlot()
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test("An exhausted budget still waits, and only until the window rolls")
    func exhaustedBudgetWaitsBounded() async throws {
        let limiter = RateLimiter(limit: 10, safetyMargin: 4)
        let start = Date()
        for _ in 0..<6 { try await limiter.waitForSlot() }

        let decision = await limiter.decision(at: start)
        guard case .wait(let until) = decision else {
            Issue.record("expected a wait once the budget is spent")
            return
        }
        #expect(until.timeIntervalSince(start) <= 61)
    }
}
