import DiscogsKit
import SwiftData
import SwiftUI

public struct ContentView: View {
    @Environment(AppServices.self) private var services

    private var syncController: SyncController { services.syncController }
    @Query private var allItems: [CachedCollectionItem]
    @Query private var cachedFolders: [CachedFolder]

    /// The folder last opened, restored at launch. `DiscogsFolder.all` is Collection.
    @AppStorage("selectedFolder") private var storedFolderID = DiscogsFolder.all
    @AppStorage("isSidebarVisible") private var isSidebarVisible = false
    /// On iPhone the split view is a stack. Opening on the detail column lands on the collection,
    /// with the sidebar one step back, instead of on the folder list.
    @State private var compactColumn = NavigationSplitViewColumn.detail

    @AppStorage("collectionSort") private var sortRaw = CollectionSortOption.default.rawValue
    @AppStorage("collectionSortDirection") private var directionRaw = CollectionSortOption.defaultOrder.rawValue
    @AppStorage("collectionItemWidth") private var itemWidth = 120.0
    @AppStorage("collectionLayout") private var layoutRaw = CollectionLayout.default.rawValue

    @State private var selection: CachedCollectionItem?
    @State private var isAdding = false
    @State private var searchQuery = ""
    @FocusState private var isSearchFocused: Bool
    @State private var editor: CollectionEditor?
    @State private var pendingRemoval: CachedCollectionItem?
    #if os(iOS)
    /// iOS has no Settings scene, so it gets a toolbar button and a sheet instead.
    @State private var isShowingSettings = false
    #endif

    public init() {}

    private var sort: CollectionSortOption {
        CollectionSortOption(rawValue: sortRaw) ?? .default
    }

    private var direction: SortDirection {
        SortDirection(rawValue: directionRaw) ?? CollectionSortOption.defaultOrder
    }

    private var layout: CollectionLayout {
        CollectionLayout(rawValue: layoutRaw) ?? .default
    }

    /// Adding belongs to the collection, not to a record page. The add sheet is presented from the
    /// collection, so a request made on a record page would otherwise wait and open on Back.
    private var canAdd: Bool {
        services.hasToken && selection == nil
    }

    private var folders: [FolderSnapshot] {
        CollectionFolders.ordered(cachedFolders.map(\.snapshot))
    }

    /// The folder on screen. See `CollectionFolders.resolved` for why this never writes back.
    private var folderID: Int {
        CollectionFolders.resolved(storedFolderID, among: folders)
    }

    private var folderName: String {
        folders.first { $0.id == folderID }?.name ?? "Collection"
    }

    private var folderCounts: [Int: Int] {
        CollectionFolders.counts(of: allItems.lazy.map(\.folderID))
    }

    public var body: some View {
        root
            // Menu commands act here, where the state they drive lives.
            .onChange(of: services.commands.addRequests) {
                if canAdd { isAdding = true }
            }
            .onChange(of: canAdd, initial: true) {
                services.commands.isAddAvailable = canAdd
            }
            .onChange(of: services.commands.syncRequests) {
                if services.hasToken { Task { await syncController.sync() } }
            }
            .onChange(of: services.commands.findRequests) {
                if services.hasToken { isSearchFocused = true }
            }
            // A record page belongs to the folder it was opened from.
            .onChange(of: folderID) { selection = nil }
            .task {
                if editor == nil { editor = services.makeEditor() }
                // On-launch delta, skipped when a sync ran moments ago.
                if syncController.shouldSyncOnLaunch { await syncController.sync() }
                // Then re-sync whenever the collection passes six hours old, for as long as the
                // window is open.
                await syncController.keepFresh()
            }
            // Matches the record page: raised from a context menu, a confirmation dialog is
            // presented as a popover anchored to that menu and inherits its width.
            .alert(
                "Remove this copy?",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                presenting: pendingRemoval
            ) { item in
                Button("Remove from Collection", role: .destructive) {
                    Task { await editor?.remove(instanceID: item.instanceID) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text("\(item.artistName) — \(item.title)\nThis removes the copy from Discogs.")
            }
            .collectionFailureAlert(editor)
    }

    /// Onboarding has nothing to put in a sidebar, so the split view appears only with a token.
    @ViewBuilder
    private var root: some View {
        if services.hasToken {
            NavigationSplitView(
                columnVisibility: sidebarVisibility,
                preferredCompactColumn: $compactColumn
            ) {
                sidebar
            } detail: {
                detail
            }
        } else {
            detail
        }
    }

    /// Remembered as shown or hidden. Every other visibility the system reports means shown.
    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { isSidebarVisible ? .all : .detailOnly },
            set: { isSidebarVisible = $0 != .detailOnly }
        )
    }

