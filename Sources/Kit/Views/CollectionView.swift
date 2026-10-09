import SwiftData
import SwiftUI

/// The collection or one folder of it, as a wall of covers or as rows, sorted on the store
/// rather than in memory.
///
/// The sort lives in the `@Query` descriptor, so changing it re-fetches instead of re-sorting an
/// array, and both layouts stay lazy.
struct CollectionView: View {
    @Environment(AppServices.self) private var services
    @Query private var items: [CachedCollectionItem]

    private let folderID: Int
    private let folderName: String
    private let layout: CollectionLayout
    /// Held only to notice a change: re-sorted rows make the old scroll position meaningless.
    private let sortSignature: String
    /// The density the macOS slider drives. iOS sizes its cells from the screen instead.
    private let itemWidth: CGFloat
    private let searchQuery: String
    private let onSelect: (CachedCollectionItem) -> Void
    private let onRequestRemove: (CachedCollectionItem) -> Void
    /// Where a copy can be moved, for the context menu. See `CollectionFolders.destinations`.
    private let destinations: [FolderSnapshot]
    private let onMove: (CachedCollectionItem, Int) -> Void

    @State private var hoveredID: PersistentIdentifier?
    /// Room under a short list, and the grid's visible height. Both keep the credit on the bottom
    /// edge while the content is short. See `creditSlack(_:)` and `creditViewport(_:)`.
    @State private var creditSlack: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    init(
        folderID: Int,
        folderName: String,
        layout: CollectionLayout,
        sort: CollectionSortOption,
        direction: SortDirection,
        itemWidth: CGFloat,
        searchQuery: String,
        destinations: [FolderSnapshot],
        onSelect: @escaping (CachedCollectionItem) -> Void,
        onMove: @escaping (CachedCollectionItem, Int) -> Void,
        onRequestRemove: @escaping (CachedCollectionItem) -> Void
    ) {
        var descriptor = FetchDescriptor<CachedCollectionItem>()
        descriptor.sortBy = sort.sortDescriptors(direction)
        // Filtering in the fetch rather than over the results keeps the grid lazy.
        descriptor.predicate = CachedCollectionItem.predicate(inFolder: folderID, matching: searchQuery)
        _items = Query(descriptor)
        self.folderID = folderID
        self.folderName = folderName
        self.layout = layout
        self.sortSignature = "\(sort.rawValue).\(direction.rawValue)"
        self.searchQuery = searchQuery
        self.itemWidth = itemWidth
        self.onSelect = onSelect
        self.onRequestRemove = onRequestRemove
        self.destinations = destinations
        self.onMove = onMove
    }

    /// The cover alone, at most 72pt, so the sidebar stays visible under the pointer.
    ///
    /// Asked for at `sourceEdge`, the size the cell already decoded it at, and only drawn smaller.
    /// macOS snapshots the preview the moment the drag starts, and only an image already decoded
    /// at the requested size is there in time; any other size would start on the placeholder.
    private func dragPreview(for item: CachedCollectionItem, sourceEdge: CGFloat) -> some View {
        let drawn = min(sourceEdge, 72)
        return CoverImageView(releaseID: item.releaseID, remoteURL: item.artwork.url, kind: item.artwork.kind, edge: sourceEdge)
            .frame(width: drawn, height: drawn)
            .clipShape(.rect(cornerRadius: 6))
            // Drawn outside this view's hierarchy, so it inherits none of its environment: without
            // this the cover cannot reach the image cache, and reading it traps.
            .environment(services)
    }

    private func contextMenu(for item: CachedCollectionItem) -> some View {
        RecordContextMenu(
            folderID: item.folderID,
            folders: destinations,
            discogsURL: DiscogsNotice.releaseURL(id: item.releaseID),
            onOpen: { onSelect(item) },
            onMove: { onMove(item, $0) },
            onRequestRemove: { onRequestRemove(item) }
        )
    }

