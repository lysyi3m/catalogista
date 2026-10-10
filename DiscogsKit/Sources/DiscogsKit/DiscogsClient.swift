import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Async client for the Discogs API v2, authenticated with a Personal Access Token.
///
/// Every request goes through a shared `RateLimiter`, so several clients built from the same
/// limiter stay inside one budget. The token is held in memory only and is never logged.
public struct DiscogsClient: Sendable {
    public let configuration: DiscogsConfiguration
    public let rateLimiter: RateLimiter

    private let token: String
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(
        token: String,
        configuration: DiscogsConfiguration,
        session: URLSession = .shared,
        rateLimiter: RateLimiter? = nil
    ) {
        self.token = token
        self.configuration = configuration
        self.session = session
        self.rateLimiter = rateLimiter ?? RateLimiter(safetyMargin: configuration.rateLimitSafetyMargin)
        self.decoder = DiscogsClient.makeDecoder()
    }

    // MARK: - Identity

    /// `GET /oauth/identity` — resolves the username the token belongs to. Also the token check
    /// used by first-run setup.
    public func identity() async throws -> Identity {
        try await get(path: "/oauth/identity")
    }

    // MARK: - Folders

    /// `GET /users/{user}/collection/folders`
    public func folders(user: String) async throws -> [Folder] {
        let list: FolderList = try await get(path: "/users/\(escape(user))/collection/folders")
        return list.folders
    }

    /// `GET /users/{user}/collection/fields` — the custom fields every copy carries values for.
    public func customFields(user: String) async throws -> [CustomField] {
        let list: CustomFieldList = try await get(path: "/users/\(escape(user))/collection/fields")
        return list.fields
    }

    // MARK: - Releases

    /// `GET /releases/{id}` — the full release, including tracklist and full-size images.
    public func release(id: Int) async throws -> Release {
        try await get(path: "/releases/\(id)")
    }

    // MARK: - Collection

    /// One page of `GET /users/{user}/collection/folders/{folder_id}/releases`.
    ///
    /// - Parameter page: 1-based, as Discogs numbers pages.
    public func collectionPage(
        user: String,
        folderID: Int = DiscogsFolder.all,
        page: Int = 1,
        perPage: Int? = nil,
        sort: CollectionSort? = nil,
        order: DiscogsSortOrder? = nil
    ) async throws -> CollectionPage {
        var query = [
            URLQueryItem(name: "page", value: String(max(page, 1))),
            URLQueryItem(name: "per_page", value: String(perPage ?? configuration.perPage)),
        ]
        if let sort { query.append(URLQueryItem(name: "sort", value: sort.rawValue)) }
        if let order { query.append(URLQueryItem(name: "sort_order", value: order.rawValue)) }

        return try await get(
            path: "/users/\(escape(user))/collection/folders/\(folderID)/releases",
            query: query
        )
    }

