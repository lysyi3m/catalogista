import DiscogsKit
import Foundation

/// The one `User-Agent` the app presents, to both the API and the image CDN.
enum DiscogsUserAgent {
    static let value = make(info: Bundle.main.infoDictionary)

    static let appBundleIdentifier = "com.mlkshkvch.catalogista"

    /// Sent outside the App Store app's bundle, so Discogs never sees a made-up release number.
    static let developmentVersion = "dev"

    /// Unhosted tests run inside the xctest runner, whose main bundle carries Xcode's version, so
    /// the version counts only when the bundle is the App Store app's. The dev app sends `dev`.
    static func make(info: [String: Any]?) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let isApp = info?["CFBundleIdentifier"] as? String == appBundleIdentifier
        return DiscogsConfiguration.userAgent(
            appVersion: isApp && !version.isEmpty ? version : developmentVersion
        )
    }
}
