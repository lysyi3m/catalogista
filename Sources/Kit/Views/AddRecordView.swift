import DiscogsKit
import SwiftData
import SwiftUI

/// Search Discogs and pick the exact release, then pick its folder and add it.
///
/// Search runs on submit rather than per keystroke: the rate limit is 60 requests a minute, and
/// typing a release title would spend most of it.
struct AddRecordView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    /// The folder on screen when the sheet opened, which the second step preselects.
    let folderID: Int
    /// Closed by the presenter when the sheet goes. See `AddRecordSession`.
    let session: AddRecordSession

    @Query private var cachedFolders: [CachedFolder]
    @State private var query = ""
    /// The release picked in the first step. While set, the sheet shows the second step.
    @State private var confirming: SearchResult?
    @State private var targetFolderID = DiscogsFolder.uncategorized
    @State private var editor: CollectionEditor?
    @State private var hoveredResultID: Int?
    /// Room under short results, which keeps the credit on the bottom edge. See `creditSlack(_:)`.
    @State private var resultsCreditSlack: CGFloat = 0
    @State private var search: ReleaseSearchController?
    /// Shown when there is no client to search with, which is not a search failure.
    @State private var noTokenMessage: String?

    private var state: ReleaseSearchController.State { search?.state ?? .idle }
    private var results: [SearchResult] { search?.results ?? [] }

    var body: some View {
        sheet
        // A macOS sheet sizes itself to its content, and a List inside a VStack reports no height
        // of its own. Without an explicit size the results area collapses to nothing and the sheet
        // renders as a search field over blank space.
        // Wide enough for the second step's cover beside its edition table.
        #if os(macOS)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 760)
        #endif
        // A sheet closed while the add is out would leave its outcome unreported.
        .interactiveDismissDisabled(editor?.isWorking ?? false)
        .task {
            editor = editor ?? services.makeEditor()
            if search == nil, let client = services.client {
                search = ReleaseSearchController(client: client)
            }
        }
        // Their images go when the sheet closes, except those of releases in the collection.
        .onChange(of: results.map(\.id)) { _, ids in session.noteListed(ids) }
        .onDisappear { search?.cancel() }
        .collectionFailureAlert(editor)
    }

    private var targets: [FolderSnapshot] {
        CollectionFolders.destinations(cachedFolders.map(\.snapshot))
    }

    private func confirm(_ result: SearchResult) {
        targetFolderID = CollectionFolders.addTarget(for: folderID, among: targets)
        _ = session.preview(of: result.id, services: services)
        confirming = result
    }

    /// A macOS sheet has no navigation bar worth the name: a title strip, a search strip and a
    /// button strip give it three horizontal rules and no hierarchy. The sheet has no title strip,
    /// and one rule separates the query from its results.
    @ViewBuilder
    private var sheet: some View {
        #if os(macOS)
        // The second step replaces the first in place. The search controller keeps its results,
        // so Back returns to the same list.
        VStack(spacing: 0) {
            if let confirming {
                confirmation(for: confirming)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Floating over the page, as the bottom bar holds it on iOS.
                    .overlay(alignment: .bottom) {
                        folderMenu
                            .padding(.bottom, Self.folderMenuMargin)
                    }
                Divider()
                confirmationFooter(for: confirming)
            } else {
                header
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer
            }
        }
        #else
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Add Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(item: $confirming) { result in
                confirmation(for: result)
                    .navigationTitle("Add Record")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            if editor?.isWorking == true {
                                ProgressView()
                            } else {
                                addButton(for: result)
                            }
                        }
                        ToolbarItem(placement: .bottomBar) { folderMenu }
                    }
            }
        }
        #endif
    }

    /// No title: the sheet is a search field and what it finds. "Find a Release" already sits in
    /// the empty state, where the eye goes, and once results arrive the query is the context. A
    /// label repeating it above the field only crowds the control it introduces.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            if let message = noTokenMessage {
                banner(message)
            }
        }
        .padding(headerPadding)
    }

    private var headerPadding: CGFloat {
        #if os(macOS)
        14
        #else
        12
        #endif
    }

    private var fieldPadding: CGFloat {
        #if os(macOS)
        8
        #else
        6
        #endif
    }

    #if os(macOS)
    /// The way out on the left in both steps, and Add Record on the right once a release is picked,
    /// so no button takes the place of another when the step changes.
    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
        }
        .padding(12)
    }

    /// Escape steps back to the results, the way Back would; from there it closes the sheet.
    private func confirmationFooter(for result: SearchResult) -> some View {
        HStack(spacing: 12) {
            Button("Back") { confirming = nil }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if editor?.isWorking == true {
                ProgressView().controlSize(.small)
            }
            addButton(for: result)
                .keyboardShortcut(.defaultAction)
        }
        .disabled(editor?.isWorking ?? false)
        .padding(12)
    }

    /// The space under the folder menu, and the room the page leaves at its end so the menu does
    /// not cover the credit. The margin matches the 24 pt the credit keeps below itself, and the
    /// clearance is that margin plus the menu's 32 pt height, so the menu sits as far from the
    /// credit as from the footer.
    private static let folderMenuMargin: CGFloat = 24
    private static let folderMenuClearance: CGFloat = 56
    #endif

    /// The folder the add goes to, named in full: it follows the folder on screen when the sheet
    /// opened, which may not be the one the user expects. In the bottom bar on iOS; on the Mac a
    /// glass capsule of its own, so both read the same.
    private var folderMenu: some View {
        Menu {
            Picker("Folder", selection: $targetFolderID) {
                ForEach(targets) { folder in
                    Text(folder.name).tag(folder.id)
                }
            }
            // Inline: in a macOS menu a picker otherwise nests its folders in a submenu.
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text("Folder").foregroundStyle(.secondary)
                Text(targets.first { $0.id == targetFolderID }?.name ?? "")
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            #if os(macOS)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(.capsule)
            #endif
        }
        #if os(macOS)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .capsule)
        #endif
        .disabled(editor?.isWorking ?? false)
    }

    @ViewBuilder
    private func confirmation(for result: SearchResult) -> some View {
        if let preview = session.preview, preview.releaseID == result.id {
            #if os(macOS)
            ReleaseConfirmation(
                result: result,
                preview: preview,
                isWorking: editor?.isWorking ?? false,
                bottomClearance: Self.folderMenuClearance
            )
            #else
            ReleaseConfirmation(result: result, preview: preview, isWorking: editor?.isWorking ?? false)
            #endif
        }
    }

    /// "Add" on iOS, where the navigation title beside it already says "Add Record".
    private func addButton(for result: SearchResult) -> some View {
        #if os(iOS)
        let label = "Add"
        #else
        let label = "Add Record"
        #endif
        return Button(label) { Task { await add(result) } }
            .disabled(editor?.isWorking ?? false)
    }

    /// An explicit field and button rather than `.searchable`: the toolbar search field's submit
    /// action does not fire reliably inside a sheet on macOS, which left the view with no way to
    /// start a search and no sign that anything was wrong.
    ///
    /// Return runs the search, so the button is the discoverable spelling of a shortcut rather
    /// than the primary action of the sheet — picking a result is — and it is styled to match.
    private var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Artist, title, or catalog number", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(startSearch)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, fieldPadding)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))

            Button("Search", action: startSearch)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
        }
    }

    private var isSearching: Bool { state == .searching }

    private func startSearch() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Never fail silently: an unreachable client looks exactly like a search that did nothing.
        guard let search else {
            noTokenMessage = "Connect to Discogs to continue."
            return
        }
        noTokenMessage = nil
        search.search(query)
    }

    private func banner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            ContentUnavailableView(
                "Find a Release",
                systemImage: "magnifyingglass",
                description: Text("Search Discogs for the release you own.")
            )
        case .searching:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Search Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", action: startSearch)
            }
        case .loaded(let total) where results.isEmpty:
            ContentUnavailableView.search(text: query)
                .overlay(alignment: .bottom) {
                    if total > 0 { Text("No matching releases").font(.footnote) }
                }
        case .loaded:
            List {
                Section {
                    ForEach(results) { result in
                        Button { confirm(result) } label: {
                            SearchResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                        .disabled(editor?.isWorking ?? false)
                        .rowHoverHighlight(id: result.id, hovered: $hoveredResultID)
                    }
                    if let search, search.hasMore || search.isLoadingMore || search.loadMoreFailed {
                        MoreResultsRow(search: search)
                    }
                }
                // For what was searched, not what the field says now.
                DiscogsCredit(
                    destination: DiscogsNotice.searchURL(query: search?.submittedQuery ?? query),
                    slack: resultsCreditSlack
                )
                .creditRow()
            }
            // The list's own trailing margin would add to the space the credit brings.
            .contentMargins(.bottom, 0, for: .scrollContent)
            .creditSlack($resultsCreditSlack)
            // The default style insets the results: on iOS into a card, which under the sheet's own
            // divider reads as a band of dead space; on the Mac with a margin under the last row,
            // which adds to the space the credit brings. Search results belong flush to the edge.
            .listStyle(.plain)
        }
    }

    private func add(_ result: SearchResult) async {
        guard let editor else { return }
        // The editor checks the fetch is of this release.
        if await editor.add(result, folderID: targetFolderID, fetched: session.preview?.loader.fetched) {
            dismiss()
        }
    }
}

