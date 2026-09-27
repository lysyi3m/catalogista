import Foundation
import Testing
@testable import DiscogsKit

@Suite("Decoding")
struct DecodingTests {
    // Trimmed from a real /collection/folders/0/releases response.
    static let collectionJSON = """
    {
      "pagination": { "page": 1, "pages": 3, "per_page": 100, "items": 254, "urls": {} },
      "releases": [
        {
          "id": 1373891,
          "instance_id": 447829291,
          "folder_id": 1,
          "rating": 0,
          "date_added": "2019-05-06T18:32:50-07:00",
          "basic_information": {
            "id": 1373891,
            "title": "Remain In Light",
            "year": 1980,
            "master_id": 34095,
            "thumb": "https://i.discogs.com/thumb.jpeg",
            "cover_image": "https://i.discogs.com/cover.jpeg",
            "resource_url": "https://api.discogs.com/releases/1373891",
            "artists": [
              { "id": 14093, "name": "Talking Heads", "anv": "", "join": "", "role": "", "resource_url": "https://api.discogs.com/artists/14093" }
            ],
            "labels": [
              { "id": 1000, "name": "Sire", "catno": "SRK 6095", "entity_type": "1", "resource_url": "https://api.discogs.com/labels/1000" }
            ],
            "formats": [
              { "name": "Vinyl", "qty": "1", "descriptions": ["LP", "Album"] }
            ],
            "genres": ["Rock"],
            "styles": ["New Wave", "Art Rock"]
          }
        }
      ]
    }
    """

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try DiscogsClient.makeDecoder().decode(type, from: Data(json.utf8))
    }

    @Test("Collection page decodes instance and release ids distinctly")
    func collectionPage() throws {
        let page = try decode(CollectionPage.self, from: Self.collectionJSON)

        #expect(page.pagination.pages == 3)
        #expect(page.pagination.items == 254)
        #expect(page.pagination.hasNextPage)

        let item = try #require(page.releases.first)
        #expect(item.instanceID == 447829291)
        #expect(item.releaseID == 1373891)
        #expect(item.folderID == 1)
        #expect(item.dateAdded != nil)
        #expect(item.basicInformation.title == "Remain In Light")
        #expect(item.basicInformation.year == 1980)
        #expect(item.basicInformation.artistDisplayName == "Talking Heads")
        #expect(item.basicInformation.formatDisplayName == "Vinyl, LP, Album")
        #expect(item.basicInformation.styles == ["New Wave", "Art Rock"])
        #expect(item.basicInformation.labels.first?.catno == "SRK 6095")
    }

    @Test("Missing optional collections decode as empty rather than failing")
    func sparseBasicInformation() throws {
        let json = """
        { "id": 1, "title": "Untitled", "year": 0 }
        """
        let info = try decode(BasicInformation.self, from: json)

        #expect(info.year == nil, "year 0 means unknown")
        #expect(info.artists.isEmpty)
        #expect(info.genres.isEmpty)
        #expect(info.formats.isEmpty)
        #expect(info.thumb == nil)
    }

    @Test("Artist join phrases drive the display name")
    func joinedArtists() throws {
        let json = """
        {
          "id": 1, "title": "Split", "year": 1999,
          "artists": [
            { "name": "Artist A", "anv": "A.", "join": "&" },
            { "name": "Artist B", "join": "" }
          ]
        }
        """
        let info = try decode(BasicInformation.self, from: json)
        #expect(info.artistDisplayName == "A. & Artist B", "anv wins over name, join sits between credits")
    }

    @Test("Identity decodes the username the token belongs to")
    func identity() throws {
        let json = """
        { "id": 1234, "username": "emil", "resource_url": "https://api.discogs.com/users/emil", "consumer_name": "Catalogista" }
        """
        let identity = try decode(Identity.self, from: json)
        #expect(identity.username == "emil")
        #expect(identity.id == 1234)
    }

    @Test("Multi-disc formats render a quantity")
    func multiDiscFormat() throws {
        let json = """
        { "name": "Vinyl", "qty": "2", "text": "180 Gram", "descriptions": ["LP", "Album", "Reissue"] }
        """
        let format = try decode(Format.self, from: json)
        #expect(format.displayName == "2 x Vinyl, LP, Album, Reissue, 180 Gram")
    }
}
