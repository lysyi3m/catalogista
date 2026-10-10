import DiscogsKit
import Foundation
import SwiftData

/// Single owner of the app's long-lived services.
///
/// One `DiscogsClient`, and therefore one `RateLimiter`, is shared by everything that talks to the
/// API, so the 60/min budget is accounted for in one place. The image cache is deliberately outside
/// that budget: the CDN does not share it.
@MainActor
@Observable
public final class AppServices {
    public let modelContainer: ModelContainer
    let store: CollectionStore
    let imageCache: ImageCache
    /// Menu commands, routed to whichever view owns the matching state.
    public let commands = AppCommands()

    private let tokenStore: TokenStore
    /// How API requests are sent. Ephemeral, so no response outlives the process in a URL cache or
    /// cookie store: disconnecting has to leave nothing of the collection behind (`PRIVACY.md`).
    private let sessionConfiguration: URLSessionConfiguration

    /// Bumped when the account disconnects. Work that started under an earlier value finished for
    /// an account that is gone, and must not write to the cache. Checked on the main actor before
    /// each write, which sign-out also runs on.
    private(set) var accountGeneration = 0

    /// Bumped whenever a copy changes folder on this device, so views that count copies per folder
    /// know to count again. A sync is the other way a copy changes folder, and has its own signal.
    private(set) var folderRevision = 0

    func noteFolderChange() { folderRevision += 1 }

    /// Bumped when covers land on disk outside a view's own load: the sync's prefetch, which also
    /// refills the cache after Reset Cache. A cover that failed, or that shows art from before a
    /// reset, loads again.
    private(set) var imageRevision = 0

    func noteImagesChanged() { imageRevision += 1 }

    /// Copies with a move or removal under way. Every editor claims a copy here first, so a removal
    /// cannot start from the grid while the record page is still moving that copy, acting on a
    /// folder Discogs has not confirmed.
    private var copiesInFlight: Set<Int> = []

    /// False when another change to the copy is still under way.
    func claimCopy(_ instanceID: Int) -> Bool { copiesInFlight.insert(instanceID).inserted }

    func releaseCopy(_ instanceID: Int) { copiesInFlight.remove(instanceID) }

    /// Non-nil once a token is available. First-run setup sets it; until then the app is in its
    /// no-token state and browses whatever the cache already holds.
    private(set) var client: DiscogsClient?

    var hasToken: Bool { client != nil }

    /// The Discogs username this token belongs to, for display. Resolved at sign-in and remembered.
    private(set) var accountUsername: String?

    /// The stored token with its middle replaced, so Settings can show *which* token is in use
    /// without putting the secret on screen. The full value never leaves the Keychain.
    private(set) var maskedToken: String?

    /// Remembered so collection writes do not spend a request on `/oauth/identity` every time.
    @ObservationIgnored private var cachedUsername: String?
    private static let usernameKey = "discogsUsername"

    /// The username the token belongs to, resolved once and remembered.
    func username() async throws -> String {
        if let cachedUsername { return cachedUsername }
        if let stored = UserDefaults.standard.string(forKey: Self.usernameKey), !stored.isEmpty {
            cachedUsername = stored
            return stored
        }
        guard let client else { throw DiscogsError.unauthorized(message: "Connect to Discogs to continue.") }
        let generation = accountGeneration
        let identity = try await client.identity()
        // The account disconnected while the lookup was out. Remembered now, the old name would
        // outlive sign-out, or replace the next account's.
        guard accountGeneration == generation else { throw CancellationError() }
        rememberUsername(identity.username)
        return identity.username
    }

    /// Also called after every sync, which resolves the username anyway. An install that has a
    /// token but no stored name — the Discogs credit's link needs one — picks it up there.
    func rememberUsername(_ username: String) {
        cachedUsername = username
        accountUsername = username
        UserDefaults.standard.set(username, forKey: Self.usernameKey)
    }

    public convenience init(modelContainer: ModelContainer) {
        self.init(modelContainer: modelContainer, tokenStore: TokenStore(), imageCache: ImageCache())
    }

