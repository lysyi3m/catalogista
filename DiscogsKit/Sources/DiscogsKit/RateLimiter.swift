import Foundation

/// Central throttle for every Discogs request.
///
/// Discogs enforces 60 requests per minute for an authenticated token as a moving 60-second window,
/// and reports the state on every response via `X-Discogs-Ratelimit*`. The limiter combines both
/// signals: it tracks its own sends locally so a burst is paced before the first response arrives,
/// and it trusts the server headers once they exist. A `429` blocks every caller for a backoff
/// interval rather than only the request that hit it.
public actor RateLimiter {
    public struct State: Sendable, Hashable {
        public var limit: Int
        public var used: Int?
        public var remaining: Int?
        /// Requests this limiter has issued inside the current local window.
        public var requestsInWindow: Int
    }

    /// Width of the Discogs moving window.
    private static let window: TimeInterval = 60

    private let safetyMargin: Int
    private let baseBackoff: TimeInterval
    private let maximumBackoff: TimeInterval

    private var limit: Int
    private var used: Int?
    private var remaining: Int?
    /// When `remaining` was last read from a response. The value describes a moving 60-second
    /// window, so it stops being meaningful once that window has passed.
    private var remainingObservedAt: Date?
    private var sendTimestamps: [Date] = []
    /// Set after a 429; gates every caller until it passes.
    private var blockedUntil: Date?

    /// What `waitForSlot` should do at a given instant. Separated from the waiting itself so the
    /// decision can be tested without sleeping.
    enum Decision: Equatable {
        case send
        case wait(until: Date)
    }

    public init(
        limit: Int = 60,
        safetyMargin: Int = 5,
        baseBackoff: TimeInterval = 1,
        maximumBackoff: TimeInterval = 60
    ) {
        self.limit = max(limit, 1)
        self.safetyMargin = max(safetyMargin, 0)
        self.baseBackoff = baseBackoff
        self.maximumBackoff = maximumBackoff
    }

    public var state: State {
        State(limit: limit, used: used, remaining: remaining, requestsInWindow: sendTimestamps.count)
    }

    /// Suspends until a request may be sent, then records the send.
    public func waitForSlot() async throws {
        while true {
            switch decision(at: Date()) {
            case .send:
                record(at: Date())
                return
            case .wait(let until):
                try await sleep(until: until)
            }
        }
    }

    /// Decides whether a request may go out now.
    ///
    /// Every wait this returns is bounded, and each one ends in a state closer to `.send`: local
    /// sends age out of the window, and a server-reported `remaining` expires with the window it
    /// describes. Without that expiry a stale low `remaining` is self-perpetuating — nothing is
    /// sent, so no response arrives to correct it.
    func decision(at now: Date) -> Decision {
        if let blockedUntil, blockedUntil > now {
            return .wait(until: blockedUntil)
        }

        prune(now: now)

        let budget = max(1, limit - safetyMargin)
        if sendTimestamps.count >= budget, let oldest = sendTimestamps.first {
            return .wait(until: oldest.addingTimeInterval(Self.window))
        }

        // The server reported a count inside the safety margin. Honour it only while the reading
        // still describes the current window.
        if let remaining, remaining <= safetyMargin,
           let observedAt = remainingObservedAt,
           now.timeIntervalSince(observedAt) < Self.window {
            // Wait for the oldest local send to age out, or failing that for the reading itself to
            // expire, after which a request goes out and refreshes it.
            let wake = sendTimestamps.first?.addingTimeInterval(Self.window)
                ?? observedAt.addingTimeInterval(Self.window)
            return .wait(until: wake)
        }

        return .send
    }

    private func record(at now: Date) {
        sendTimestamps.append(now)
        // Decrement optimistically so concurrent callers see the cost of in-flight requests
        // before their responses land.
        if let current = remaining { remaining = max(current - 1, 0) }
    }

    /// Absorbs the rate-limit headers from a response.
    ///
    /// A 429 block is left alone: a success that arrives now may answer a request sent before the
    /// 429, and says nothing about whether the server's block is over. The block ends at its
    /// deadline.
    public func update(from response: HTTPURLResponse) {
        if let value = response.value(forHTTPHeaderField: "X-Discogs-Ratelimit"),
           let parsed = Int(value.trimmingCharacters(in: .whitespaces)), parsed > 0 {
            limit = parsed
        }
        if let value = response.value(forHTTPHeaderField: "X-Discogs-Ratelimit-Used"),
           let parsed = Int(value.trimmingCharacters(in: .whitespaces)) {
            used = parsed
        }
        if let value = response.value(forHTTPHeaderField: "X-Discogs-Ratelimit-Remaining"),
           let parsed = Int(value.trimmingCharacters(in: .whitespaces)) {
            remaining = parsed
            remainingObservedAt = Date()
        }
    }

    /// Records a 429 and blocks all callers for the backoff interval. Returns the delay applied.
    @discardableResult
    public func noteRateLimited(retryAfter: TimeInterval?, attempt: Int) async throws -> TimeInterval {
        let delay = backoffDelay(retryAfter: retryAfter, attempt: attempt)
        let until = Date().addingTimeInterval(delay)
        if (blockedUntil ?? .distantPast) < until { blockedUntil = until }
        // Local send history is kept: the sends in it are still inside the server's moving window,
        // and forgetting them would let a burst go out the moment a short block ends.
        try await sleep(until: until)
        // The backoff has passed, so the counts that came with the 429 describe a window that is
        // over. Keeping them would gate every later request on a reading that can never refresh.
        remaining = nil
        used = nil
        remainingObservedAt = nil
        return delay
    }

    /// Backoff for a retryable server failure, without the shared block a 429 imposes.
    public func backOff(attempt: Int) async throws {
        try await sleep(until: Date().addingTimeInterval(backoffDelay(retryAfter: nil, attempt: attempt)))
    }

    func backoffDelay(retryAfter: TimeInterval?, attempt: Int) -> TimeInterval {
        let exponential = min(baseBackoff * pow(2, Double(max(attempt, 0))), maximumBackoff)
        // Jitter spreads retries when several requests are throttled together.
        let jittered = min(exponential * Double.random(in: 0.8...1.2), maximumBackoff)
        // The cap bounds our own guess, never the server's: retrying before its Retry-After only
        // earns another 429.
        return max(jittered, retryAfter ?? 0)
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.window)
        sendTimestamps.removeAll { $0 <= cutoff }
    }

    private func sleep(until date: Date) async throws {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return }
        try await Task.sleep(for: .seconds(interval))
    }
}
