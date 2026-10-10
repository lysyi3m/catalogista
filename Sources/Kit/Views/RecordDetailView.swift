import DiscogsKit
import SwiftData
import SwiftUI

/// One record: cover and edition, this copy's details, the tracklist and the release notes.
///
/// The collection snapshot holds what identifies an edition — title, artist, label and catalog
/// number — so the page has content the moment it opens. One release fetch on open adds the
/// tracklist, notes, release date and country.
struct RecordDetailView: View {
    let item: CachedCollectionItem

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Query private var cachedFolders: [CachedFolder]
    @Query(sort: [SortDescriptor(\CachedField.position), SortDescriptor(\CachedField.id)])
    private var cachedFields: [CachedField]

    @State private var loader: ReleaseDetailLoader?
    @State private var editor: CollectionEditor?
    @State private var isConfirmingRemoval = false
    @State private var isTracklistExpanded = true
    /// The visible height. A short page is stretched to it, which keeps the credit on the bottom
    /// edge. See `creditViewport(_:)`.
    @State private var viewportHeight: CGFloat = 0
    #if os(iOS)
    /// Whether the page's title has scrolled under the navigation bar. Until it has, the bar stays
    /// empty rather than repeat it.
    @State private var isTitleUnderBar = false
    @State private var titleTracking = TitleTracking()
    #endif

    private var detail: ReleaseDetailSnapshot? { loader?.snapshot }

    private var pagePadding: CGFloat {
        #if os(macOS)
        28
        #else
        20
        #endif
    }

    /// On iOS the navigation bar already sets the cover apart from the top edge.
    private var topPadding: CGFloat {
        #if os(macOS)
        28
        #else
        4
        #endif
    }

