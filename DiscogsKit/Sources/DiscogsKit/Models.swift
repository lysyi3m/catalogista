import Foundation

// MARK: - Identity

/// Response of `GET /oauth/identity`: resolves the username the token belongs to.
public struct Identity: Codable, Sendable, Hashable {
    public let id: Int
    public let username: String
    public let resourceURL: String?
    public let consumerName: String?

    enum CodingKeys: String, CodingKey {
        case id, username
        case resourceURL = "resource_url"
        case consumerName = "consumer_name"
    }
}

// MARK: - Pagination

public struct Pagination: Codable, Sendable, Hashable {
    public let page: Int
    public let pages: Int
    public let perPage: Int
    public let items: Int

    public var hasNextPage: Bool { page < pages }

    enum CodingKeys: String, CodingKey {
        case page, pages, items
        case perPage = "per_page"
    }
}

// MARK: - Collection

/// One page of `GET /users/{user}/collection/folders/{folder_id}/releases`.
public struct CollectionPage: Codable, Sendable {
    public let pagination: Pagination
    public let releases: [CollectionItem]
}

/// One owned copy. Discogs models each copy as an *instance* of a release inside a folder, so two
/// copies of the same release are two instances sharing a `releaseID`. Removal keys off
/// `instanceID`.
public struct CollectionItem: Codable, Sendable, Hashable {
    public let instanceID: Int
    public let releaseID: Int
    public let folderID: Int
    public let dateAdded: Date?
    public let rating: Int
    public let basicInformation: BasicInformation
    /// The owner's values for their custom fields on this copy, one per filled-in field. Discogs
    /// calls them notes; see `CustomField` for what each field is.
    public let fieldValues: [FieldValue]

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case releaseID = "id"
        case folderID = "folder_id"
        case dateAdded = "date_added"
        case rating
        case basicInformation = "basic_information"
        case fieldValues = "notes"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instanceID = try container.decode(Int.self, forKey: .instanceID)
        releaseID = try container.decode(Int.self, forKey: .releaseID)
        folderID = try container.decode(Int.self, forKey: .folderID)
        dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded)
        rating = try container.decode(Int.self, forKey: .rating)
        basicInformation = try container.decode(BasicInformation.self, forKey: .basicInformation)
        // Absent on a copy with no field filled in.
        fieldValues = try container.decodeIfPresent([FieldValue].self, forKey: .fieldValues) ?? []
    }
}

/// One custom field's value on one copy.
public struct FieldValue: Codable, Sendable, Hashable {
    public let fieldID: Int
    public let value: String

    public init(fieldID: Int, value: String) {
        self.fieldID = fieldID
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case fieldID = "field_id"
        case value
    }
}

/// A field the owner defined on discogs.com for every copy in their collection, such as Media
/// Condition or a free-text Notes. Created and edited only on discogs.com.
public struct CustomField: Codable, Sendable, Hashable {
    public let id: Int
    public let name: String
    /// `dropdown` for a choice from a fixed list, `textarea` for free text.
    public let type: String
    /// The order discogs.com shows the fields in.
    public let position: Int

    public var isFreeText: Bool { type == "textarea" }

    public init(id: Int, name: String, type: String, position: Int) {
        self.id = id
        self.name = name
        self.type = type
        self.position = position
    }
}

public struct CustomFieldList: Codable, Sendable {
    public let fields: [CustomField]
}

/// The snapshot Discogs embeds in each collection item. Rich enough to render the grid without a
/// per-record call.
public struct BasicInformation: Codable, Sendable, Hashable {
    public let id: Int
    public let title: String
    public let year: Int?
    public let thumb: String?
    public let coverImage: String?
    public let artists: [ArtistCredit]
    public let labels: [LabelCredit]
    public let formats: [Format]
    public let genres: [String]
    public let styles: [String]
    public let masterID: Int?
    public let resourceURL: String?

    /// Artist names joined the way Discogs intends, honouring each credit's `join` phrase.
    public var artistDisplayName: String {
        Self.joinedName(from: artists)
    }

    static func joinedName(from artists: [ArtistCredit]) -> String {
        var result = ""
        for (index, artist) in artists.enumerated() {
            result += artist.displayName
            guard index < artists.count - 1 else { continue }
            let join = artist.join?.trimmingCharacters(in: .whitespaces) ?? ""
            result += join.isEmpty ? ", " : (join == "," ? ", " : " \(join) ")
        }
        return result
    }

    /// e.g. `2 x Vinyl, LP, Album, Reissue`.
    public var formatDisplayName: String {
        formats.map(\.displayName).joined(separator: ", ")
    }

