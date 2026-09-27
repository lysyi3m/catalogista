import SwiftUI

/// The notices the Discogs API Terms of Use require.
///
/// The affiliation notice must be shown prominently in the app. The credit must sit directly next
/// to any Discogs data and link to the discogs.com page that holds that data.
enum DiscogsNotice {
    static let affiliation = "This application uses Discogs’ API but is not affiliated with, sponsored or endorsed by Discogs. ‘Discogs’ is a trademark of Zink Media, LLC."

    static func collectionURL(username: String?) -> URL {
        guard let username,
              let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://www.discogs.com/user/\(encoded)/collection")
        else { return URL(string: "https://www.discogs.com")! }
        return url
    }

    static func searchURL(query: String) -> URL {
        var components = URLComponents(string: "https://www.discogs.com/search/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "release"),
        ]
        return components.url!
    }
}

/// "Data provided by Discogs.", linked to the page the data came from.
struct DiscogsCredit: View {
    let destination: URL

    var body: some View {
        Link("Data provided by Discogs.", destination: destination)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Links the app publishes. Public so the macOS Help menu in the app target can use them.
public enum AppLinks {
    public static let privacyPolicy = URL(string: "https://github.com/lysyi3m/catalogista/blob/master/PRIVACY.md")!
}
