import DiscogsKit
import Foundation
import SwiftData

/// One owned copy, mirrored from Discogs.
///
/// This is a cache, never the source of truth: a refresh upserts by `instanceID` and drops rows
/// Discogs no longer reports. The `basic_information` snapshot is flattened into stored properties
/// so the grid can sort and render without a per-record call.
@Model
final class CachedCollectionItem {
    /// Identifies the copy. Two copies of the same release share a `releaseID` but not this.
    @Attribute(.unique) var instanceID: Int
    var releaseID: Int
    var folderID: Int
    var dateAdded: Date?
    var rating: Int

    var title: String
    /// Pre-joined artist credit, as Discogs would render it.
    var artistName: String
    var year: Int?
    /// 0 when Discogs reports a year, 1 when it does not, kept in step with `year` at every write.
    ///
    /// Sorting by year has to put the yearless records last whichever direction is chosen — a
    /// column of blanks at the top reads like the sort failed. That needs a second sort key that
    /// always ascends, and `SortDescriptor` needs a `Comparable`, which `Bool` is not. Existing
    /// rows migrate to 0 and are corrected by the next sync.
    var yearRank: Int = 0
    var thumbURL: String?
    var coverURL: String?
    var formatSummary: String
    var labelName: String?
    var catalogNumber: String?
    var genres: [String]
    var styles: [String]
    /// The owner's custom field values on this copy. Existing rows migrate to empty and are
    /// filled by the next sync.
    var fieldValues: [FieldValue] = []

    /// Case-folded sort keys, stored so SwiftData can sort in the store rather than in memory.
    var sortArtist: String
    var sortTitle: String

    init(from item: CollectionItem) {
        instanceID = item.instanceID
        releaseID = item.releaseID
        folderID = item.folderID
        dateAdded = item.dateAdded
        rating = item.rating
        title = item.basicInformation.title
        artistName = item.basicInformation.artistDisplayName
        year = item.basicInformation.year
        yearRank = item.basicInformation.year == nil ? 1 : 0
        thumbURL = item.basicInformation.thumb
        coverURL = item.basicInformation.coverImage
        formatSummary = item.basicInformation.formatDisplayName
        labelName = item.basicInformation.labels.first?.name
        catalogNumber = item.basicInformation.labels.first?.catno
        genres = item.basicInformation.genres
        styles = item.basicInformation.styles
        fieldValues = item.fieldValues
        sortArtist = Self.sortKey(item.basicInformation.artistDisplayName)
        sortTitle = Self.sortKey(item.basicInformation.title)
    }

    /// Builds a row from an optimistic add, before Discogs has confirmed it.
    init(from pending: PendingAddition) {
        instanceID = pending.instanceID
        releaseID = pending.releaseID
        folderID = pending.folderID
        dateAdded = pending.dateAdded
        rating = 0
        title = pending.title
        artistName = pending.artistName
        year = pending.year
        yearRank = pending.year == nil ? 1 : 0
        thumbURL = pending.thumbURL
        coverURL = pending.coverURL
        formatSummary = pending.formatSummary
        labelName = pending.labelName
        catalogNumber = pending.catalogNumber
        genres = pending.genres
        styles = pending.styles
        sortArtist = Self.sortKey(pending.artistName)
        sortTitle = Self.sortKey(pending.title)
    }

    /// Rebuilds a row from a snapshot, so a failed removal can be rolled back exactly.
    init(from snapshot: CollectionItemSnapshot) {
        instanceID = snapshot.instanceID
        releaseID = snapshot.releaseID
        folderID = snapshot.folderID
        dateAdded = snapshot.dateAdded
        rating = snapshot.rating
        title = snapshot.title
        artistName = snapshot.artistName
        year = snapshot.year
        yearRank = snapshot.year == nil ? 1 : 0
        thumbURL = snapshot.thumbURL
        coverURL = snapshot.coverURL
        formatSummary = snapshot.formatSummary
        labelName = snapshot.labelName
        catalogNumber = snapshot.catalogNumber
        genres = snapshot.genres
        styles = snapshot.styles
        fieldValues = snapshot.fieldValues
        sortArtist = Self.sortKey(snapshot.artistName)
        sortTitle = Self.sortKey(snapshot.title)
    }

