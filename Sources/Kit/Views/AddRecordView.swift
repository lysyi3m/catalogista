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

    @Query private var cachedFolders: [CachedFolder]
    @State private var query = ""
    /// The release picked in the first step. While set, the sheet shows the second step.
    @State private var confirming: SearchResult?
    @State private var targetFolderID = DiscogsFolder.uncategorized
    @State private var editor: CollectionEditor?
    @State private var hoveredResultID: Int?
    /// Room under short results, and the second step's visible height. Both keep the credit on
    /// the bottom edge. See `creditSlack(_:)` and `creditViewport(_:)`.
    @State private var resultsCreditSlack: CGFloat = 0
    @State private var resultsCreditSpacing = ListCreditSpacing()
    @State private var confirmationViewportHeight: CGFloat = 0
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
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 480, idealHeight: 620)
        #endif
        .task {
            editor = editor ?? services.makeEditor()
            if search == nil, let client = services.client {
                search = ReleaseSearchController(client: client)
            }
        }
        .onDisappear { search?.cancel() }
        .collectionFailureAlert(editor)
    }

    private var targets: [FolderSnapshot] {
        CollectionFolders.destinations(cachedFolders.map(\.snapshot))
    }

    private func confirm(_ result: SearchResult) {
        targetFolderID = CollectionFolders.addTarget(for: folderID, among: targets)
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
                ToolbarItem(placement: .bottomBar) { moreResults }
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
    private var footer: some View {
        HStack {
            moreResults
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }
    #endif

    /// How many of the matches are shown, and the way to the next page. In the sheet's bar rather
    /// than the list: as rows under the results, the macOS list drew a separator between them and
    /// the credit whatever the rows asked for.
    @ViewBuilder
    private var moreResults: some View {
        if case .loaded(let total) = state, total > results.count {
            HStack(spacing: 10) {
                Text("Showing \(results.count) of \(total)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if search?.isLoadingMore == true {
                    ProgressView().controlSize(.small)
                } else if search?.hasMore == true {
                    Button("Show More") { search?.loadMore() }
                }
            }
        }
    }
    #if os(macOS)

    /// Escape steps back to the results rather than closing the sheet, the way Back would.
    private func confirmationFooter(for result: SearchResult) -> some View {
        HStack {
            Button("Back") { confirming = nil }
                .keyboardShortcut(.cancelAction)
                .disabled(editor?.isWorking ?? false)
            Spacer()
            if editor?.isWorking == true {
                ProgressView().controlSize(.small)
            }
            addButton(for: result)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
    #endif

    /// The release laid out the way its record page will show it, so the edition can be checked
    /// before it is added, and the folder it goes into.
    ///
    /// Search carries a year but no release date, so Released is absent until the record page
    /// fetches the release.
    private func confirmation(for result: SearchResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 28) {
                    ReleaseHeader(
                        releaseID: result.id,
                        cover: result.artwork,
                        title: result.releaseTitle,
                        artist: result.artistName ?? "Unknown artist",
                        subtitle: ReleaseRow.details([
                            result.year.map(String.init),
                            result.formatDisplayName,
                        ]),
                        tags: result.genre + result.style
                    )
                    EditionFacts([
                        (EditionFacts.label, result.label.first),
                        (EditionFacts.catalogNumber, result.catno),
                        (EditionFacts.country, result.country),
                    ])
                    PageSection("Folder") {
                        Picker("Folder", selection: $targetFolderID) {
                            ForEach(targets) { folder in
                                Text(folder.name).tag(folder.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                Spacer(minLength: 0)
                // The search results' credit is gone once this step replaces them.
                DiscogsCredit(destination: DiscogsNotice.releaseURL(id: result.id))
            }
            .padding([.horizontal, .top], confirmationPadding)
            .frame(minHeight: confirmationViewportHeight)
        }
        .creditViewport($confirmationViewportHeight)
        .disabled(editor?.isWorking ?? false)
    }

    private var confirmationPadding: CGFloat {
        #if os(macOS)
        28
        #else
        20
        #endif
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
                }
                // For what was searched, not what the field says now.
                DiscogsCredit(
                    destination: DiscogsNotice.searchURL(query: search?.submittedQuery ?? query),
                    slack: resultsCreditSlack,
                    listTrailing: resultsCreditSpacing.trailing
                )
                .creditRow(resultsCreditSpacing)
            }
            // The list's own trailing margin would add to the space the credit brings.
            .contentMargins(.bottom, 0, for: .scrollContent)
            .creditSlack($resultsCreditSlack)
            .listCreditSpacing(resultsCreditSpacing)
            #if os(iOS)
            // The default grouped style insets the results into a card, which under the sheet's
            // own divider reads as a band of dead space. Search results belong flush to the edge.
            .listStyle(.plain)
            #endif
        }
    }

    private func add(_ result: SearchResult) async {
        guard let editor else { return }
        if await editor.add(result, folderID: targetFolderID) {
            dismiss()
        }
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
