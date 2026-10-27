import DiscogsKit
import Foundation
import SwiftData

/// One track, stored inline on the release. Codable so SwiftData can persist the array as an
/// attribute rather than a relationship — tracks have no identity of their own and are only ever
/// read as a whole list.
struct CachedTrack: Codable, Sendable, Hashable {
    var position: String
    var title: String
    var duration: String
    var isTrack: Bool

    init(from track: Track) {
        position = track.position
        title = track.title
        duration = track.duration
        isTrack = track.isTrack
    }
}

/// The full release behind a record, fetched on first open and again once it passes
/// `Freshness.maximumAge`.
///
/// Keyed by `releaseID`, not `instanceID`: two copies of the same release share one cached detail.
@Model
final class CachedReleaseDetail {
    @Attribute(.unique) var releaseID: Int
    var title: String
    var artistName: String
    var year: Int?
    var released: String?
    var country: String?
    var notes: String?
    var formatSummary: String
    var labelName: String?
    var catalogNumber: String?
    var genres: [String]
    var styles: [String]
    var tracks: [CachedTrack]
    var coverURL: String?
    /// Every image of the release, the cover first. The record page's image viewer shows them.
    /// Nil in a copy stored before the app kept them, which is fetched again.
    var imageURLs: [String]?
    var discogsURL: String?
    /// When this release was fetched. A release older than `Freshness.maximumAge` is fetched again.
    var fetchedAt: Date

    convenience init(from release: Release, fetchedAt: Date = .now) {
        self.init(ReleaseDetailSnapshot(from: release, fetchedAt: fetchedAt))
    }

    init(_ detail: ReleaseDetailSnapshot) {
        releaseID = detail.releaseID
        title = detail.title
        artistName = detail.artistName
        year = detail.year
        released = detail.released
        country = detail.country
        notes = detail.notes
        formatSummary = detail.formatSummary
        labelName = detail.labelName
        catalogNumber = detail.catalogNumber
        genres = detail.genres
        styles = detail.styles
        tracks = detail.tracks
        coverURL = detail.coverURL
        imageURLs = detail.imageURLs
        discogsURL = detail.discogsURL
        fetchedAt = detail.fetchedAt
    }

    func update(from release: Release, fetchedAt: Date = .now) {
        let detail = ReleaseDetailSnapshot(from: release, fetchedAt: fetchedAt)
        title = detail.title
        artistName = detail.artistName
        year = detail.year
        released = detail.released
        country = detail.country
        notes = detail.notes
        formatSummary = detail.formatSummary
        labelName = detail.labelName
        catalogNumber = detail.catalogNumber
        genres = detail.genres
        styles = detail.styles
        tracks = detail.tracks
        coverURL = detail.coverURL
        imageURLs = detail.imageURLs
        discogsURL = detail.discogsURL
        self.fetchedAt = detail.fetchedAt
    }

    static func imageURLs(of release: Release) -> [String] {
        let primary = release.primaryImage
        let others = release.images.filter { $0 != primary }
        return ([primary].compactMap(\.self) + others).map(\.uri).filter { !$0.isEmpty }
    }
}

struct ReleaseDetailSnapshot: Sendable, Hashable, Identifiable {
    var releaseID: Int
    var title: String
    var artistName: String
    var year: Int?
    var released: String?
    var country: String?
    var notes: String?
    var formatSummary: String
    var labelName: String?
    var catalogNumber: String?
    var genres: [String]
    var styles: [String]
    var tracks: [CachedTrack]
    var coverURL: String?
    var imageURLs: [String]?
    var discogsURL: String?
    var fetchedAt: Date

    var id: Int { releaseID }

    /// Tracklist entries that are actual tracks, dropping Discogs' headings and index rows.
    var playableTracks: [CachedTrack] { tracks.filter(\.isTrack) }

    /// `released` formatted for display, at whatever precision Discogs actually gave.
    ///
    /// The field is free-form and only loosely ISO-like: `2025-02-28`, `2025-02`, `2025`, and
    /// `2025-00-00` for a year-only release all occur. Zero month and day components mean "not
    /// known", so they are dropped rather than clamped to January 1st. Anything unparseable is
    /// shown as Discogs sent it.
    var releasedDisplay: String? { releasedDisplay(locale: .autoupdatingCurrent) }

    func releasedDisplay(locale: Locale) -> String? {
        guard let raw = released?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }

        let parts = raw.split(separator: "-").map(String.init)
        guard let year = parts.first.flatMap(Int.init), year > 0 else { return raw }

        var components = DateComponents()
        components.year = year
        if parts.count > 1, let month = Int(parts[1]), (1...12).contains(month) {
            components.month = month
            if parts.count > 2, let day = Int(parts[2]), (1...31).contains(day) {
                components.day = day
            }
        }

        // Discogs dates are Gregorian; the user's own calendar applies only to the display.
        guard let date = Calendar(identifier: .gregorian).date(from: components) else { return raw }
        if components.day != nil {
            return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: locale.calendar))
        }
        if components.month != nil {
            return date.formatted(Date.FormatStyle(locale: locale, calendar: locale.calendar).month(.abbreviated).year())
        }
        return String(year)
    }
}

extension CachedReleaseDetail {
    var snapshot: ReleaseDetailSnapshot {
        ReleaseDetailSnapshot(
            releaseID: releaseID,
            title: title,
            artistName: artistName,
            year: year,
            released: released,
            country: country,
            notes: notes,
            formatSummary: formatSummary,
            labelName: labelName,
            catalogNumber: catalogNumber,
            genres: genres,
            styles: styles,
            tracks: tracks,
            coverURL: coverURL,
            imageURLs: imageURLs,
            discogsURL: discogsURL,
            fetchedAt: fetchedAt
        )
    }
}

extension ReleaseDetailSnapshot {
    /// A release as fetched, for a page that shows it without storing it.
    init(from release: Release, fetchedAt: Date) {
        releaseID = release.id
        title = release.title
        artistName = release.artistDisplayName
        year = release.year
        released = release.released
        country = release.country
        notes = release.notes
        formatSummary = release.formatDisplayName
        labelName = release.labels.first?.name
        catalogNumber = release.labels.first?.catno
        genres = release.genres
        styles = release.styles
        tracks = release.tracklist.map(CachedTrack.init)
        coverURL = release.primaryImage?.uri
        imageURLs = CachedReleaseDetail.imageURLs(of: release)
        discogsURL = release.uri
        self.fetchedAt = fetchedAt
    }
}
