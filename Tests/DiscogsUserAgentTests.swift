import DiscogsKit
import Foundation
import Testing
@testable import CatalogistaKit

@Suite("Discogs User-Agent")
struct DiscogsUserAgentTests {
    @Test("The app bundle's marketing version goes into the User-Agent")
    func usesAppVersion() {
        let info: [String: Any] = [
            "CFBundleIdentifier": DiscogsUserAgent.appBundleIdentifier,
            "CFBundleShortVersionString": "1.1",
        ]
        #expect(DiscogsUserAgent.make(info: info) == DiscogsConfiguration.userAgent(appVersion: "1.1"))
    }

    @Test(
        "Without the app's own version the User-Agent says dev",
        arguments: [
            nil,
            [:],
            ["CFBundleIdentifier": DiscogsUserAgent.appBundleIdentifier],
            ["CFBundleIdentifier": DiscogsUserAgent.appBundleIdentifier, "CFBundleShortVersionString": ""],
            ["CFBundleIdentifier": "com.apple.dt.xctest.tool", "CFBundleShortVersionString": "27.0"],
        ] as [[String: String]?]
    )
    func fallsBackToDevelopmentVersion(info: [String: String]?) {
        #expect(
            DiscogsUserAgent.make(info: info)
                == DiscogsConfiguration.userAgent(appVersion: DiscogsUserAgent.developmentVersion)
        )
    }

    @Test("The test runner is not the app, so the shared value says dev")
    func testRunnerFallsBack() {
        #expect(DiscogsUserAgent.value.hasPrefix("Catalogista/\(DiscogsUserAgent.developmentVersion) +"))
    }
}
