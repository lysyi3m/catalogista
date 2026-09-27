import Foundation
import Testing
@testable import CatalogistaKit

@Suite("TokenStore", .serialized)
struct TokenStoreTests {
    /// A throwaway service name per test, so nothing here can touch the real stored token.
    private func makeStore() -> TokenStore {
        TokenStore(service: "com.mlkshkvch.catalogista.tests.\(UUID().uuidString)", account: "discogs-pat")
    }

    @Test("A token round-trips through the Keychain")
    func roundTrip() throws {
        let store = makeStore()
        defer { try? store.delete() }

        #expect(try store.read() == nil, "a fresh service holds nothing")
        try store.save("example-token")
        #expect(try store.read() == "example-token")
    }

    @Test("Saving twice replaces the token rather than adding a second item")
    func overwrite() throws {
        let store = makeStore()
        defer { try? store.delete() }

        try store.save("first")
        try store.save("second")
        #expect(try store.read() == "second")
    }

    @Test("Delete removes the token and is safe to call when nothing is stored")
    func delete() throws {
        let store = makeStore()

        try store.save("example-token")
        try store.delete()
        #expect(try store.read() == nil)
        try store.delete()
    }
}
