import DiscogsKit
import SwiftUI

/// What can be done with one copy: file it in another folder, open its page on Discogs, remove it.
///
/// The record page shows these as a row of buttons and the grid and list as a context menu. Both
/// are built from the parts here, so the two always offer the same actions.
struct RecordActionRow: View {
    let folderID: Int
    let folders: [FolderSnapshot]
    let discogsURL: URL
    let isWorking: Bool
    let onMove: (Int) -> Void
    let onRequestRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                FolderPicker(folderID: folderID, folders: folders, onMove: onMove)
            } label: {
                ActionLabel(
                    FolderPicker.name(of: folderID, among: folders),
                    // Filed in one of the user's folders, or not filed at all.
                    systemImage: folderID == DiscogsFolder.uncategorized ? "folder" : "folder.fill",
                    trailingImage: "chevron.down"
                )
            }
            .menuIndicator(.hidden)
            .disabled(isWorking)
            .accessibilityLabel("Folder: \(FolderPicker.name(of: folderID, among: folders))")

            Link(destination: discogsURL) {
                ActionLabel("View", trailingImage: "arrow.up.right")
            }
            .accessibilityLabel("View on Discogs")

            Menu {
                RemoveButton(isWorking: isWorking, action: onRequestRemove)
            } label: {
                ActionLabel(systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("More")
        }
        .menuStyle(.button)
        .buttonStyle(RecordActionButtonStyle())
        .fixedSize()
    }
}

/// One look for the three actions on every platform, drawn here rather than left to the system:
/// a system-drawn button is the same grey capsule as a genre tag, and a macOS menu button lays out
/// its own label with uneven gaps. Tinted, so the actions read as controls and the tags as labels,
/// as in Music.
private struct RecordActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.tint)
            .frame(height: ActionLabel.height)
            .background(.tint.opacity(configuration.isPressed ? 0.22 : 0.12), in: .capsule)
            .contentShape(.capsule)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// An icon, a title and a trailing glyph, spaced evenly. With no title it is a circle.
private struct ActionLabel: View {
    static let height: CGFloat = 30

    var title: String?
    var systemImage: String?
    var trailingImage: String?

    init(_ title: String? = nil, systemImage: String? = nil, trailingImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.trailingImage = trailingImage
    }

    var body: some View {
        if let title {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
                if let trailingImage {
                    Image(systemName: trailingImage)
                        .font(.caption.weight(.semibold))
                        .padding(.leading, 1)
                }
            }
            .padding(.horizontal, 14)
        } else if let systemImage {
            Image(systemName: systemImage)
                .frame(width: Self.height, height: Self.height)
        }
    }
}

/// The same actions as a context menu, for a cover in the grid or a row in the list.
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
        Picker("Folder", selection: Binding(
            get: { folderID },
            set: { if $0 != folderID { onMove($0) } }
        )) {
            ForEach(folders) { folder in
                Text(folder.name).tag(folder.id)
            }
        }
        .pickerStyle(.inline)
        // The menu around it already says what the list is: the folder button, or "Move to".
        .labelsHidden()
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
