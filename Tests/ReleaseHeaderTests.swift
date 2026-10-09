import Testing
@testable import CatalogistaKit

@Suite("Release header")
struct ReleaseHeaderTests {
    @Test("A middot list breaks only after a dot, and never inside an item")
    func listBreaks() {
        let nbsp = "\u{00A0}"
        let joined = ReleaseHeader.list(["Electronic", "Funk / Soul", "IDM"])
        #expect(joined == "Electronic\(nbsp)· Funk\(nbsp)/\(nbsp)Soul\(nbsp)· IDM")
        // The only ordinary spaces, where a line may break, follow a dot.
        let breaks = joined.indices.filter { joined[$0] == " " }
        #expect(breaks.allSatisfy { joined[joined.index(before: $0)] == "·" })
    }
}
