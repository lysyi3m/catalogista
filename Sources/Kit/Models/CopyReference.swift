import CoreTransferable
import UniformTypeIdentifiers

/// A copy picked up from the grid or list, dropped on a folder in the sidebar to move it there.
///
/// Carried as an app-specific type and nothing else, so no other app accepts the drop: a cover
/// dragged out of the window takes no Discogs data with it.
struct CopyReference: Codable, Hashable, Transferable {
    let instanceID: Int
    /// The folder the copy is in, so a drop on that same folder can be refused.
    let folderID: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .catalogistaCopy)
    }
}

extension UTType {
    /// Declared under `UTExportedTypeDeclarations` in `project.yml`.
    static let catalogistaCopy = UTType(exportedAs: "com.mlkshkvch.catalogista.copy")
}

extension CachedCollectionItem {
    var copyReference: CopyReference {
        CopyReference(instanceID: instanceID, folderID: folderID)
    }
}
