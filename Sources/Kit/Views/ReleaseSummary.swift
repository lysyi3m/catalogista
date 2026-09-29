import SwiftUI

/// A release at the top of a page: cover, title, artist, year and format, genres and styles.
///
/// Shared by the record page and the add confirmation, so a release reads the same before and
/// after it is added.
struct ReleaseHeader: View {
    let releaseID: Int
    let cover: (url: String?, kind: ImageCache.Kind)
    let title: String
    let artist: String
    /// Year and format, the two things that distinguish one edition from another at a glance.
    let subtitle: String
    let tags: [String]

    var body: some View {
        #if os(iOS)
        // Side by side, a phone leaves the text about 120pt — too narrow for a format summary, and
        // narrow enough that the genre chips collapse to one letter per line. The cover leads
        // instead, the way a record page reads anyway.
        VStack(alignment: .leading, spacing: 18) {
            coverImage(edge: 240)
                .frame(maxWidth: .infinity, alignment: .center)
            titleBlock
        }
        #else
        HStack(alignment: .top, spacing: 24) {
            coverImage(edge: 200)
            titleBlock
            Spacer(minLength: 0)
        }
        #endif
    }

    private func coverImage(edge: CGFloat) -> some View {
        CoverImageView(releaseID: releaseID, remoteURL: cover.url, kind: cover.kind, edge: edge)
            .frame(width: edge, height: edge)
            .clipShape(.rect(cornerRadius: 8))
            .shadow(radius: 6, y: 3)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            Text(artist)
                .font(.title3)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            if !tags.isEmpty {
                TagRow(tags: tags)
                    .padding(.top, 4)
            }
        }
    }
}

/// The edition details, as a wrapping grid rather than a column of full-width rows: five short
/// facts do not need five lines of a wide window.
struct EditionFacts: View {
    struct Entry {
        let label: String
        let value: String
    }

    static let label = "Label"
    static let catalogNumber = "Catalog number"
    static let released = "Released"
    /// Discogs mixes countries with regions ("Europe"), compounds ("UK & Europe") and historical
    /// states, and sends abbreviations rather than CLDR names, so the value cannot be classified
    /// reliably. The label covers both rather than claiming one.
    static let country = "Country/Region"
    static let added = "Added"

    let entries: [Entry]

    /// Drops the facts Discogs left empty.
    init(_ facts: [(label: String, value: String?)]) {
        entries = facts.compactMap { fact in
            guard let value = fact.value, !value.isEmpty else { return nil }
            return Entry(label: fact.label, value: value)
        }
    }

    var body: some View {
        if !entries.isEmpty {
            PageSection("Edition") {
                LazyVGrid(
                    // Sized so the five usual facts sit on one line at the record page's width; a
                    // lone "Added" wrapping to a second row looks like a mistake.
                    columns: [GridItem(.adaptive(minimum: 130), spacing: 16, alignment: .leading)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(entries, id: \.label) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.value)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// A headed section of a page.
struct PageSection<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
    }
}

/// Genres and styles as unobtrusive chips, which read faster than a comma-separated list.
private struct TagRow: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags.prefix(5), id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
            }
        }
    }
}

/// Chips that wrap onto the next line rather than being squeezed, which is what an `HStack` does
/// to them when the column is narrower than their combined width.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var height: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                height += rowHeight + spacing
                rowHeight = 0
                x = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: height + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                rowHeight = 0
                x = bounds.minX
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
