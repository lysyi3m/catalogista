import SwiftUI

/// One release as a row: its cover, its title, who made it, and the details that separate one
/// edition from another.
///
/// Shared by the collection's list layout and the add sheet's results, which are the same thing
/// seen from two sides — a release you own and a release you might. Each caller supplies its own
/// `details`, because disambiguating an edition on Discogs needs more than reading your own shelf
/// does, but the shape stays identical so the two cannot drift apart.
struct ReleaseRow: View {
    let releaseID: Int
    let remoteURL: String?
    let kind: ImageCache.Kind
    let title: String
    let artist: String
    let details: String
    var coverEdge: CGFloat = Self.defaultCoverEdge

    static let defaultCoverEdge: CGFloat = 56

    var body: some View {
        HStack(spacing: 12) {
            CoverImageView(
                releaseID: releaseID,
                remoteURL: remoteURL,
                kind: kind,
                edge: coverEdge
            )
            .frame(width: coverEdge, height: coverEdge)
            .clipShape(.rect(cornerRadius: 4))
            // A pale sleeve has no edge of its own and would dissolve into the row.
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !details.isEmpty {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

extension View {
    /// Highlights a list row while the pointer is over it.
    ///
    /// The caller keeps one optional id for the whole list rather than a flag per row, so a move
    /// redraws the two rows that changed instead of all of them. `listRowBackground` rather than a
    /// background on the content, so the highlight spans the full row including its insets. A
    /// no-op where there is no pointer.
    func rowHoverHighlight<ID: Hashable>(id: ID, hovered: Binding<ID?>) -> some View {
        #if os(macOS)
        self
            .listRowBackground(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered.wrappedValue == id ? Color.primary.opacity(0.06) : .clear)
            )
            .onHover { isInside in
                if isInside { hovered.wrappedValue = id }
                else if hovered.wrappedValue == id { hovered.wrappedValue = nil }
            }
        #else
        self
        #endif
    }
}

extension ReleaseRow {
    /// Joins the parts that are present, dropping the empties, so a missing label never leaves a
    /// stray separator behind.
    nonisolated static func details(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