/// The release laid out the way its record page will show it, so the edition can be checked
/// before it is added. The folder to add it to floats over the page's lower edge.
///
/// The header shows the search result, the row that was tapped, until the release fetch adds the
/// country and the full release date. A view of its own: on iOS the page is a navigation
/// destination, whose content is built outside the sheet's body, so the sheet would not redraw
/// it when the fetch lands.
private struct ReleaseConfirmation: View {
    let result: SearchResult
    let preview: AddRecordSession.Preview
    let isWorking: Bool
    /// Room left under the credit for a control floating over the page's lower edge.
    var bottomClearance: CGFloat = 0

    @Environment(AppServices.self) private var services
    /// The visible height, which keeps the credit on the bottom edge. See `creditViewport(_:)`.
    @State private var viewportHeight: CGFloat = 0

    private var loader: ReleaseDetailLoader { preview.loader }
    private var images: ReleaseImages { preview.images }

    var body: some View {
        let detail = loader.snapshot
        let imageSources = ReleaseImages.sources(detail: detail, cover: result.artwork.url)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 28) {
                    ReleaseHeader(
                        releaseID: result.id,
                        cover: result.artwork,
                        title: result.releaseTitle,
                        artist: result.artistName ?? "Unknown artist",
                        facts: Fact.present([
                            (Fact.label, result.label.first),
                            (Fact.catalogNumber, result.catno),
                            (Fact.format, result.formatDisplayName),
                            (Fact.country, detail?.country ?? result.country),
                            (Fact.released, detail?.releasedDisplay ?? result.year.map(String.init)),
                        ]),
                        genres: result.genre,
                        styles: result.style,
                        gallery: CoverGallery(count: imageSources.count, isLoading: images.isLoading) {
                            images.open(
                                releaseID: result.id,
                                title: result.releaseTitle,
                                sources: imageSources,
                                imageCache: services.imageCache
                            )
                        }
                    )
                    ReleaseSections(loader: loader, releaseID: result.id)
                    if let staleSince = loader.staleSince {
                        StaleDetailsLabel(since: staleSince)
                    }
                }
                Spacer(minLength: 0)
                // The search results' credit is gone once this step replaces them.
                DiscogsCredit(
                    destination: detail?.discogsURL.flatMap(URL.init(string:)) ?? DiscogsNotice.releaseURL(id: result.id)
                )
            }
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding([.horizontal, .top], padding)
            .padding(.bottom, bottomClearance)
            .frame(minHeight: viewportHeight)
        }
        .creditViewport($viewportHeight)
        .disabled(isWorking)
        .releaseImages(images)
        .task(id: result.id) {
            await loader.load(releaseID: result.id)
            await loader.keepFresh(releaseID: result.id)
        }
    }

    private var padding: CGFloat {
        #if os(macOS)
        28
        #else
        20
        #endif
    }
}

