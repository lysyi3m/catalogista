import Foundation

/// A defaults domain no other test shares. Suites run in parallel, and one suite's sync or
/// sign-out must not change the username or sync time another starts from. `discard()` removes
/// the domain when the test ends.
struct TestDefaults {
    let name = "com.mlkshkvch.catalogista.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
    }

    func discard() {
        defaults.removePersistentDomain(forName: name)
    }
}
