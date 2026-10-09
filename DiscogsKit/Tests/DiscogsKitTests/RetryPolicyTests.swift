import Foundation
import Testing
@testable import DiscogsKit

/// Serves canned responses and counts how many times each path was requested.
final class CountingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var lastPath: String?
    nonisolated(unsafe) private static var lastBody: Data?
    private static let lock = NSLock()

    static func configure(status: Int, body: Data) {
        lock.withLock {
            counts = [:]
            self.status = status
            self.body = body
        }
    }

    static func count(forMethod method: String) -> Int {
        lock.withLock { counts[method] ?? 0 }
    }

    /// The path and body of the last request. A URLProtocol sees the body as a stream.
    static func lastRequest() -> (path: String?, body: Data?) {
        lock.withLock { (lastPath, lastBody) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "?"
        let sent = request.httpBodyStream.map(Self.read)
        let (status, body) = Self.lock.withLock { () -> (Int, Data) in
            Self.counts[method, default: 0] += 1
            Self.lastPath = request.url?.path
            Self.lastBody = sent
            return (Self.status, Self.body)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite("Retry policy", .serialized)
struct RetryPolicyTests {
    private func makeClient(maxRetries: Int = 3) -> DiscogsClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingProtocol.self]
        return DiscogsClient(
            token: "test",
            configuration: DiscogsConfiguration(
                userAgent: "Test/1.0 +test",
                rateLimitSafetyMargin: 0,
                maxRetries: maxRetries
            ),
            session: URLSession(configuration: configuration),
            rateLimiter: RateLimiter(limit: 60, safetyMargin: 0, baseBackoff: 0.01, maximumBackoff: 0.02)
        )
    }

    @Test("A 5xx never retries an add, because Discogs may already have applied it")
    func addIsNotRetriedOnServerError() async throws {
        CountingProtocol.configure(status: 503, body: Data("{}".utf8))
        let client = makeClient()

        await #expect(throws: DiscogsError.self) {
            try await client.addToCollection(user: "emil", folderID: 1, releaseID: 1)
        }
        #expect(CountingProtocol.count(forMethod: "POST") == 1, "an add must be sent exactly once")
    }

    @Test("A 5xx does retry a read, which is safe to repeat")
    func getIsRetriedOnServerError() async throws {
        CountingProtocol.configure(status: 503, body: Data("{}".utf8))
        let client = makeClient(maxRetries: 2)

        await #expect(throws: DiscogsError.self) { try await client.identity() }
        #expect(CountingProtocol.count(forMethod: "GET") == 3, "the first attempt plus two retries")
    }

    @Test("A 5xx retries a delete: removing the same instance twice is harmless")
    func deleteIsRetriedOnServerError() async throws {
        CountingProtocol.configure(status: 503, body: Data("{}".utf8))
        let client = makeClient(maxRetries: 2)

        await #expect(throws: DiscogsError.self) {
            try await client.removeFromCollection(user: "emil", folderID: 1, releaseID: 1, instanceID: 2)
        }
        #expect(CountingProtocol.count(forMethod: "DELETE") == 3)
    }

    @Test("A rejected token reads as one short line, not Discogs' developer-facing text")
    func rejectedTokenMessage() async throws {
        CountingProtocol.configure(
            status: 401,
            body: Data(#"{"message": "Invalid consumer token. Please register an app before making requests."}"#.utf8)
        )
        let client = makeClient()

        let error = await #expect(throws: DiscogsError.self) { try await client.identity() }
        #expect(error?.isUnauthorized == true)
        #expect(error?.errorDescription == "Discogs rejected the token.")
    }

    @Test("A successful add is sent once and returns its instance id")
    func successfulAdd() async throws {
        CountingProtocol.configure(status: 201, body: Data(#"{"instance_id": 99}"#.utf8))
        let client = makeClient()

        let addition = try await client.addToCollection(user: "emil", folderID: 1, releaseID: 1)
        #expect(addition.instanceID == 99)
        #expect(CountingProtocol.count(forMethod: "POST") == 1)
    }

    @Test("A move names the current folder in the path and the new one in the body")
    func moveRequest() async throws {
        CountingProtocol.configure(status: 204, body: Data())
        let client = makeClient()

        try await client.moveInstance(user: "emil", fromFolderID: 1, releaseID: 500, instanceID: 77, toFolderID: 4)

        let sent = CountingProtocol.lastRequest()
        #expect(sent.path == "/users/emil/collection/folders/1/releases/500/instances/77")
        let body = try JSONSerialization.jsonObject(with: try #require(sent.body)) as? [String: Int]
        #expect(body == ["folder_id": 4])
    }

    @Test("A move is retried after a 5xx, since repeating it changes nothing")
    func moveRetries() async throws {
        CountingProtocol.configure(status: 503, body: Data(#"{"message":"Unavailable"}"#.utf8))
        let client = makeClient(maxRetries: 2)

        await #expect(throws: DiscogsError.self) {
            try await client.moveInstance(user: "emil", fromFolderID: 1, releaseID: 500, instanceID: 77, toFolderID: 4)
        }
        #expect(CountingProtocol.count(forMethod: "POST") == 3)
    }
}