    /// Streams the collection page by page, so a caller can render progressively during the first
    /// sync instead of waiting for the whole collection.
    ///
    /// - Important: `AsyncThrowingStream` answers cancellation by finishing, not by throwing. A
    ///   `for try await` over this stream therefore ends normally when the consuming task is
    ///   cancelled, having yielded however many pages it managed — which is indistinguishable
    ///   from a collection that really is that size. Every consumer must call
    ///   `Task.checkCancellation()` **after** the loop before treating the result as the whole
    ///   collection.
    public func collectionPages(
        user: String,
        folderID: Int = DiscogsFolder.all,
        perPage: Int? = nil,
        sort: CollectionSort? = nil,
        order: DiscogsSortOrder? = nil
    ) -> AsyncThrowingStream<CollectionPage, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var page = 1
                    while true {
                        try Task.checkCancellation()
                        let result = try await collectionPage(
                            user: user,
                            folderID: folderID,
                            page: page,
                            perPage: perPage,
                            sort: sort,
                            order: order
                        )
                        continuation.yield(result)
                        guard result.pagination.hasNextPage else { break }
                        page += 1
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Every item in the collection, paging until Discogs reports the last page.
    public func allCollectionItems(
        user: String,
        folderID: Int = DiscogsFolder.all,
        perPage: Int? = nil,
        sort: CollectionSort? = nil,
        order: DiscogsSortOrder? = nil
    ) async throws -> [CollectionItem] {
        var items: [CollectionItem] = []
        for try await page in collectionPages(
            user: user, folderID: folderID, perPage: perPage, sort: sort, order: order
        ) {
            items.append(contentsOf: page.releases)
        }
        // A cancelled stream finishes rather than throwing, so without this a caller would be
        // handed a short list as though it were the whole collection.
        try Task.checkCancellation()
        return items
    }

    // MARK: - Search

    /// `GET /database/search` restricted to releases, which is what the add flow picks from.
    public func searchReleases(
        query: String,
        page: Int = 1,
        perPage: Int? = nil
    ) async throws -> SearchPage {
        try await get(path: "/database/search", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "page", value: String(max(page, 1))),
            URLQueryItem(name: "per_page", value: String(perPage ?? configuration.perPage)),
        ])
    }

    // MARK: - Collection writes

    /// `POST /users/{user}/collection/folders/{folder_id}/releases/{release_id}`
    ///
    /// Adds a copy and returns the `instance_id` Discogs assigned it. The target must be a real
    /// folder: folder 0 is the read-only "All" pseudo-folder.
    @discardableResult
    public func addToCollection(
        user: String,
        folderID: Int = DiscogsFolder.uncategorized,
        releaseID: Int
    ) async throws -> CollectionAddition {
        try await perform(
            method: "POST",
            path: "/users/\(escape(user))/collection/folders/\(folderID)/releases/\(releaseID)",
            // Adding a copy is not idempotent: a retry would add a second one.
            isIdempotent: false
        )
    }

    /// `DELETE …/collection/folders/{folder_id}/releases/{release_id}/instances/{instance_id}`
    ///
    /// Removes one copy. Keyed by `instanceID`, so owning two copies of the same release stays
    /// unambiguous.
    public func removeFromCollection(
        user: String,
        folderID: Int,
        releaseID: Int,
        instanceID: Int
    ) async throws {
        try await performIgnoringResponse(
            method: "DELETE",
            path: "/users/\(escape(user))/collection/folders/\(folderID)/releases/\(releaseID)/instances/\(instanceID)",
            // Removing a specific instance twice is harmless: the second call finds nothing.
            isIdempotent: true
        )
    }

    /// `POST …/collection/folders/{folder_id}/releases/{release_id}/instances/{instance_id}`
    ///
    /// Moves one copy to `toFolderID`. A copy is in exactly one folder, so this replaces its folder
    /// rather than adding another. The path names the folder the copy is in now.
    public func moveInstance(
        user: String,
        fromFolderID: Int,
        releaseID: Int,
        instanceID: Int,
        toFolderID: Int
    ) async throws {
        try await performIgnoringResponse(
            method: "POST",
            path: "/users/\(escape(user))/collection/folders/\(fromFolderID)/releases/\(releaseID)/instances/\(instanceID)",
            body: ["folder_id": toFolderID],
            // Moving a copy to the folder it is already in changes nothing.
            isIdempotent: true
        )
    }

    // MARK: - Request plumbing

    private func get<Response: Decodable>(
        path: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        try await perform(method: "GET", path: path, query: query)
    }

    private func perform<Response: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        isIdempotent: Bool = true
    ) async throws -> Response {
        let request = try makeRequest(method: method, path: path, query: query)
        let data = try await send(request, isIdempotent: isIdempotent)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw DiscogsError.decoding(underlying: error)
        }
    }

    /// Sends a request whose response body is not needed.
    private func performIgnoringResponse(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: [String: Int]? = nil,
        isIdempotent: Bool = true
    ) async throws {
        _ = try await send(
            try makeRequest(method: method, path: path, query: query, body: body),
            isIdempotent: isIdempotent
        )
    }

    private func makeRequest(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: [String: Int]? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw DiscogsError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw DiscogsError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    /// Sends a request through the throttle, retrying with backoff where that is safe.
    ///
    /// A `429` is always safe to retry: the request was refused, not performed. A `5xx` is not,
    /// unless the request is idempotent — the server may have applied it and failed afterwards,
    /// and repeating an add would create a second copy.
    private func send(_ request: URLRequest, isIdempotent: Bool) async throws -> Data {
        var attempt = 0
        while true {
            try await rateLimiter.waitForSlot()

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DiscogsError.transport(underlying: error)
            }

            guard let http = response as? HTTPURLResponse else {
                throw DiscogsError.http(status: -1, message: "Response was not HTTP.")
            }
            await rateLimiter.update(from: http)

            switch http.statusCode {
            case 200...299:
                return data

            case 429:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
                guard attempt < configuration.maxRetries else {
                    throw DiscogsError.rateLimited(retryAfter: retryAfter)
                }
                try await rateLimiter.noteRateLimited(retryAfter: retryAfter, attempt: attempt)
                attempt += 1

            case 500...599:
                guard isIdempotent, attempt < configuration.maxRetries else {
                    throw DiscogsError.http(status: http.statusCode, message: message(from: data))
                }
                try await rateLimiter.backOff(attempt: attempt)
                attempt += 1

            case 401, 403:
                // Discogs' text here ("Invalid consumer token. Please register an app before
                // making requests.") speaks to API developers, not to the person holding the
                // token, so the error carries no message and reads as a plain rejection.
                throw DiscogsError.unauthorized(message: nil)

            case 404:
                throw DiscogsError.notFound(message: message(from: data))

            default:
                throw DiscogsError.http(status: http.statusCode, message: message(from: data))
            }
        }
    }

    private func message(from data: Data) -> String? {
        try? JSONDecoder().decode(DiscogsErrorPayload.self, from: data).message
    }

    private func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    /// Decoder configured for Discogs payloads. Public so the app's tests can build models from
    /// recorded JSON without duplicating the date strategy.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // Discogs sends ISO-8601 with a UTC offset, sometimes with fractional seconds.
        // ISO8601FormatStyle accepts both and, unlike ISO8601DateFormatter, is Sendable.
        let style = Date.ISO8601FormatStyle()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = try? style.parse(raw) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unrecognized date format: \(raw)"
                    )
                )
            }
            return date
        }
        return decoder
    }
}
