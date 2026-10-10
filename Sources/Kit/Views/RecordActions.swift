import DiscogsKit
import SwiftUI

/// The folder a copy is in, as a menu that moves it: the first value of the record page's Copy
/// section. Drawn in the accent colour so it reads as a control beside plain-text values.
struct FolderMenu: View {
    let folderID: Int
    let folders: [FolderSnapshot]
    let isWorking: Bool
    let onMove: (Int) -> Void

    var body: some View {
        Menu {
            FolderPicker(folderID: folderID, folders: folders, onMove: onMove)
        } label: {
            // One text, not a stack: macOS makes each view of a plain menu label a control of its
            // own, so a stack became three menu buttons.
            Text("""
                \(Image(systemName: folderID == DiscogsFolder.uncategorized ? "folder" : "folder.fill")) \
                \(FolderPicker.name(of: folderID, among: folders)) \
                \(Text(Image(systemName: "chevron.down")).font(.caption2.weight(.semibold)))
                """)
                .lineLimit(1)
                // Keeps the icon and the chevron when a long folder name has to shorten.
                .truncationMode(.middle)
                .foregroundStyle(.tint)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // As wide as the name needs and no wider than the column: a long folder name truncates
        // rather than spreading over the next value in the Copy grid.
        .fixedSize(horizontal: false, vertical: true)
        .disabled(isWorking)
        .accessibilityLabel("Folder: \(FolderPicker.name(of: folderID, among: folders))")
    }
}

struct RecordMenu: View {
    let discogsURL: URL
    let isWorking: Bool
    let onShowImages: () -> Void
    let onRequestRemove: () -> Void

    var body: some View {
        Menu {
            Button("Show Images", systemImage: "photo.on.rectangle", action: onShowImages)
            Link(destination: discogsURL) {
                Label("View on Discogs", systemImage: "arrow.up.right.square")
            }
            Divider()
            RemoveButton(isWorking: isWorking, action: onRequestRemove)
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
    }
}

/// What can be done with one copy, as a context menu for a cover in the grid or a row in the list:
/// the record page's folder menu and toolbar menu together.
struct RecordContextMenu: View {
    let folderID: Int
    let folders: [FolderSnapshot]
    let discogsURL: URL
    let onOpen: () -> Void
    let onMove: (Int) -> Void
    let onRequestRemove: () -> Void

    var body: some View {
        Button("Open", action: onOpen)
        Menu("Move to", systemImage: "folder") {
            FolderPicker(folderID: folderID, folders: folders, onMove: onMove)
        }
        Link(destination: discogsURL) {
            Label("View on Discogs", systemImage: "arrow.up.right.square")
        }
        Divider()
        RemoveButton(isWorking: false, action: onRequestRemove)
    }
}

/// Every folder a copy can be filed in, the current one ticked. Choosing another moves the copy
/// at once: a move loses nothing and is undone by choosing again, so it asks for no confirmation.
private struct FolderPicker: View {
    let folderID: Int
    let folders: [FolderSnapshot]
    let onMove: (Int) -> Void

    var body: some View {
        // One picker per section, all on one selection: a menu sets them apart with a separator.
        // A divider among one picker's options is not drawn.
        ForEach(Array(CollectionFolders.menuSections(folders).enumerated()), id: \.offset) { _, section in
            Picker("Folder", selection: Binding(
                get: { folderID },
                set: { if $0 != folderID { onMove($0) } }
            )) {
                ForEach(section) { folder in
                    Text(folder.name).tag(folder.id)
                }
            }
            .pickerStyle(.inline)
            // The menu around it already says what the list is: the folder button, or "Move to".
            .labelsHidden()
        }
    }

    /// A folder the cache does not know yet — created on discogs.com since the last sync — has no
    /// name to show until the next one.
    static func name(of folderID: Int, among folders: [FolderSnapshot]) -> String {
        folders.first { $0.id == folderID }?.name ?? "Folder"
    }
}

private struct RemoveButton: View {
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button("Remove from Collection…", systemImage: "trash", role: .destructive, action: action)
            .disabled(isWorking)
    }
}
