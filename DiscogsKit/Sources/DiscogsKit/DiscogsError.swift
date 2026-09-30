import Foundation

public enum DiscogsError: Error, Sendable {
    /// The token was rejected (401) or lacks access to the resource (403).
    case unauthorized(message: String?)
    case notFound(message: String?)
    /// Rate limited and still failing after the configured retries.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other non-2xx response.
    case http(status: Int, message: String?)
    case decoding(underlying: any Error)
    case transport(underlying: any Error)
    case invalidURL
}

extension DiscogsError {
    /// True when the request failed for lack of a working connection. The app stays usable from
    /// cache in this state, so it is worth distinguishing from a server-side failure.
    public var isOffline: Bool {
        guard case .transport(let underlying) = self,
              let urlError = underlying as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dataNotAllowed, .timedOut, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    public var isRateLimited: Bool {
        if case .rateLimited = self { return true }
        return false
    }

    /// True when Discogs has no such resource. On a delete that is the desired end state, not a
    /// failure: the copy is already gone.
    public var isNotFound: Bool {
        if case .notFound = self { return true }
        if case .http(let status, _) = self, status == 404 { return true }
        return false
    }

    /// True when the token is missing, wrong, or revoked, so the fix is to re-enter it.
    public var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    /// Whether Discogs definitely did not apply a write that failed with this error.
    ///
    /// A write is not a read: rolling the local change back is only safe when the server is known
    /// to have rejected it. A request that timed out, lost its connection, or met a 5xx may well
    /// have been applied before the answer went missing, and a caller that assumes otherwise will
    /// hide a copy the user really owns — or offer a retry that adds a second one.
    public var didNotReachDiscogs: Bool {
        switch self {
        case .unauthorized, .notFound, .invalidURL:
            // Answered, and the answer was no. An invalid URL is never sent.
            return true
        case .rateLimited:
            // Refused without being processed, and only after the retries are spent.
            return true
        case .http(let status, _):
            // 4xx is a rejection; 5xx may have been applied before it failed.
            return (400..<500).contains(status)
        case .decoding:
            // A response arrived and could not be read. The write may well have succeeded.
            return false
        case .transport:
            return false
        }
    }
}

extension DiscogsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized(let message):
            return message ?? "Discogs rejected the token."
        case .notFound(let message):
            return message ?? "The requested item was not found."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                let seconds = Int(retryAfter.rounded())
                let unit = seconds == 1 ? "second" : "seconds"
                return "Discogs is temporarily limiting requests. Try again in \(seconds) \(unit)."
            }
            return "Discogs is temporarily limiting requests. Try again shortly."
        case .http(let status, let message):
            return message ?? "Discogs returned HTTP \(status)."
        case .decoding:
            return "Could not read the Discogs response."
        case .transport:
            return isOffline
                ? "No connection to Discogs."
                : "Could not reach Discogs."

        case .invalidURL:
            return "The request URL is invalid."
        }
    }
}

/// Discogs returns `{"message": "..."}` on most errors.
struct DiscogsErrorPayload: Decodable {
    let message: String
}