    private var navigationTitle: String {
        #if os(iOS)
        isTitleUnderBar ? item.title : ""
        #else
        item.title
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    CopyFields(
                        dateAdded: item.dateAdded,
                        values: item.fieldValues,
                        fields: cachedFields.map(\.field)
                    ) {
                        FolderMenu(
                            folderID: item.folderID,
                            folders: CollectionFolders.destinations(cachedFolders.map(\.snapshot)),
                            isWorking: editor?.isWorking ?? true,
                            onMove: { folderID in
                                Task { await editor?.move(instanceID: item.instanceID, toFolderID: folderID) }
                            }
                        )
                    }
                    tracklist
                    notes
                    if let staleSince = loader?.staleSince {
                        Label(
                            "Details updated \(staleSince.formatted(.relative(presentation: .named)))",
                            systemImage: "clock.arrow.circlepath"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                // Outside the spaced stack: the credit brings its own space.
                DiscogsCredit(destination: discogsURL)
            }
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, pagePadding)
            .padding(.top, topPadding)
            .frame(minHeight: viewportHeight)
        }
        .creditViewport($viewportHeight)
        .detailScrollEdge()
        #if os(iOS)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, inset in
            titleTracking.topInset = inset
            updateTitleUnderBar()
        }
        #endif
        .navigationTitle(navigationTitle)
        .toolbar {
            ToolbarItem {
                RecordMenu(
                    discogsURL: discogsURL,
                    isWorking: editor?.isWorking ?? true,
                    onRequestRemove: { isConfirmingRemoval = true }
                )
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Before the first frame, unlike `task`: a record opened before shows its details at once.
        .onAppear {
            if loader == nil {
                loader = ReleaseDetailLoader(
                    services: services,
                    cached: ReleaseDetailLoader.cachedDetail(releaseID: item.releaseID, in: item.modelContext)
                )
            }
        }
        .task {
            editor = editor ?? services.makeEditor()
            let loader = loader ?? ReleaseDetailLoader(services: services)
            self.loader = loader
            // Tracklist, notes and country arrive together; one fetch covers the page.
            await loader.load(releaseID: item.releaseID)
            // A page left open refreshes itself once its data passes six hours old.
            await loader.keepFresh(releaseID: item.releaseID)
        }
        // An alert rather than a confirmation dialog. Raised from the "…" menu, a dialog is
        // presented as a popover anchored to that menu and inherits its width. That crams the
        // message into a few words per line and hides the cancel button behind a tap outside.
        .alert(
            "Remove this copy?",
            isPresented: $isConfirmingRemoval
        ) {
            Button("Remove from Collection", role: .destructive) {
                Task {
                    if await editor?.remove(instanceID: item.instanceID) == true { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(item.artistName) — \(item.title)\nThis copy will be removed from your collection on Discogs.")
        }
        .collectionFailureAlert(editor)
    }

    private var discogsURL: URL {
        detail?.discogsURL.flatMap(URL.init(string:)) ?? DiscogsNotice.releaseURL(id: item.releaseID)
    }

    // MARK: - Header

    /// Which image to show, and which cache slot it belongs in.
    ///
    /// The grid and this page share one cache slot per release, so they have to agree on the URL.
    /// Otherwise each reads the other's URL as a changed image and downloads the slot again. The
    /// collection's `cover_image` wins; the release's own full-size image is the fallback for a
    /// copy that has none.
    ///
    /// When neither exists the thumb is shown, but as a thumb — writing it into the cover slot
    /// would cache a 150px image as this release's cover for as long as its URL stands.
    private var coverSource: (url: String?, kind: ImageCache.Kind) {
        let collection = item.artwork
        if collection.kind == .cover { return collection }
        if let cover = detail?.coverURL, !cover.isEmpty { return (cover, .cover) }
        return collection
    }

    private var header: some View {
        ReleaseHeader(
            releaseID: item.releaseID,
            cover: coverSource,
            title: item.title,
            artist: item.artistName,
            facts: Fact.present([
                (Fact.label, item.labelName),
                (Fact.catalogNumber, item.catalogNumber),
                (Fact.format, item.formatSummary),
                (Fact.country, detail?.country),
                // The full date once the release is fetched; until then the year the copy carries.
                (Fact.released, detail?.releasedDisplay ?? item.year.map(String.init)),
            ]),
            genres: item.genres,
            styles: item.styles,
            onTitleBottomChange: { bottom in
                #if os(iOS)
                titleTracking.titleBottom = bottom
                updateTitleUnderBar()
                #endif
            }
        )
    }

    #if os(iOS)
    /// Changes view state only when the title crosses the bar. The positions change on every
    /// scrolled frame, and stored as state they re-evaluated the whole page each time.
    private func updateTitleUnderBar() {
        let isUnder = titleTracking.titleBottom < titleTracking.topInset
        if isUnder != isTitleUnderBar { isTitleUnderBar = isUnder }
    }
    #endif

    // MARK: - Tracklist

    @ViewBuilder
    private var tracklist: some View {
        DisclosureGroup(isExpanded: $isTracklistExpanded) {
            tracklistContent
                .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Text("Tracklist").font(.pageHeading)
                if let count = detail?.playableTracks.count {
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                }
                if loader?.state == .loading {
                    ProgressView().controlSize(.small)
                }
            }
            #if os(iOS)
            // The whole row toggles, not only the words and the chevron at either end.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            #endif
        }
        #if os(iOS)
        // Left to the accent colour, the section heading reads as a link rather than a heading.
        .tint(.primary)
        #endif
    }

    @ViewBuilder
    private var notes: some View {
        if let notes = detail?.notes, !notes.isEmpty {
            // Named apart from a custom field the owner may also have called Notes, in Copy.
            PageSection("Release Notes") {
                NotesText(notes: DiscogsMarkup.attributed(notes))
            }
        }
    }

    @ViewBuilder
    private var tracklistContent: some View {
        switch loader?.state {
        case .loaded(let snapshot) where !snapshot.tracks.isEmpty:
            VStack(alignment: .leading, spacing: 0) {
                // By position in the list: position and title together are not unique — a release
                // can repeat an unnumbered heading, and repeated ids make SwiftUI reuse rows.
                ForEach(Array(snapshot.tracks.enumerated()), id: \.offset) { index, track in
                    TrackRow(track: track)
                    if index < snapshot.tracks.count - 1 { Divider() }
                }
            }
        case .loaded:
            Text("No tracklist on Discogs")
                .foregroundStyle(.secondary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).foregroundStyle(.red)
                Button("Try Again") {
                    Task { await loader?.load(releaseID: item.releaseID) }
                }
            }
        case .loading, nil:
            Text("Loading details…")
                .foregroundStyle(.secondary)
        }
    }
}

private struct TrackRow: View {
    let track: CachedTrack
    /// Grows with the text size, so a position such as "A10" stays on one line.
    @ScaledMetric(relativeTo: Self.supportingTextStyle) private var positionWidth: CGFloat = 44

    var body: some View {
        if track.isTrack {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(track.position)
                    .font(Self.supportingFont)
                    .foregroundStyle(.secondary)
                    .frame(width: positionWidth, alignment: .leading)
                Text(track.title)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if !track.duration.isEmpty {
                    // Monospaced digits keep the column's right edge straight.
                    Text(track.duration)
                        .font(Self.supportingFont)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        } else {
            Text(track.title)
                .fontWeight(.semibold)
                .textSelection(.enabled)
                .padding(.top, 12)
                .padding(.bottom, 4)
        }
    }

    #if os(iOS)
    /// One step under the title: at body size a position and a duration compete with it.
    private static let supportingTextStyle = Font.TextStyle.subheadline
    #else
    private static let supportingTextStyle = Font.TextStyle.body
    #endif
    private static let supportingFont = Font.system(supportingTextStyle)
}

#if os(iOS)
/// Where the page's title ends and where the navigation bar ends, in the scroll view's space. A
/// class, so updating them on every scrolled frame does not invalidate the page.
private final class TitleTracking {
    var titleBottom: CGFloat = .infinity
    var topInset: CGFloat = 0
}
#endif
