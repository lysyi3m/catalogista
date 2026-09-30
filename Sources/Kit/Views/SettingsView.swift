import DiscogsKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// App settings: what is cached, which account it came from, and the notices about both.
///
/// macOS presents these as tabs in the Settings window; iOS as sections in a sheet.
public struct SettingsView: View {
    /// Called after signing out, so the presenter can close itself.
    var onSignedOut: () -> Void

    public init(onSignedOut: @escaping () -> Void = {}) {
        self.onSignedOut = onSignedOut
    }

    public var body: some View {
        #if os(macOS)
        TabView {
            CollectionSettingsView()
                .tabItem { Label("Collection", systemImage: "square.grid.2x2") }
            AccountSettingsView(onSignedOut: onSignedOut)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        // Tall enough for the Collection tab, which is the longest of the three; a short window
        // hides its first section behind the tab bar.
        .frame(width: 520, height: 420)
        #else
        NavigationStack {
            Form {
                CollectionSettingsView()
                AccountSettingsView(onSignedOut: onSignedOut)
                AboutSettingsView()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        #endif
    }
}

// MARK: - Collection

/// Cache state and the two manual controls worth having when something looks wrong.
struct CollectionSettingsView: View {
    @Environment(AppServices.self) private var services

    @State private var summary: CacheSummary?
    @State private var isConfirmingReset = false
    @State private var message: String?

    private var syncController: SyncController { services.syncController }

    private struct CacheSummary: Equatable {
        var items: Int
        var folders: Int
        var images: ImageCache.Statistics
    }

    private var isWorking: Bool { syncController.isSyncing }

    var body: some View {
        content
            .task { await refreshSummary() }
            .confirmationDialog(
                "Reset the cache?",
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button("Reset Cache", role: .destructive) {
                    Task { await resetAndResync() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This downloads your collection again. Your collection on Discogs will not change.")
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        Form {
            sections
        }
        .formStyle(.grouped)
        #else
        sections
        #endif
    }

    @ViewBuilder
    private var sections: some View {
        Section("Sync") {
            LabeledContent("Last Synced", value: lastSyncedText)
            if let summary {
                LabeledContent("Records", value: "\(summary.items)")
                LabeledContent("Folders", value: "\(summary.folders)")
            }
        }

        Section("Cover Art") {
            if let summary {
                LabeledContent("Images on Disk", value: "\(summary.images.fileCount)")
                LabeledContent(
                    "Size",
                    value: summary.images.byteCount.formatted(.byteCount(style: .file))
                )
            }
        }

        Section {
            // Both actions on one row, with their own progress beside them: a disabled button is
            // not a progress indicator.
            HStack(spacing: 10) {
                Button("Sync Now") { Task { await syncNow() } }
                    .disabled(isWorking || !services.hasToken)
                Button("Reset Cache…", role: .destructive) { isConfirmingReset = true }
                    .disabled(isWorking || !services.hasToken)

                Spacer(minLength: 8)

                if let activity = syncController.activity {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(activity)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(message)
                }
            }
        }
    }

    private var lastSyncedText: String {
        guard let lastSyncedAt = syncController.lastSyncedAt else { return "Never" }
        return lastSyncedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func syncNow() async {
        message = nil
        await syncController.sync()
        // An offline state without an error message is reported too, rather than passed off as
        // success.
        if let errorMessage = syncController.errorMessage {
            message = errorMessage
        } else if syncController.isOffline {
            message = "Offline"
        } else {
            message = "Synced"
        }
        await refreshSummary()
    }

    private func resetAndResync() async {
        message = nil
        do {
            try await syncController.resetAndResync()
            message = "Cache rebuilt"
        } catch {
            message = error.localizedDescription
        }
        await refreshSummary()
    }

    private func refreshSummary() async {
        summary = CacheSummary(
            items: (try? await services.store.itemCount()) ?? 0,
            folders: CollectionFolders.ordered((try? await services.store.folders()) ?? []).count,
            images: await services.imageCache.statistics()
        )
    }
}

// MARK: - Account

struct AccountSettingsView: View {
    var onSignedOut: () -> Void

    @Environment(AppServices.self) private var services

    @State private var isConfirmingSignOut = false
    @State private var errorMessage: String?

    var body: some View {
        content
            .confirmationDialog(
                "Disconnect this account?",
                isPresented: $isConfirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) { Task { await signOut() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes your token and cached collection from this device. Your collection on Discogs will not change.")
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        Form { sections }.formStyle(.grouped)
        #else
        sections
        #endif
    }

    @ViewBuilder
    private var sections: some View {
        Section("Discogs Account") {
            LabeledContent("Username", value: services.accountUsername ?? "Unknown")
            LabeledContent("Token") {
                Text(services.maskedToken ?? "None")
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            Button("Disconnect Account…", role: .destructive) { isConfirmingSignOut = true }
                .disabled(!services.hasToken)
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
        } footer: {
            Text("Stored securely in this device’s Keychain")
        }
    }

    private func signOut() async {
        do {
            try await services.signOut()
            onSignedOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - About

/// Name and version, the privacy policy, and the affiliation notice the Discogs terms require.
///
/// The notice's wording is fixed by the Discogs API Terms of Use, so it is presented as fine print
/// under the links rather than reworded.
struct AboutSettingsView: View {
    var body: some View {
        #if os(macOS)
        Form { sections }.formStyle(.grouped)
        #else
        sections
        #endif
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            HStack(spacing: 14) {
                #if os(macOS)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                #endif
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.appName).font(.headline)
                    Text(Self.version).font(.callout).foregroundStyle(.secondary)
                }
            }
        }

        Section {
            Link("Privacy Policy", destination: AppLinks.privacyPolicy)
        } footer: {
            Text(DiscogsNotice.affiliation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Catalogista"
    }

    private static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(short) (\(build))"
    }
}
