import Foundation
import Testing
@testable import CatalogistaKit

@Suite("Discogs markup")
struct DiscogsMarkupTests {
    private func text(_ markup: String) -> String {
        String(DiscogsMarkup.attributed(markup).characters)
    }

    private func links(_ markup: String) -> [URL] {
        DiscogsMarkup.attributed(markup).runs.compactMap(\.link)
    }

    @Test("A release reference in either form becomes a link to the release")
    func releaseReference() {
        #expect(text("Earlier version of [r7632764], same runouts") == "Earlier version of release 7632764, same runouts")
        #expect(text("Unlike [r=469141], no code") == "Unlike release 469141, no code")
        #expect(links("[r7632764]") == [URL(string: "https://www.discogs.com/release/7632764")!])
    }

    @Test("Master, artist and label references link to their pages; a name reference shows the name")
    func otherReferences() {
        #expect(links("[m123] [a45] [l6]") == [
            URL(string: "https://www.discogs.com/master/123")!,
            URL(string: "https://www.discogs.com/artist/45")!,
            URL(string: "https://www.discogs.com/label/6")!,
        ])
        #expect(text("Engineer: [a=Rudy Van Gelder] at [l=Blue Note]") == "Engineer: Rudy Van Gelder at Blue Note")
    }

    @Test("A url tag becomes a link, with or without its own text; other schemes stay plain")
    func urlTags() {
        #expect(text("See [url=https://example.com/a]the booklet[/url].") == "See the booklet.")
        #expect(links("[url=https://example.com/a]the booklet[/url]") == [URL(string: "https://example.com/a")!])
        #expect(text("[url]https://example.com/b[/url]") == "https://example.com/b")
        #expect(links("[url]https://example.com/b[/url]") == [URL(string: "https://example.com/b")!])
        #expect(links("[url=javascript:alert(1)]x[/url]").isEmpty)
    }

    @Test("Bold and italic keep their emphasis; other tags are dropped; ordinary brackets stay")
    func emphasis() {
        let rendered = DiscogsMarkup.attributed("[b]Bold[/b] [i]italic[/i] [u]under[/u] [sic]")
        #expect(String(rendered.characters) == "Bold italic under [sic]")
        let intents = rendered.runs.map(\.inlinePresentationIntent)
        #expect(intents.contains(.stronglyEmphasized))
        #expect(intents.contains(.emphasized))
    }

    @Test("Plain notes pass through unchanged")
    func plainText() {
        let note = "Orange vinyl pressing in gatefold sleeve with booklet.\n- On disc 1 DC 4"
        #expect(text(note) == note)
        #expect(links(note).isEmpty)
    }
}