    /// Replaces the search-derived fields with the release's authoritative ones, after an add.
    func apply(_ release: Release) {
        title = release.title
        artistName = release.artistDisplayName
        year = release.year
        yearRank = year == nil ? 1 : 0
        formatSummary = release.formatDisplayName
        labelName = release.labels.first?.name
        catalogNumber = release.labels.first?.catno
        genres = release.genres
        styles = release.styles
        // Only as a fallback. `cover_image` is 600px at quality 90 and is what both the grid and
        // the record page draw; the release's primary image is the full-size original, several
        // times the bytes for no visible gain. A copy that arrived with a cover keeps it, so the
        // same release looks the same whether it was added here or arrived from a sync.
        if coverURL?.isEmpty != false, let cover = release.primaryImage?.uri { coverURL = cover }
        sortArtist = Self.sortKey(artistName)
        sortTitle = Self.sortKey(title)
    }

    /// Applies a fresh snapshot in place. Discogs wins on every field.
    func update(from item: CollectionItem) {
        releaseID = item.releaseID
        folderID = item.folderID
        dateAdded = item.dateAdded
        rating = item.rating
        title = item.basicInformation.title
        artistName = item.basicInformation.artistDisplayName
        year = item.basicInformation.year
        yearRank = year == nil ? 1 : 0
        thumbURL = item.basicInformation.thumb
        coverURL = item.basicInformation.coverImage
        formatSummary = item.basicInformation.formatDisplayName
        labelName = item.basicInformation.labels.first?.name
        catalogNumber = item.basicInformation.labels.first?.catno
        genres = item.basicInformation.genres
        styles = item.basicInformation.styles
        fieldValues = item.fieldValues
        sortArtist = Self.sortKey(item.basicInformation.artistDisplayName)
        sortTitle = Self.sortKey(item.basicInformation.title)
    }

    /// Matches a record against the folder on screen and what was typed in the search field.
    ///
    /// Defined once and used both as the grid's fetch predicate and, evaluated in Swift, for the
    /// count in the status bar, so the two can never disagree about what matched. Folder 0 is
    /// Collection and matches every copy. `localizedStandardContains` is the search users expect:
    /// case- and diacritic-insensitive, so "bjork" finds "Björk".
    static func predicate(inFolder folderID: Int, matching query: String) -> Predicate<CachedCollectionItem> {
        let all = DiscogsFolder.all
        return #Predicate<CachedCollectionItem> { item in
            (folderID == all || item.folderID == folderID)
                && (query.isEmpty
                    || item.title.localizedStandardContains(query)
                    || item.artistName.localizedStandardContains(query))
        }
    }

    /// The best artwork available, and the cache slot it belongs in.
    ///
    /// Discogs serves the thumb at 150px and quality 40, which the grid draws at up to 260pt —
    /// three times its size on a Retina display. `cover_image` is 600px at quality 90 and costs
    /// about 100 KB, so it is worth using everywhere the art is more than a row icon.
    ///
    /// The kind follows the URL: caching a 150px thumb in the cover slot would fix this release's
    /// cover as a thumb for as long as its URL stands, and nothing would replace it.
    var artwork: (url: String?, kind: ImageCache.Kind) {
        if let coverURL, !coverURL.isEmpty { return (coverURL, .cover) }
        return (thumbURL, .thumb)
    }

    /// Lowercases and drops a leading article so "The Beatles" sorts under B.
    static func sortKey(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for article in ["the ", "a ", "an "] where folded.hasPrefix(article) {
            return String(folded.dropFirst(article.count))
        }
        return folded
    }
}