    enum CodingKeys: String, CodingKey {
        case id, title, year, thumb, artists, labels, formats, genres, styles
        case coverImage = "cover_image"
        case masterID = "master_id"
        case resourceURL = "resource_url"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        // Discogs sends 0 for "unknown year"; surface that as nil rather than year zero.
        let rawYear = try container.decodeIfPresent(Int.self, forKey: .year)
        year = (rawYear == 0) ? nil : rawYear
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        coverImage = try container.decodeIfPresent(String.self, forKey: .coverImage)
        artists = try container.decodeIfPresent([ArtistCredit].self, forKey: .artists) ?? []
        labels = try container.decodeIfPresent([LabelCredit].self, forKey: .labels) ?? []
        formats = try container.decodeIfPresent([Format].self, forKey: .formats) ?? []
        genres = try container.decodeIfPresent([String].self, forKey: .genres) ?? []
        styles = try container.decodeIfPresent([String].self, forKey: .styles) ?? []
        masterID = try container.decodeIfPresent(Int.self, forKey: .masterID)
        resourceURL = try container.decodeIfPresent(String.self, forKey: .resourceURL)
    }
}

public struct ArtistCredit: Codable, Sendable, Hashable {
    public let id: Int?
    public let name: String
    /// Artist name variation as credited on this release; preferred over `name` when present.
    public let anv: String?
    /// Phrase linking this credit to the next one, e.g. `&`, `feat.`.
    public let join: String?
    public let role: String?
    public let resourceURL: String?

    public var displayName: String {
        if let anv, !anv.isEmpty { return anv }
        return name
    }

    enum CodingKeys: String, CodingKey {
        case id, name, anv, join, role
        case resourceURL = "resource_url"
    }
}

public struct LabelCredit: Codable, Sendable, Hashable {
    public let id: Int?
    public let name: String
    /// Catalog number.
    public let catno: String?
    public let resourceURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, catno
        case resourceURL = "resource_url"
    }
}

public struct Format: Codable, Sendable, Hashable {
    public let name: String
    /// Disc count, sent as a string.
    public let qty: String?
    public let text: String?
    public let descriptions: [String]

    public var displayName: String {
        var parts: [String] = []
        if let qty, let count = Int(qty), count > 1 {
            parts.append("\(count) x \(name)")
        } else {
            parts.append(name)
        }
        parts.append(contentsOf: descriptions)
        if let text, !text.isEmpty { parts.append(text) }
        return parts.joined(separator: ", ")
    }

    enum CodingKeys: String, CodingKey {
        case name, qty, text, descriptions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        qty = try container.decodeIfPresent(String.self, forKey: .qty)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        descriptions = try container.decodeIfPresent([String].self, forKey: .descriptions) ?? []
    }
}

// MARK: - Folders

public struct FolderList: Codable, Sendable {
    public let folders: [Folder]
}

public struct Folder: Codable, Sendable, Hashable {
    public let id: Int
    public let name: String
    public let count: Int
    public let resourceURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, count
        case resourceURL = "resource_url"
    }
}

// MARK: - Sorting

/// Sort keys accepted by the collection-items endpoint.
public enum CollectionSort: String, Sendable {
    case added
    case artist
    case title
    case year
    case rating
    case label
    case format
    case catno
}

/// Named to avoid colliding with Foundation's `SortOrder`, which `SortDescriptor` uses.
public enum DiscogsSortOrder: String, Sendable {
    case ascending = "asc"
    case descending = "desc"
}

// MARK: - Release detail

/// Full release from `GET /releases/{id}`: everything the collection snapshot leaves out.
public struct Release: Codable, Sendable, Hashable {
    public let id: Int
    public let title: String
    public let year: Int?
    /// Release date as Discogs formats it, e.g. `1980-10-08` or `1980`. Free-form, so kept as text.
    public let released: String?
    public let country: String?
    public let notes: String?
    public let artists: [ArtistCredit]
    public let labels: [LabelCredit]
    public let formats: [Format]
    public let genres: [String]
    public let styles: [String]
    public let tracklist: [Track]
    public let images: [ReleaseImage]
    /// Canonical discogs.com page for this release.
    public let uri: String?

    public var artistDisplayName: String {
        BasicInformation.joinedName(from: artists)
    }

    public var formatDisplayName: String {
        formats.map(\.displayName).joined(separator: ", ")
    }

    /// The cover: the primary image if Discogs marks one, else the first.
    public var primaryImage: ReleaseImage? {
        images.first { $0.type == "primary" } ?? images.first
    }

