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
            // `folder`, as discogs.com itself links a folder. The API's `folder_id` is ignored there
            // and opens the whole collection.
            components.queryItems = [URLQueryItem(name: "folder", value: String(folderID))]
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
    /// Moves the credit down within its own padding, to line it up with the credit at the end of a
    /// grid or a page. See `standardListOffset`.
    var listOffset: CGFloat = 0

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
            // Explicit: an iOS list row draws a link in the primary colour, like plain text.
            .foregroundStyle(.tint)
            #if os(iOS)
            // A list row with one button-like control turns the whole row into that control, and
            // the row is stretched to fill the empty space below the list.
            .buttonStyle(.borderless)
            #endif
            .accessibilityLabel("View on Discogs")
        }
        .font(.caption)
        .frame(maxWidth: .infinity)
        // Moved, not trimmed: the row keeps its height, so the list's layout does not change and
        // cannot feed back into the slack measurement.
        .padding(.top, 24 + listOffset)
        .padding(.bottom, 24 - listOffset)
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
    ///
    /// The view's own size, not its scroll geometry. A macOS window restored at launch grows to its
    /// saved size without a scroll-geometry update, which left the credit partway up the window.
    /// The size already ends at the toolbar and the bottom bar, which the scroll view still reports
    /// as insets; subtracting them would count the bars twice.
    func creditViewport(_ height: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visible in
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

extension DiscogsCredit {
    /// Lines up a list's credit with the one at the end of a grid or a page, checked side by side:
    /// the macOS inset list needs 10 pt, an iOS list none. The add sheet's results pass none.
    ///
    /// A constant, not a live measurement: the row and the content report their positions in
    /// separate callbacks, a frame apart while the list moves, so a measured value jitters.
    static var standardListOffset: CGFloat {
        #if os(macOS)
        10
        #else
        0
        #endif
    }
}

/// Links the app publishes. Public so the macOS Help menu in the app target can use them.
public enum AppLinks {
    public static let privacyPolicy = URL(string: "https://github.com/lysyi3m/catalogista/blob/master/PRIVACY.md")!
}
