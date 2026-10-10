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

    /// Pinned, so the expected text does not depend on the machine running the tests.
    private let english = Locale(identifier: "en_US")

    @Test("A full date formats at day precision")
    func fullDate() {
        #expect(snapshot(released: "2025-02-28").releasedDisplay(locale: english) == "Feb 28, 2025")
    }

    @Test("A year-month date formats without inventing a day")
    func yearMonth() {
        #expect(snapshot(released: "1980-10").releasedDisplay(locale: english) == "Oct 1980")
    }

    @Test("Zero month and day mean unknown, not January 1st")
    func zeroComponents() {
        // Discogs sends this shape for a release it only knows the year of.
        #expect(snapshot(released: "2025-00-00").releasedDisplay(locale: english) == "2025")
        #expect(snapshot(released: "1977-05-00").releasedDisplay(locale: english) == "May 1977")
    }

    @Test("The date follows the reader's locale")
    func localized() {
        let german = snapshot(released: "2025-02-28").releasedDisplay(locale: Locale(identifier: "de_DE"))
        #expect(german != "Feb 28, 2025")
        #expect(german?.contains("2025") == true)
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
