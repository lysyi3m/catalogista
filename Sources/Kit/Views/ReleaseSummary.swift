import SwiftUI

/// A release's cover, title, artist and edition. On the Mac the edition is a two-column table
/// beside the cover, the way discogs.com lays out a release; on iOS it follows the cover.
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
    /// Makes the cover open the release's images. The record page sets it; the add confirmation
    /// does not.
    var gallery: CoverGallery?
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

    @ViewBuilder
    private func coverImage(edge: CGFloat) -> some View {
        let image = CoverImageView(releaseID: releaseID, remoteURL: cover.url, kind: cover.kind, edge: edge)
            .frame(width: edge, height: edge)
            .clipShape(.rect(cornerRadius: Self.coverCornerRadius))
        if let gallery {
            GalleryCover(releaseID: releaseID, artwork: cover, gallery: gallery, cornerRadius: Self.coverCornerRadius) { image }
        } else {
            image.shadow(color: Self.coverShadow, radius: 10, y: 4)
        }
    }

    private static let coverCornerRadius: CGFloat = 8
    // Soft and low: a dark lower edge drew the eye away from the text beside it.
    private static let coverShadow = Color.black.opacity(0.16)

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

/// What the cover opens: the release's images, in Quick Look.
struct CoverGallery {
    let count: Int
    let isLoading: Bool
    let open: () -> Void
}

/// The cover as a button that opens the release's images. With more than one image, two sheets in
/// the cover's own colours stack behind it and a badge gives the count.
private struct GalleryCover<Cover: View>: View {
    let releaseID: Int
    let artwork: (url: String?, kind: ImageCache.Kind)
    let gallery: CoverGallery
    let cornerRadius: CGFloat
    @ViewBuilder let cover: Cover

    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    /// Back sheet last. Empty when the cover could not be read, and neutral sheets stand in.
    @State private var sheetColors: [CoverPalette.RGB] = []
    @State private var isPaletteRead = false
    /// The sheets wait until the cover's colours are read, then fan out from behind it.
    @State private var isFanned = false

    private var hasMore: Bool { gallery.count > 1 }

    var body: some View {
        Button(action: gallery.open) {
            // Only the cover lifts on hover; the sheets and the badge keep their place.
            cover
                // Close and tight, so the cover lifts off sheets in its own colours.
                .shadow(color: .black.opacity(hasMore ? 0.22 : 0), radius: 1.5, y: 0.5)
                .shadow(color: .black.opacity(isHovered ? 0.14 : 0.1), radius: isHovered ? 9 : 6, y: isHovered ? 3 : 2)
                .scaleEffect(isHovered ? 1.02 : 1)
                .animation(.smooth(duration: 0.2), value: isHovered)
                // The sheets stay out of the layout, so the cover keeps its place beside the text.
                .background {
                    if hasMore && isPaletteRead {
                        // Inserted folded, so they have somewhere to fan out from.
                        sheets
                            .compositingGroup()
                            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                            .onAppear { isFanned = true }
                            .onDisappear { isFanned = false }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if hasMore || gallery.isLoading { badge.padding(10) }
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(hasMore ? "Cover, \(gallery.count) images" : "Cover")
        .accessibilityHint(hasMore ? "Opens the images" : "Opens the image")
        .task(id: artwork.url) { await readSheetColors() }
    }

    private var badge: some View {
        HStack(spacing: 6) {
            if gallery.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "photo.on.rectangle")
            }
            if hasMore { Text("\(gallery.count)").monospacedDigit() }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    /// Sheets in the cover's colours, not the release's other images: those would pull the eye
    /// from the cover, and need downloading before the page settles.
    private var sheets: some View {
        ZStack {
            fanned(sheet(sheetColors.last), step: 2)
            fanned(sheet(sheetColors.first), step: 1)
        }
    }

    /// Each sheet a step further out than the one in front of it, and a beat behind it, like the
    /// blades of a hand fan.
    private func fanned(_ sheet: some View, step: Double) -> some View {
        let distance = isFanned ? step : 0
        return sheet
            .rotationEffect(.degrees(Self.rotation * distance))
            .offset(x: Self.offset * distance, y: -Self.offset * distance)
            .animation(
                isFanned && !reduceMotion ? .spring(duration: 0.5, bounce: 0.35).delay(0.06 * (step - 1)) : nil,
                value: isFanned
            )
    }

    private func sheet(_ color: CoverPalette.RGB?) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(color.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? Color.gray.opacity(0.35))
            .overlay { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.black.opacity(0.08)) }
    }

    /// From the cover file on disk, small, off the main thread.
    private func readSheetColors() async {
        isPaletteRead = false
        defer { if !Task.isCancelled { isPaletteRead = true } }
        guard let remote = artwork.url.flatMap(URL.init(string:)),
              let file = try? await services.imageCache.localURL(
                  releaseID: releaseID,
                  kind: artwork.kind,
                  remoteURL: remote,
                  priority: .visible
              )
        else { return }
        let colors = await Task.detached(priority: .utility) { CoverPalette.sheetColors(at: file) }.value
        guard !Task.isCancelled else { return }
        sheetColors = colors
    }

    private static var rotation: Double { 2.5 }
    private static var offset: CGFloat { 3 }
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
