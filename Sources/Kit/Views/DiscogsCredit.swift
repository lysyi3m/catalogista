import DiscogsKit
import SwiftUI

/// The notices the Discogs API Terms of Use require.
///
/// The affiliation notice must be shown prominently in the app. The credit must sit directly next
/// to any Discogs data and link to the discogs.com page that holds that data.
enum DiscogsNotice {
    static let affiliation = "This application uses Discogs’ API but is not affiliated with, sponsored or endorsed by Discogs. ‘Discogs’ is a trademark of Zink Media, LLC."

    /// The collection's page, or one folder's when `folderID` names a real folder.
    static func collectionURL(username: String?, folderID: Int = DiscogsFolder.all) -> URL {
        guard let username,
              let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(string: "https://www.discogs.com/user/\(encoded)/collection")
        else { return URL(string: "https://www.discogs.com")! }
        if folderID != DiscogsFolder.all {
            components.queryItems = [URLQueryItem(name: "folder_id", value: String(folderID))]
        }
        return components.url ?? URL(string: "https://www.discogs.com")!
    }

    static func releaseURL(id: Int) -> URL {
        URL(string: "https://www.discogs.com/release/\(id)")!
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

/// "Data provided by Discogs. View ↗", the link going to the page the data came from.
///
/// One line, since it ends every screen. The notice reads as a notice; the arrow marks the link as
/// leaving the app, and VoiceOver reads it in full. The credit owns the space around it, the same
/// above as below, so every screen ends the same way: content, space, credit, space. Callers place
/// it flush against their content.
///
/// In a list, `slack` is the room left under rows that do not fill the window (see
/// `creditSlack(_:)`). It goes above the credit, so the credit sits on the bottom edge until the
/// rows scroll. Other scroll views stretch their content instead (see `creditViewport(_:)`).
struct DiscogsCredit: View {
    let destination: URL
    var slack: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: slack)
            line
        }
    }

    private var line: some View {
        HStack(spacing: 4) {
            Text("Data provided by Discogs.")
                .foregroundStyle(.secondary)
            Link(destination: destination) {
                HStack(spacing: 2) {
                    Text("View")
                    Image(systemName: "arrow.up.right")
                        .imageScale(.small)
                }
            }
            .accessibilityLabel("View on Discogs")
        }
        .font(.caption)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

extension View {
    /// Measures the room a list leaves under its content, for `DiscogsCredit.slack`.
    ///
    /// The content includes the slack itself, so the new value is the old one plus what is still
    /// left over. It settles after one pass, and sub-point changes are ignored so rounding cannot
    /// feed back into another layout.
    func creditSlack(_ slack: Binding<CGFloat>) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
                - geometry.contentSize.height
        } action: { _, leftover in
            let settled = max(0, slack.wrappedValue + leftover)
            if abs(settled - slack.wrappedValue) >= 1 { slack.wrappedValue = settled }
        }
    }

    /// Measures a scroll view's visible height.
    ///
    /// Content given at least this height, with a flexible space before the credit, keeps the
    /// credit on the bottom edge until the content is tall enough to scroll. For scroll views whose
    /// content can be stretched; a `List` cannot, and uses `creditSlack(_:)`.
    func creditViewport(_ height: Binding<CGFloat>) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            #if os(macOS)
            // The detail column already ends at the toolbar and the status bar, yet the scroll view
            // still reports both as insets. Subtracting them counts the bars twice, and the credit
            // stops about 90pt short of the bottom edge.
            geometry.containerSize.height
            #else
            // On iPhone the content runs under the bars, so the insets are real.
            geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
            #endif
        } action: { _, visible in
            height.wrappedValue = max(0, visible)
        }
    }

    /// Places a credit as the last row of a list. A section footer adds insets of its own, which
    /// would leave more space below the credit than above it.
    func creditRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// Links the app publishes. Public so the macOS Help menu in the app target can use them.
public enum AppLinks {
    public static let privacyPolicy = URL(string: "https://github.com/lysyi3m/catalogista/blob/master/PRIVACY.md")!
}
