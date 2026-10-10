import CatalogistaKit
import SwiftUI

#if os(macOS)
import AppKit

/// Refreshes the runtime app icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep AppKit's runtime icon in sync with the compiled asset catalog. During development,
        // Launch Services can otherwise retain the placeholder from an older build at this path.
        // NSWorkspace applies the system icon shape, but reports a 32 pt logical size; correcting
        // that size lets Dock use its high-resolution representations instead of scaling one up.
        if let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath).copy() as? NSImage {
            appIcon.size = NSSize(width: 512, height: 512)
            NSApp.applicationIconImage = appIcon
        }
    }
}
#endif

@main
struct CatalogistaApp: App {
    /// A cache that will not open is a startup state rather than a crash, with a way out: try
    /// again, or rebuild the cache from Discogs.
    private enum Startup {
        case ready(AppServices)
        case failed(String)
    }

    @State private var startup: Startup

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        _startup = State(initialValue: Self.start())
    }

    private static func start() -> Startup {
        do {
            let container = try AppServices.makeModelContainer()
            return .ready(AppServices(modelContainer: container))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    var body: some Scene {
        #if os(macOS)
        // One collection, one window. `Window` drops the window tab bar that `WindowGroup` brings
        // with it, and the `.newItem` group below replaces File ▸ New Window with Add Record….
        Window("Catalogista", id: "collection") {
            rootView
                // Height only. Each screen sets its own minimum width: an outer minimum here would
                // cap the window's, whatever a screen inside needs (`ContentView`).
                .frame(minHeight: 420)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            // ⌘, is wired by the Settings scene below. With a single `Window` scene the New Window
            // item only re-focuses the window that is already open, so ⌘N is free for adding a
            // record — the conventional meaning of New.
            CommandGroup(replacing: .newItem) {
                if case .ready(let services) = startup {
                    Button("Add Record…") { services.commands.requestAdd() }
                        .keyboardShortcut("n", modifiers: .command)
                        .disabled(!services.commands.isAddAvailable)
                }
            }
            CommandGroup(replacing: .singleWindowList) {}
            // View ▸ Show Sidebar, ⌃⌘S.
            SidebarCommands()

            // App Review requires a privacy policy link inside the app (guideline 5.1.1(i)).
            // Replacing the group drops the default Help item on purpose: with no help book, it
            // only shows "Help isn't available for Catalogista."
            CommandGroup(replacing: .help) {
                Link("Privacy Policy", destination: AppLinks.privacyPolicy)
            }

            CommandMenu("Collection") {
                if case .ready(let services) = startup {
                    Button("Sync Now") { services.commands.requestSync() }
                        .keyboardShortcut("r", modifiers: .command)
                    Divider()
                    // Searches the folder on screen, so the item cannot name one.
                    Button("Find") { services.commands.requestFind() }
                        .keyboardShortcut("f", modifiers: .command)
                    // ⌘Y, as Quick Look in the Finder.
                    Button("Show Images") { services.commands.requestImages() }
                        .keyboardShortcut("y", modifiers: .command)
                        .disabled(!services.commands.isShowImagesAvailable)
                }
            }
        }
        Settings {
            if case .ready(let services) = startup {
                SettingsView {
                    // Signing out returns the app to onboarding; the Settings window has nothing
                    // left to show.
                    NSApp.keyWindow?.close()
                }
                .environment(services)
                .modelContainer(services.modelContainer)
            }
        }
        #else
        WindowGroup {
            rootView
        }
        #endif
    }

    @ViewBuilder
    private var rootView: some View {
        switch startup {
        case .ready(let services):
            ContentView()
                .environment(services)
                .modelContainer(services.modelContainer)
        case .failed(let message):
            failureView(message)
                #if os(macOS)
                .frame(minWidth: 560)
                #endif
        }
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Cache Unavailable", systemImage: "externaldrive.badge.xmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { startup = Self.start() }
            // The cache holds nothing Discogs does not, so rebuilding loses nothing. The next
            // sync downloads the collection; the token in the Keychain stays.
            Button("Rebuild Cache") {
                do {
                    try AppServices.discardModelStore()
                    startup = Self.start()
                } catch {
                    startup = .failed(error.localizedDescription)
                }
            }
        }
    }
}