    private var sidebar: some View {
        List(selection: Binding<Int?>(
            get: { folderID },
            set: { storedFolderID = $0 ?? DiscogsFolder.all }
        )) {
            Label("Collection", systemImage: "square.stack")
                .badge(allItems.count)
                .tag(DiscogsFolder.all)
            if !folders.isEmpty {
                Section("Folders") {
                    ForEach(folders) { folder in
                        Label(folder.name, systemImage: "folder")
                            .badge(folderCounts[folder.id] ?? 0)
                            .tag(folder.id)
                    }
                }
            }
        }
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        #endif
    }

    private var detail: some View {
        NavigationStack {
            content
                // Without this the empty and loading states size to their own content, and the
                // bottom bar rides up with them instead of staying at the window edge.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // First run has no collection to title, and "Collection" above "Welcome to
                // Catalogista" reads as a stray label.
                .navigationTitle(services.hasToken ? folderName : "")
                #if os(iOS)
                .navigationBarTitleDisplayMode(services.hasToken ? .large : .inline)
                // Where iOS puts sync state, the way Mail does. The phone has no status bar of its
                // own, and a failed refresh is not worth an alert: the cache is still browsable.
                .navigationSubtitle(syncSubtitle)
                #endif
                .toolbar { toolbarContent }
                // Filters the cached collection as you type; the add sheet is what searches
                // Discogs itself.
                .modifier(
                    CollectionSearchField(
                        isEnabled: services.hasToken,
                        prompt: "Find in \(folderName)",
                        text: $searchQuery,
                        isFocused: $isSearchFocused
                    )
                )
                #if os(macOS)
                .modifier(WindowChrome(statusBar: statusBar))
                #endif
                .navigationDestination(item: $selection) { item in
                    RecordDetailView(item: item)
                        #if os(macOS)
                        .modifier(WindowChrome(statusBar: statusBar))
                        #endif
                }
                .sheet(isPresented: $isAdding) {
                    AddRecordView(folderID: folderID)
                        .environment(services)
                        .modelContainer(services.modelContainer)
                }
                #if os(iOS)
                .sheet(isPresented: $isShowingSettings) {
                    SettingsView { isShowingSettings = false }
                        .environment(services)
                        .modelContainer(services.modelContainer)
                }
                #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        if !services.hasToken {
            SetupView { Task { await syncController.sync() } }
        } else if allItems.isEmpty, syncController.isSyncing {
            // First sync on a fresh install: an empty grid with a spinner beats an empty-state
            // screen that is about to be wrong.
            VStack(spacing: 12) {
                ProgressView()
                Text(initialSyncStatus).font(.callout).foregroundStyle(.secondary)
            }
        } else if allItems.isEmpty {
            ContentUnavailableView {
                Label("No Records", systemImage: "square.stack")
            } description: {
                Text("Sync to download your Discogs collection.")
            } actions: {
                Button("Sync Now") { Task { await syncController.sync() } }
                    .disabled(syncController.isSyncing)
                Button("Add a Record") { isAdding = true }
            }
        } else {
            CollectionView(
                folderID: folderID,
                folderName: folderName,
                layout: layout,
                sort: sort,
                direction: direction,
                itemWidth: itemWidth,
                searchQuery: searchQuery,
                onSelect: { selection = $0 },
                onRequestRemove: { pendingRemoval = $0 }
            )
            // A fresh view per folder, so a new folder opens at the top rather than at the
            // previous folder's scroll offset.
            .id(folderID)
            .refreshable { await syncController.sync() }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !services.hasToken {
            // macOS only builds a window toolbar when something is in it. With no items, the
            // onboarding window falls back to a short plain title bar and the window visibly
            // changes shape once a token is entered. A spacer gives the toolbar something to hold
            // without drawing a control or the divider a placeholder item would.
            ToolbarSpacer(.flexible)
        }
        if services.hasToken {
            addButton
            sortMenu
            // Syncing is a command, not a control: it lives on ⌘R, the Collection menu, and
            // pull-to-refresh. A permanent button for something used a few times a month is noise.
            #if os(iOS)
            settingsButton
            #endif
        }
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private var settingsButton: some ToolbarContent {
        ToolbarItem {
            Button {
                isShowingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
    #endif

    @ToolbarContentBuilder
    private var addButton: some ToolbarContent {
        ToolbarItem {
            Button {
                isAdding = true
            } label: {
                Label("Add Record", systemImage: "plus")
            }
        }
    }

    @ToolbarContentBuilder
    private var sortMenu: some ToolbarContent {
        ToolbarItem {
            Menu {
                // Inline, so the keys and the direction sit in one flat menu with checkmarks.
                // A plain picker in a menu becomes a submenu, which buries a two-click choice.
                Picker("View", selection: $layoutRaw) {
                    ForEach(CollectionLayout.allCases) { option in
                        Label(option.label, systemImage: option.symbol).tag(option.rawValue)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Picker("Sort By", selection: $sortRaw) {
                    ForEach(CollectionSortOption.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Picker("Order", selection: $directionRaw) {
                    ForEach(SortDirection.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("View Options", systemImage: "line.3.horizontal.decrease")
            }
            // The menu is the control; the chevron beside it on macOS is redundant chrome.
            .menuIndicator(.hidden)
        }
    }

    #if os(iOS)
    /// The same reading as the macOS status bar: a sync in flight, a problem, or when it last worked.
    private var syncSubtitle: String {
        guard services.hasToken else { return "" }
        if let progress = syncController.progress {
            return "Syncing \(progress.itemsFetched) of \(progress.totalItems)"
        }
        if syncController.isSyncing { return "Syncing…" }
        if let errorMessage = editor?.errorMessage ?? syncController.errorMessage { return errorMessage }
        if syncController.isOffline { return offlineStatus }
        guard let lastSyncedAt = syncController.lastSyncedAt else { return "Not synced yet" }
        return "Updated \(lastSyncedAt.formatted(.relative(presentation: .named)))"
    }
    #endif

    /// Offline, the cache stays on screen, so its age is part of the status: the Discogs terms
    /// bound how stale displayed data may be. See `Freshness`.
    private var offlineStatus: String {
        guard let lastSyncedAt = syncController.lastSyncedAt else { return "Offline" }
        return "Offline · updated \(lastSyncedAt.formatted(.relative(presentation: .named)))"
    }

    private var initialSyncStatus: String {
        guard let progress = syncController.progress else { return "Fetching collection…" }
        return "\(progress.itemsFetched) of \(progress.totalItems) records"
    }

    // The bottom bar is a desktop affordance: a window has the room for a persistent strip of
    // state, and grid density only makes sense where the window can be any width. On a phone the
    // grid is two columns wide by definition, pull-to-refresh reports the sync, and the bar is
    // a stolen row.
    #if os(macOS)

    /// One row: what you can change on the left, what is happening on the right.
    @ViewBuilder
    private var statusBar: some View {
        if services.hasToken {
            VStack(spacing: 0) {
                // Without this the bar is invisible against the record page's light background.
                Divider()
                barContents
            }
            .background(.bar)
        }
    }

    private var barContents: some View {
        HStack(spacing: 12) {
            // The density control sizes grid cells, so it goes away on the record page and in the
            // list, which has nothing to size.
            if selection == nil, layout == .grid { densityControls }
            Spacer(minLength: 12)
            syncStatus
        }
        // Overlaid rather than placed between the two, so it centres on the bar itself and does
        // not drift as the status text changes length.
        .overlay {
            if selection == nil { count }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 28)
    }

    private var count: some View {
        countLabel
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// Reads as a plain count of the folder on screen, and says how much of it is showing while a
    /// search narrows it. Built as `Text` so the inflection markup is resolved.
    @ViewBuilder
    private var countLabel: some View {
        if searchQuery.isEmpty {
            Text("^[\(folderCount) record](inflect: true)")
        } else {
            Text("\(matchCount) of \(folderCount)")
        }
    }

    private var folderCount: Int {
        folderID == DiscogsFolder.all ? allItems.count : folderCounts[folderID] ?? 0
    }

    private var matchCount: Int {
        let predicate = CachedCollectionItem.predicate(inFolder: folderID, matching: searchQuery)
        return allItems.filter { (try? predicate.evaluate($0)) ?? false }.count
    }

    private var densityControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.3x3.fill").imageScale(.small)
            Slider(value: $itemWidth, in: 60...260)
                .frame(width: 140)
                .controlSize(.small)
            Image(systemName: "square.fill").imageScale(.small)
        }
        .foregroundStyle(.secondary)
    }

    /// Always says something: a sync in flight, a problem, or when it last worked.
    @ViewBuilder
    private var syncStatus: some View {
        if let progress = syncController.progress {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Syncing \(progress.itemsFetched) of \(progress.totalItems)")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        } else if syncController.isSyncing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Syncing…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let errorMessage = editor?.errorMessage ?? syncController.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(errorMessage)
        } else if syncController.isOffline {
            Label(offlineStatus, systemImage: "wifi.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if let lastSyncedAt = syncController.lastSyncedAt {
            Text("Synced \(lastSyncedAt.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("Not synced yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    #endif
}

/// The macOS status bar, applied to each page of the detail stack.
///
/// A page pushed inside a split view's detail column does not inherit modifiers applied outside
/// its `NavigationStack`, so the record page needs it as much as the collection does.
#if os(macOS)
private struct WindowChrome<StatusBar: View>: ViewModifier {
    let statusBar: StatusBar

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) { statusBar }
    }
}
#endif

extension View {
    /// Keeps covers from showing through the macOS toolbar as they scroll under it.
    ///
    /// A hard scroll edge rather than an opaque toolbar background: the background spans the
    /// window and cuts the top off the sidebar. Applied to each scroll view, because the style does
    /// not reach a scroll view from a container around it.
    func detailScrollEdge() -> some View {
        #if os(macOS)
        scrollEdgeEffectStyle(.hard, for: .top)
        #else
        self
        #endif
    }
}

/// The search field, present only once there is a collection to search. It searches the folder on
/// screen, and the query stays as the user moves between folders.
///
/// `.searchable` cannot be applied conditionally on its own. Applied unconditionally, it puts a
/// search field on the onboarding screen, where there is nothing to search.
private struct CollectionSearchField: ViewModifier {
    let isEnabled: Bool
    let prompt: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .searchable(text: $text, placement: .toolbar, prompt: Text(prompt))
                .searchFocused(isFocused)
        } else {
            content
        }
    }
}

#Preview {
    let container = try! AppServices.makeModelContainer(inMemory: true)
    return ContentView()
        .environment(AppServices(modelContainer: container))
        .modelContainer(container)
}