    var body: some View {
        if items.isEmpty, !searchQuery.isEmpty {
            // Shows only the query, no Discogs data, so there is nothing to credit.
            ContentUnavailableView.search(text: searchQuery)
        } else if items.isEmpty {
            // Only a folder can be empty here: an empty collection never reaches this view.
            ContentUnavailableView(
                "No Records",
                systemImage: "folder",
                description: Text("There are no records in “\(folderName)”.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The title still names a Discogs folder, so the credit stays, on the bottom edge as
            // elsewhere. An overlay, so the message centres in the window like the no-match one.
            .overlay(alignment: .bottom) { credit() }
        } else if layout == .list {
            list
        } else {
            #if os(iOS)
            // The covers are the content, so they take the width the device has: two per row on a
            // phone, more on an iPad. The edge is measured rather than assumed because it is also
            // the decode size.
            GeometryReader { proxy in
                let columnCount = max(2, Int(proxy.size.width / 200))
                let edge = max((proxy.size.width - phoneSpacing * CGFloat(columnCount + 1)) / CGFloat(columnCount), 1)
                grid(
                    columns: Array(
                        repeating: GridItem(.fixed(edge), spacing: phoneSpacing),
                        count: columnCount
                    ),
                    spacing: phoneSpacing,
                    edge: edge,
                    showsCaption: true
                )
            }
            #else
            grid(
                columns: [GridItem(.adaptive(minimum: itemWidth), spacing: spacing)],
                spacing: spacing,
                edge: itemWidth,
                showsCaption: itemWidth >= 110
            )
            #endif
        }
    }

    /// Rows, for finding rather than browsing: the sort key is readable instead of implied by
    /// position, and far more of the collection fits on screen.
    private var list: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(items) { item in
                        Button { onSelect(item) } label: {
                            ReleaseRow(
                                releaseID: item.releaseID,
                                remoteURL: item.artwork.url,
                                kind: item.artwork.kind,
                                title: item.title,
                                artist: item.artistName,
                                // What the record page puts under the title. Year alone in a
                                // right-hand column is a lot of width for four digits.
                                details: ReleaseRow.details([
                                    item.year.map(String.init),
                                    item.formatSummary,
                                ])
                            )
                        }
                            .buttonStyle(.plain)
                            .contextMenu { contextMenu(for: item) }
                            .draggable(item.copyReference) { dragPreview(for: item, sourceEdge: ReleaseRow.defaultCoverEdge) }
                            #if os(iOS)
                            .swipeActions(edge: .trailing) {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    onRequestRemove(item)
                                }
                            }
                            #endif
                            .rowHoverHighlight(id: item.id, hovered: $hoveredID)
                    }
                }
                credit(slack: creditSlack, listOffset: DiscogsCredit.standardListOffset)
                    .creditRow()
            }
            // The list's own trailing margin would add to the space the credit brings.
            .contentMargins(.bottom, 0, for: .scrollContent)
            .creditSlack($creditSlack)
            .detailScrollEdge()
            #if os(macOS)
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            #endif
            // A new sort re-fetches into the same list, which keeps its scroll offset. The offset
            // no longer points at anything the user chose, so it lands a couple of rows down the
            // new ordering. Start at the top, which is what the re-sort was asking for.
            .onChange(of: sortSignature) {
                guard let first = items.first?.id else { return }
                proxy.scrollTo(first, anchor: .top)
            }
        }
    }

    private func grid(
        columns: [GridItem],
        spacing: CGFloat,
        edge: CGFloat,
        showsCaption: Bool
    ) -> some View {
        ScrollView {
            // At least the visible height, so a short folder still ends on the bottom edge.
            VStack(spacing: 0) {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(items) { item in
                        Button { onSelect(item) } label: {
                            CoverCell(item: item, edge: edge, showsCaption: showsCaption)
                        }
                        .buttonStyle(.plain)
                        // A dense grid has no caption, and the cover says nothing to VoiceOver.
                        .accessibilityLabel("\(item.title), \(item.artistName)")
                        // Long press on iOS, right click on macOS.
                        .contextMenu { contextMenu(for: item) }
                        .draggable(item.copyReference) { dragPreview(for: item, sourceEdge: edge) }
                    }
                }
                // No bottom padding: the credit below brings its own space.
                .padding([.horizontal, .top], spacing)
                Spacer(minLength: 0)
                credit()
            }
            .frame(minHeight: viewportHeight)
        }
        .creditViewport($viewportHeight)
        .detailScrollEdge()
    }

    /// Only the list passes slack: the grid and the empty folder fill the window themselves.
    private func credit(slack: CGFloat = 0, listOffset: CGFloat = 0) -> some View {
        DiscogsCredit(
            destination: DiscogsNotice.collectionURL(username: services.accountUsername, folderID: folderID),
            slack: slack,
            listOffset: listOffset
        )
    }

    #if os(iOS)
    private var phoneSpacing: CGFloat { 16 }
    #else
    /// Tight covers at high density read as a wall; loose ones at low density read as cards.
    private var spacing: CGFloat {
        itemWidth < 100 ? 6 : 12
    }
    #endif
}

private struct CoverCell: View {
    let item: CachedCollectionItem
    let edge: CGFloat
    let showsCaption: Bool

    @State private var isHovered = false

    private var cornerRadius: CGFloat { edge < 100 ? 3 : 5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            CoverImageView(
                releaseID: item.releaseID,
                remoteURL: item.artwork.url,
                kind: item.artwork.kind,
                edge: edge
            )
            .frame(width: edge, height: edge)
            .clipShape(.rect(cornerRadius: cornerRadius))
            // A sleeve with a pale background has no edge of its own and dissolves into the page.
            // The hairline gives every cover the same silhouette, whatever the art does.
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(isHovered ? 0.22 : 0.10), radius: isHovered ? 8 : 3, y: isHovered ? 4 : 1)
            .scaleEffect(isHovered ? 1.025 : 1)

            if showsCaption {
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(item.artistName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(width: edge, alignment: .leading)
            }
        }
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .onHover { isHovered = $0 }
        .help("\(item.artistName) — \(item.title)")
    }
}
