import SwiftUI

/// A release's cover, title and artist, with its edition beside them as a two-column table, the
/// way discogs.com lays out a release.
///
/// Used by the record page and by the add confirmation, so a release looks the same before and
/// after it is added.
struct ReleaseHeader: View {
    let releaseID: Int
    let cover: (url: String?, kind: ImageCache.Kind)
    let title: String
    let artist: String
    /// The edition table. See `Fact`.
    let facts: [Fact]
    /// The last row of the table, genres before styles. Discogs keeps the two apart (Jazz is a
    /// genre, Modal a style), so the row is labelled for both.
    let genres: [String]
    let styles: [String]
    /// Reports the title's lower edge in the scroll view's coordinates, so a page can put the
    /// title in its navigation bar once it scrolls out of view.
    var onTitleBottomChange: ((CGFloat) -> Void)?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var rows: [Fact] {
        // A genre and a style can share a name.
        var seen = Set<String>()
        let tags = (genres + styles).filter { seen.insert($0).inserted }
        return facts + Fact.present([(Fact.genresAndStyles, Self.list(tags))])
    }

    /// Items run together with middots. A line may break only after a dot, never before one or
    /// inside an item, so a wrapped list ends its line with "·" and starts the next with a whole
    /// item.
    nonisolated static func list(_ items: [String]) -> String {
        let nonBreaking = "\u{00A0}"
        return items
            .map { $0.replacingOccurrences(of: " ", with: nonBreaking) }
            .joined(separator: nonBreaking + "· ")
    }

    var body: some View {
        #if os(iOS)
        // Side by side, a phone leaves the table about 120pt. The cover leads instead, the way a
        // record page reads anyway.
        VStack(alignment: .leading, spacing: 18) {
            coverImage(edge: 240)
                .frame(maxWidth: .infinity, alignment: .center)
            VStack(alignment: .leading, spacing: 18) {
                titleAndArtist
                if horizontalSizeClass == .compact {
                    // A label column takes a third of a phone's width and squeezes the long
                    // values, so each label sits above its value instead.
                    StackedFacts(facts: rows)
                } else {
                    table
                }
            }
        }
        #else
        // Sized so the title and a typical edition table end near the cover's lower edge: larger,
        // and an empty band opens under the text.
        HStack(alignment: .top, spacing: 28) {
            coverImage(edge: 216)
            details
            Spacer(minLength: 0)
        }
        #endif
    }

    private func coverImage(edge: CGFloat) -> some View {
        CoverImageView(releaseID: releaseID, remoteURL: cover.url, kind: cover.kind, edge: edge)
            .frame(width: edge, height: edge)
            .clipShape(.rect(cornerRadius: 8))
            // Soft and low: a dark lower edge drew the eye away from the text beside it.
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleAndArtist
            table
        }
    }

    private var titleAndArtist: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Self.titleFont)
                .textSelection(.enabled)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).maxY } action: {
                    onTitleBottomChange?($0)
                }
            Text(artist)
                .font(Self.artistFont)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    #if os(iOS)
    // A step down from the Mac: under a full-width cover, .title wraps most titles.
    private static let titleFont = Font.title2.weight(.semibold)
    private static let artistFont = Font.title3
    #else
    private static let titleFont = Font.title.weight(.semibold)
    private static let artistFont = Font.title2
    #endif

    private var table: some View {
        // Rows close enough to read as one block; wrapped values keep their own line spacing.
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 5) {
            ForEach(rows, id: \.label) { fact in
                GridRow {
                    Text(fact.label)
                        .foregroundStyle(.secondary)
                    Text(fact.value)
                        .textSelection(.enabled)
                }
            }
        }
        .font(.body)
    }
}

#if os(iOS)
/// The edition as labelled values, two short ones to a row and a long one across both columns.
/// One column at accessibility text sizes.
private struct StackedFacts: View {
    let facts: [Fact]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Facts whose values run long on Discogs; the rest fit half a phone's width.
    private static let wide: Set<String> = [Fact.format, Fact.genresAndStyles]

    private var rows: [[Fact]] {
        var rows: [[Fact]] = []
        for fact in facts {
            if !Self.wide.contains(fact.label), let last = rows.last, last.count == 1,
               !Self.wide.contains(last[0].label) {
                rows[rows.count - 1].append(fact)
            } else {
                rows.append([fact])
            }
        }
        return rows
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(facts, id: \.label, content: cell)
            }
        } else {
            Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 14) {
                ForEach(rows, id: \.first?.label) { row in
                    GridRow {
                        if row.count == 1, Self.wide.contains(row[0].label) {
                            cell(row[0]).gridCellColumns(2)
                        } else {
                            ForEach(row, id: \.label, content: cell)
                        }
                    }
                }
            }
        }
    }

    private func cell(_ fact: Fact) -> some View {
        FactCell(label: fact.label) {
            Text(fact.value).textSelection(.enabled)
        }
    }
}
#endif

/// One labelled value: a row of the edition table, or a cell of a `FactGrid`.
struct Fact {
    let label: String
    let value: String

    static let label = "Label"
    static let catalogNumber = "Catalog Number"
    static let format = "Format"
    /// Discogs mixes countries with regions ("Europe"), compounds ("UK & Europe") and historical
    /// states, and sends abbreviations rather than CLDR names, so the value cannot be classified
    /// reliably. The label covers both rather than claiming one.
    static let country = "Country/Region"
    static let released = "Released"
    static let genresAndStyles = "Genres & Styles"

    /// The facts Discogs filled in, in order; the empty ones are dropped.
    static func present(_ facts: [(label: String, value: String?)]) -> [Fact] {
        facts.compactMap { fact in
            guard let value = fact.value, !value.isEmpty else { return nil }
            return Fact(label: fact.label, value: value)
        }
    }
}

/// Short labelled values in equal columns, wrapping to further rows. `leading` is a cell placed
/// first, for a value that is a control rather than text.
///
/// Four columns at most (two on a phone, one at accessibility text sizes): spread across the whole
/// page, a handful of short values read as scattered rather than as one group. On a phone the
/// leading cell takes a row of its own, so a long control does not crowd half the width.
struct FactGrid<Leading: View>: View {
    let entries: [Fact]
    let leading: Leading
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif

    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    private var columnCount: Int {
        #if os(iOS)
        if dynamicTypeSize.isAccessibilitySize { return 1 }
        #endif
        return isCompact ? 2 : 4
    }

    init(entries: [Fact], @ViewBuilder leading: () -> Leading) {
        self.entries = entries
        self.leading = leading()
    }

    var body: some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 16) {
                leading
                if !entries.isEmpty { grid {} }
            }
        } else {
            grid { leading }
        }
    }

    private func grid(@ViewBuilder first: () -> some View) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .topLeading), count: columnCount),
            alignment: .leading,
            spacing: 16
        ) {
            first()
            // By position: a custom field may share a name with another fact, such as "Added".
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                FactCell(label: entry.label) {
                    Text(entry.value)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// A label over a value. On the Mac both are at body size: placement already sets the label
/// apart, and the colour does the rest. On iOS, where body is 17pt, the label steps down.
struct FactCell<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Self.labelFont)
                .foregroundStyle(.secondary)
            value
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(iOS)
    private static var labelFont: Font { .subheadline }
    #else
    private static var labelFont: Font { .body }
    #endif
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
            Text(title).font(.pageHeading)
            content
        }
    }
}

extension Font {
    /// A section heading on a page.
    static var pageHeading: Font {
        #if os(iOS)
        // Under a .title2 record title, a .title3 heading competes with it.
        .headline
        #else
        .title3.weight(.semibold)
        #endif
    }
}
