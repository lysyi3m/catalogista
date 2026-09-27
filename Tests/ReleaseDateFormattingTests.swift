import Foundation
import Testing
@testable import CatalogistaKit

@Suite("Released date formatting")
struct ReleaseDateFormattingTests {
    private func snapshot(released: String?) -> ReleaseDetailSnapshot {
        ReleaseDetailSnapshot(
            releaseID: 1,
            title: "Untitled",
            artistName: "Artist",
            year: nil,
            released: released,
            country: nil,
            notes: nil,
            formatSummary: "",
            labelName: nil,
            catalogNumber: nil,
            genres: [],
            styles: [],
            tracks: [],
            coverURL: nil,
            discogsURL: nil,
            fetchedAt: .now
        )
    }

    @Test("A full date formats at day precision")
    func fullDate() throws {
        let formatted = try #require(snapshot(released: "2025-02-28").releasedDisplay)
        #expect(formatted.contains("2025"))
        #expect(formatted.contains("Feb"))
        #expect(formatted.contains("28"))
    }

    @Test("A year-month date formats without inventing a day")
    func yearMonth() throws {
        let formatted = try #require(snapshot(released: "1980-10").releasedDisplay)
        #expect(formatted.contains("1980"))
        #expect(formatted.contains("Oct"))
        #expect(!formatted.contains("1,"), "no day should appear")
    }

    @Test("Zero month and day mean unknown, not January 1st")
    func zeroComponents() {
        // Discogs sends this shape for a release it only knows the year of.
        #expect(snapshot(released: "2025-00-00").releasedDisplay == "2025")
        #expect(snapshot(released: "1977-05-00").releasedDisplay?.contains("May") == true)
    }

    @Test("A bare year stays a bare year")
    func yearOnly() {
        #expect(snapshot(released: "1969").releasedDisplay == "1969")
    }

    @Test("Missing and unparseable values are passed through untouched")
    func passthrough() {
        #expect(snapshot(released: nil).releasedDisplay == nil)
        #expect(snapshot(released: "").releasedDisplay == nil)
        #expect(snapshot(released: "   ").releasedDisplay == nil)
        #expect(snapshot(released: "Spring 1972").releasedDisplay == "Spring 1972")
    }
}