    enum CodingKeys: String, CodingKey {
        case id, title, year, released, country, notes, artists, labels, formats
        case genres, styles, tracklist, images, uri
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        let rawYear = try container.decodeIfPresent(Int.self, forKey: .year)
        year = (rawYear == 0) ? nil : rawYear
        released = try container.decodeIfPresent(String.self, forKey: .released)
        country = try container.decodeIfPresent(String.self, forKey: .country)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        artists = try container.decodeIfPresent([ArtistCredit].self, forKey: .artists) ?? []
        labels = try container.decodeIfPresent([LabelCredit].self, forKey: .labels) ?? []
        formats = try container.decodeIfPresent([Format].self, forKey: .formats) ?? []
        genres = try container.decodeIfPresent([String].self, forKey: .genres) ?? []
        styles = try container.decodeIfPresent([String].self, forKey: .styles) ?? []
        tracklist = try container.decodeIfPresent([Track].self, forKey: .tracklist) ?? []
        images = try container.decodeIfPresent([ReleaseImage].self, forKey: .images) ?? []
        uri = try container.decodeIfPresent(String.self, forKey: .uri)
    }
}

/// One tracklist entry. Discogs uses the same array for tracks, headings and index entries, which
/// `type` distinguishes.
public struct Track: Codable, Sendable, Hashable {
    /// e.g. `A1`. Empty for headings.
    public let position: String
    public let title: String
    /// e.g. `4:32`. Often empty.
    public let duration: String
    /// `track`, `heading`, or `index`.
    public let type: String

    public var isTrack: Bool { type == "track" }

    enum CodingKeys: String, CodingKey {
        case position, title, duration
        // Discogs sends this with a trailing underscore, to avoid clashing with a reserved word.
        case type = "type_"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decodeIfPresent(String.self, forKey: .position) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        duration = try container.decodeIfPresent(String.self, forKey: .duration) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "track"
    }
}

public struct ReleaseImage: Codable, Sendable, Hashable {
    /// `primary` or `secondary`.
    public let type: String
    public let uri: String
    public let uri150: String?
    public let width: Int?
    public let height: Int?
}

// MARK: - Search

public struct SearchPage: Codable, Sendable {
    public let pagination: Pagination
    public let results: [SearchResult]
}

/// One hit from `GET /database/search`.
///
/// Search results are shaped differently from collection items: the title is a single
/// `Artist - Title` string, and `year` arrives as text, so both need unpicking before they can fill
/// the cache.
public struct SearchResult: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let type: String
    /// Combined `Artist - Title`.
    public let title: String
    public let thumb: String?
    public let coverImage: String?
    public let country: String?
    public let format: [String]
    public let label: [String]
    public let catno: String?
    public let genre: [String]
    public let style: [String]
    public let masterID: Int?
    public let resourceURL: String?

    /// Search sends the year as a string, and sometimes not at all.
    public let year: Int?

    /// Artist portion of `title`, or nil when Discogs did not use the usual separator.
    public var artistName: String? {
        guard let range = title.range(of: " - ") else { return nil }
        return String(title[title.startIndex..<range.lowerBound])
    }

    /// Release-title portion of `title`, falling back to the whole string.
    public var releaseTitle: String {
        guard let range = title.range(of: " - ") else { return title }
        return String(title[range.upperBound...])
    }

    public var formatDisplayName: String { format.joined(separator: ", ") }

    enum CodingKeys: String, CodingKey {
        case id, type, title, thumb, country, format, label, catno, genre, style, year
        case coverImage = "cover_image"
        case masterID = "master_id"
        case resourceURL = "resource_url"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "release"
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        coverImage = try container.decodeIfPresent(String.self, forKey: .coverImage)
        country = try container.decodeIfPresent(String.self, forKey: .country)
        format = try container.decodeIfPresent([String].self, forKey: .format) ?? []
        label = try container.decodeIfPresent([String].self, forKey: .label) ?? []
        catno = try container.decodeIfPresent(String.self, forKey: .catno)
        genre = try container.decodeIfPresent([String].self, forKey: .genre) ?? []
        style = try container.decodeIfPresent([String].self, forKey: .style) ?? []
        masterID = try container.decodeIfPresent(Int.self, forKey: .masterID)
        resourceURL = try container.decodeIfPresent(String.self, forKey: .resourceURL)

        // `year` is a string here, unlike everywhere else in the API, and may be absent, empty,
        // or a full date. Accept a number too, in case that ever changes.
        let parsedYear: Int?
        if let text = try? container.decodeIfPresent(String.self, forKey: .year) {
            parsedYear = Int(text.prefix(4))
        } else {
            parsedYear = try? container.decodeIfPresent(Int.self, forKey: .year)
        }
        year = (parsedYear == 0) ? nil : parsedYear
    }
}

// MARK: - Collection writes

/// Response of a successful add: Discogs assigns the new copy an `instance_id`.
public struct CollectionAddition: Codable, Sendable, Hashable {
    public let instanceID: Int
    public let resourceURL: String?

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case resourceURL = "resource_url"
    }
}