/// The last row of the results while Discogs has more: how many are shown, and the way to the next
/// page. Each page is a request against the rate limit, so it loads only when asked.
private struct MoreResultsRow: View {
    let search: ReleaseSearchController

    var body: some View {
        HStack(spacing: 12) {
            if search.loadMoreFailed {
                Text("More results could not be loaded.")
                    .foregroundStyle(.secondary)
                Button("Try Again") { search.loadMore() }
            } else {
                if case .loaded(let total) = search.state {
                    Text("Showing \(search.results.count) of \(total)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if search.isLoadingMore {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Show More") { search.loadMore() }
                }
            }
        }
        // Bordered: in an iOS list row a plain button draws as primary text and reads as a label.
        .buttonStyle(.bordered)
        .font(.callout)
        .frame(maxWidth: .infinity)
        // The space below belongs to the credit that follows. See `DiscogsCredit`.
        .padding(.top, 18)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }
}

private struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        ReleaseRow(
            releaseID: result.id,
            remoteURL: result.thumb,
            kind: .thumb,
            title: result.releaseTitle,
            artist: result.artistName ?? "Unknown artist",
            details: result.editionDetails
        )
    }
}

private extension SearchResult {
    /// The best artwork search offers, and the cache slot it belongs in. See
    /// `CachedCollectionItem.artwork` for why the kind follows the URL.
    var artwork: (url: String?, kind: ImageCache.Kind) {
        if let coverImage, !coverImage.isEmpty { return (coverImage, .cover) }
        return (thumb, .thumb)
    }

    /// The details that separate one edition from another. Richer than the collection's row:
    /// picking the right one out of a page of near-identical results is what the label and catalog
    /// number are for.
    ///
    /// The results and the second step both draw `SearchResultRow`, so the second step describes
    /// the row that was tapped.
    var editionDetails: String {
        ReleaseRow.details([
            year.map(String.init),
            country,
            label.first,
            catno,
            formatDisplayName,
        ])
    }
}