    /// Full initializer, kept internal so the public surface does not expose the services it wires
    /// together. Tests use it to inject a temporary cache directory or Keychain account.
    init(
        modelContainer: ModelContainer,
        tokenStore: TokenStore = TokenStore(),
        imageCache: ImageCache = ImageCache(),
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.modelContainer = modelContainer
        self.tokenStore = tokenStore
        self.imageCache = imageCache
        self.sessionConfiguration = sessionConfiguration
        self.store = CollectionStore(modelContainer: modelContainer)
        let storedToken = (try? tokenStore.read()).flatMap { $0 }
        self.client = storedToken.map { Self.makeClient(token: $0, configuration: sessionConfiguration) }
        self.maskedToken = storedToken.map(Self.mask)
        self.accountUsername = UserDefaults.standard.string(forKey: Self.usernameKey)
    }

    /// Keeps the first and last few characters, which is enough to tell two tokens apart.
    nonisolated static func mask(_ token: String) -> String {
        guard token.count > 12 else { return String(repeating: "•", count: max(token.count, 8)) }
        return "\(token.prefix(4))\(String(repeating: "•", count: 12))\(token.suffix(4))"
    }

    /// Moves the cache's store files to the Trash, so a store that will not open can be rebuilt by
    /// the next sync. The Keychain token is not touched. To the Trash rather than deleted: the
    /// files are only a cache, but a user may still want them back.
    nonisolated public static func discardModelStore() throws {
        let store = ModelConfiguration().url
        let folder = store.deletingLastPathComponent()
        let name = store.lastPathComponent
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(name) }
        for file in files {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
        // The new store is empty, so the collection is not fresh however recent the last sync
        // was. Without this the launch sync is skipped and the app shows nothing for hours.
        UserDefaults.standard.removeObject(forKey: SyncController.lastSyncedKey)
    }

    nonisolated public static func makeModelContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([CachedCollectionItem.self, CachedReleaseDetail.self, CachedFolder.self, CachedField.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Validates a token against `/oauth/identity` before storing it, so a typo never reaches the
    /// Keychain.
    @discardableResult
    func signIn(token: String) async throws -> Identity {
        let candidate = Self.makeClient(token: token, configuration: sessionConfiguration)
        let generation = accountGeneration
        let identity = try await candidate.identity()
        // Disconnected while the check was out: that disconnect is the later request, and it wins.
        // Checked and applied on the main actor with no suspension between, so no sign-out can
        // land in between.
        guard accountGeneration == generation else { throw CancellationError() }
        try tokenStore.save(token)
        client = candidate
        maskedToken = Self.mask(token)
        rememberUsername(identity.username)
        return identity
    }

    /// Empties the local cache without touching the token, so the next sync rebuilds from scratch.
    func resetCache() async throws {
        try await store.removeAll()
        try await imageCache.removeAll()
    }

    /// Disconnects the account and leaves the app as it was before first run: no token, no cached
    /// collection, no cover art.
    func signOut() async throws {
        // Order matters. Dropping the client first means nothing can build a new syncer while this
        // runs; cancelling then drains the one already in flight. Clearing the cache before either
        // would let that sync write the old account's records back into the cleared cache.
        //
        // The cache and Keychain steps can both throw, and a half-signed-out app — no client, but
        // the token still stored — is a state with no way out through the UI. If either fails the
        // client comes back, so the app is either signed in or signed out and never between.
        let previousClient = client
        client = nil
        accountGeneration += 1
        await syncController.cancelAndWait()
        do {
            try await resetCache()
            try tokenStore.delete()
        } catch {
            client = previousClient
            throw error
        }
        cachedUsername = nil
        accountUsername = nil
        maskedToken = nil
        UserDefaults.standard.removeObject(forKey: Self.usernameKey)
        syncController.forgetAccount()
    }

    func makeEditor() -> CollectionEditor {
        CollectionEditor(services: self)
    }

    /// The one sync controller for the app. Views must share it, or a sync started in Settings
    /// looks like "not syncing" to the collection screen, which then shows its empty state.
    @ObservationIgnored private var storedSyncController: SyncController?

    var syncController: SyncController {
        if let storedSyncController { return storedSyncController }
        let controller = SyncController(services: self)
        storedSyncController = controller
        return controller
    }

    func makeSyncer() -> CollectionSyncer? {
        guard let client else { return nil }
        return CollectionSyncer(client: client, store: store, imageCache: imageCache)
    }

    private static func makeClient(token: String, configuration: URLSessionConfiguration) -> DiscogsClient {
        DiscogsClient(
            token: token,
            configuration: DiscogsConfiguration(userAgent: DiscogsUserAgent.value),
            session: URLSession(configuration: configuration)
        )
    }
}
