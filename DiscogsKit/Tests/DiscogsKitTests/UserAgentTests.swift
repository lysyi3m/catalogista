import Testing
@testable import DiscogsKit

@Suite("User-Agent")
struct UserAgentTests {
    @Test("The User-Agent carries the given version and contact")
    func buildsFromVersionAndContact() {
        #expect(
            DiscogsConfiguration.userAgent(appVersion: "1.1", contact: "https://example.com")
                == "Catalogista/1.1 +https://example.com"
        )
    }

    @Test("The contact defaults to the project page")
    func defaultsContact() {
        #expect(
            DiscogsConfiguration.userAgent(appVersion: "2.0")
                == "Catalogista/2.0 +\(DiscogsConfiguration.contact)"
        )
    }
}
