import DiscogsKit
import Foundation

/// Sendable value copies of the cache models.
///
/// `@Model` classes are bound to the `ModelContext` that fetched them and are not `Sendable`, so
/// `CollectionStore` hands out snapshots rather than live objects. SwiftUI reads live models on the
/// main actor through `@Query`; everything crossing an isolation boundary uses these.
struct CollectionItemSnapshot: Sendable, Hashable, Identifiable {
    var instanceID: Int
    var releaseID: Int
    var folderID: Int
    var dateAdded: Date?
    var rating: Int
    var title: String
    var artistName: String
    var year: Int?
    var thumbURL: String?
    var coverURL: String?
    var formatSummary: String
    var labelName: String?
    var catalogNumber: String?
    var genres: [String]
    var styles: [String]
    var fieldValues: [FieldValue]

    var id: Int { instanceID }
}

struct FolderSnapshot: Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var count: Int
}

extension CachedCollectionItem {
    var snapshot: CollectionItemSnapshot {
        CollectionItemSnapshot(
            instanceID: instanceID,
            releaseID: releaseID,
            folderID: folderID,
            dateAdded: dateAdded,
            rating: rating,
            title: title,
            artistName: artistName,
            year: year,
            thumbURL: thumbURL,
            coverURL: coverURL,
            formatSummary: formatSummary,
            labelName: labelName,
            catalogNumber: catalogNumber,
            genres: genres,
            styles: styles,
            fieldValues: fieldValues
        )
    }
}

extension CachedFolder {
    var snapshot: FolderSnapshot {
        FolderSnapshot(id: id, name: name, count: count)
    }
}
