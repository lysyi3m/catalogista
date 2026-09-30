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
    /// Space a list keeps after its last row. The credit moves down by it within its own padding,
    /// so it ends as far from the bottom edge in a list as anywhere else. See `ListCreditSpacing`.
    var listTrailing: CGFloat = 0

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
            .accessibilityLabel("View on Discogs")
        }
        .font(.caption)
        .frame(maxWidth: .infinity)
        // Moved, not trimmed: the row keeps its height, so the list's layout does not change and
        // cannot feed back into the measurement.
        .padding(.top, 24 + listTrailing)
        .padding(.bottom, 24 - listTrailing)
    }
}

/// Measures the space a `List` keeps after its last row.
///
/// The macOS list keeps about 14 pt there whatever its content margins say, so a credit in its
/// last row ends higher than one at the end of a grid or a page, and jumps when switching between
/// them. Measured rather than assumed, since the list style decides it: the content's bottom edge
/// minus the credit row's, both in the scroll view's space. Taken only while the list is at rest,
/// because the two readings arrive separately and would disagree mid-scroll.
@MainActor
@Observable
final class ListCreditSpacing {
    private(set) var trailing: CGFloat = 0
    @ObservationIgnored private var rowBottom: CGFloat?
    @ObservationIgnored private var contentBottom: CGFloat?
    @ObservationIgnored private var isScrolling = false

    func rowMoved(bottom: CGFloat) {
        rowBottom = bottom
        settle()
    }

    func contentMoved(bottom: CGFloat) {
        contentBottom = bottom
        settle()
    }

    func scrollingChanged(_ scrolling: Bool) {
        isScrolling = scrolling
        settle()
    }

    /// Applying a value moves the credit within its row and leaves every size alone, so the reading
    /// stays put. While rows first lay out the two readings drift apart and give passing values
    /// (−1460, 95, 175 pt measured), so only readings within the credit's own padding count, and
    /// a new value is applied after the layout pass: changing layout from within a layout pass
    /// made AppKit stop the app.
    private func settle() {
        guard !isScrolling, let rowBottom, let contentBottom else { return }
        let measured = (contentBottom - rowBottom).rounded()
        guard (0...24).contains(measured), measured != trailing else { return }
        Task { @MainActor in self.trailing = measured }
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
            // The container already ends at the toolbar and the bottom bar, yet the scroll view
            // still reports both as insets, on macOS and iOS alike. Subtracting them counts the
            // bars twice, and the credit stops short of the bottom edge.
            geometry.containerSize.height
        } action: { _, visible in
            height.wrappedValue = max(0, visible)
        }
    }

    /// Places a credit as the last row of a list. A section footer adds insets of its own, which
    /// would leave more space below the credit than above it. `spacing` measures the row; pass the
    /// same object to the list's `listCreditSpacing(_:)` and its `trailing` to the credit.
    func creditRow(_ spacing: ListCreditSpacing? = nil) -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).maxY } action: {
                spacing?.rowMoved(bottom: $0)
            }
    }

    /// The list's half of `ListCreditSpacing`: where its content ends, and whether it is scrolling.
    func listCreditSpacing(_ spacing: ListCreditSpacing) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            // The content's bottom edge in the same space as the row's frame.
            geometry.contentSize.height - geometry.contentOffset.y
        } action: { _, bottom in
            spacing.contentMoved(bottom: bottom)
        }
        .onScrollPhaseChange { _, phase in
            spacing.scrollingChanged(phase != .idle)
        }
    }
}

/// Links the app publishes. Public so the macOS Help menu in the app target can use them.
public enum AppLinks {
    public static let privacyPolicy = URL(string: "https://github.com/lysyi3m/catalogista/blob/master/PRIVACY.md")!
}
