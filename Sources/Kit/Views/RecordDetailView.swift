import SwiftUI

/// One record: cover, the facts that identify the edition, and its tracklist on request.
///
/// The collection snapshot holds what identifies an edition — title, artist, label and catalog
/// number — so the page has content the moment it opens. One release fetch on open adds the
/// tracklist, notes, release date and country.
struct RecordDetailView: View {
    let item: CachedCollectionItem

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var loader: ReleaseDetailLoader?
    @State private var editor: CollectionEditor?
    @State private var isConfirmingRemoval = false
    @State private var isTracklistExpanded = false
    /// The visible height. A short page is stretched to it, which keeps the credit on the bottom
    /// edge. See `creditViewport(_:)`.
    @State private var viewportHeight: CGFloat = 0

    private var detail: ReleaseDetailSnapshot? { loader?.snapshot }

    private var pagePadding: CGFloat {
        #if os(macOS)
        28
        #else
        20
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    facts
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
            .padding([.horizontal, .top], pagePadding)
            .frame(minHeight: viewportHeight)
        }
        .creditViewport($viewportHeight)
        .detailScrollEdge()
        .navigationTitle(item.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { actions }
        .task {
            editor = editor ?? services.makeEditor()
            let loader = loader ?? ReleaseDetailLoader(services: services)
            self.loader = loader
            // Tracklist, notes and country arrive together; one fetch covers the page.
            await loader.load(releaseID: item.releaseID)
            // A page left open refreshes itself once its data passes six hours old.
            await loader.keepFresh(releaseID: item.releaseID)
        }
        // An alert rather than a confirmation dialog. Raised from the toolbar menu, a dialog is
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

    // MARK: - Actions

    /// Record-scoped actions live in the toolbar rather than the page body: they are about the
    /// record rather than part of it.
    @ToolbarContentBuilder
    private var actions: some ToolbarContent {
        ToolbarItem {
            Menu {
                Link(destination: discogsURL) {
                    Label("View on Discogs", systemImage: "arrow.up.right.square")
                }
                Divider()
                Button(role: .destructive) {
                    isConfirmingRemoval = true
                } label: {
                    Label("Remove from Collection…", systemImage: "trash")
                }
                .disabled(editor?.isWorking ?? true)
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
        }
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
            subtitle: ReleaseRow.details([
                item.year.map(String.init),
                item.formatSummary,
            ]),
            tags: item.genres + item.styles
        )
    }

    // MARK: - Facts

    private var facts: some View {
        EditionFacts([
            (EditionFacts.label, item.labelName),
            (EditionFacts.catalogNumber, item.catalogNumber),
            (EditionFacts.released, detail?.releasedDisplay),
            (EditionFacts.country, detail?.country),
            (EditionFacts.added, item.dateAdded?.formatted(date: .abbreviated, time: .omitted)),
        ])
    }

    // MARK: - Tracklist

    @ViewBuilder
    private var tracklist: some View {
        DisclosureGroup(isExpanded: $isTracklistExpanded) {
            tracklistContent
                .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Text("Tracklist").font(.headline)
                if let count = detail?.playableTracks.count {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if loader?.state == .loading {
                    ProgressView().controlSize(.small)
                }
            }
        }
        #if os(iOS)
        // Left to the accent colour, the section heading reads as a link rather than a heading.
        .tint(.primary)
        #endif
    }

    @ViewBuilder
    private var notes: some View {
        if let notes = detail?.notes, !notes.isEmpty {
            PageSection("Notes") {
                Text(notes)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.callout).foregroundStyle(.red)
                Button("Try Again") {
                    Task { await loader?.load(releaseID: item.releaseID) }
                }
            }
        case .loading, nil:
            Text("Loading details…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TrackRow: View {
    let track: CachedTrack

    var body: some View {
        if track.isTrack {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(track.position)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Text(track.title).font(.callout)
                Spacer(minLength: 8)
                if !track.duration.isEmpty {
                    Text(track.duration)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        } else {
            Text(track.title)
                .font(.subheadline.weight(.semibold))
                .padding(.top, 12)
                .padding(.bottom, 4)
        }
    }
}
