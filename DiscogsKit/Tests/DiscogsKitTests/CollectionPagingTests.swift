import Foundation
import Testing
@testable import DiscogsKit

@Suite("Collection paging", .serialized)
struct CollectionPagingTests {
    /// Serves a two-page collection, slowly enough that a cancellation lands mid-stream.
    final class SlowPagingProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value ?? "1"
            let body = """
            {"pagination":{"page":\(page),"pages":2,"per_page":1,"items":2},
             "releases":[{"id":500,"instance_id":\(page),"folder_id":1,"rating":0,
             "basic_information":{"id":500,"title":"Remain In Light","year":1980,
             "artists":[{"name":"Talking Heads","join":""}],
             "labels":[],"formats":[],"genres":[],"styles":[]}}]}
            """
            Thread.sleep(forTimeInterval: 0.2)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeClient() -> DiscogsClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowPagingProtocol.self]
        return DiscogsClient(
            token: "test",
            configuration: DiscogsConfiguration(userAgent: "Catalogista/1.0 +tests", perPage: 1),
            session: URLSession(configuration: configuration)
        )
    }

    @Test("The whole collection is returned when nothing interrupts it")
    func fetchesEveryPage() async throws {
        let items = try await makeClient().allCollectionItems(user: "tester")
        #expect(items.count == 2)
    }

    @Test("A cancelled fetch throws rather than returning a short collection")
    func cancellationThrows() async throws {
        let client = makeClient()
        let task = Task { try await client.allCollectionItems(user: "tester") }
        // Long enough to be mid-stream, short enough to be well inside the two page loads.
        try await Task.sleep(for: .milliseconds(250))
        task.cancel()

        // A cancelled stream finishes instead of throwing. Returning the pages it happened to get
        // would present a partial collection as the whole one, and callers reconcile against it.
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
