import Foundation

/// Renders the markup Discogs allows in release notes.
///
/// References to other entries (`[r123]`, `[r=123]`, `[m…]`, `[a…]`, `[l…]`) become links to their
/// discogs.com pages. Discogs shows the entry's name there; that would cost a request per reference,
/// so the link names the kind and id instead. A name reference (`[a=Miles Davis]`) shows the name.
/// `[url]` becomes a link, `[b]` and `[i]` keep their emphasis, and `[u]` and `[s]` are dropped.
enum DiscogsMarkup {
    static func attributed(_ markup: String) -> AttributedString {
        var result = AttributedString()
        var bold = false
        var italic = false
        var link: URL?
        var remaining = Substring(markup)

        func append(_ text: some StringProtocol, linkTo url: URL? = nil) {
            guard !text.isEmpty else { return }
            var run = AttributedString(String(text))
            var intent: InlinePresentationIntent = []
            if bold { intent.insert(.stronglyEmphasized) }
            if italic { intent.insert(.emphasized) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            run.link = url ?? link
            result += run
        }

        while let match = remaining.firstMatch(of: tag) {
            append(remaining[..<match.range.lowerBound])
            remaining = remaining[match.range.upperBound...]

            let isClosing = !match.output.1.isEmpty
            let name = match.output.2.lowercased()
            let argument = match.output.3.map { String($0.drop { $0 == "=" }) }

            switch name {
            case "b": bold = !isClosing
            case "i": italic = !isClosing
            case "url":
                if isClosing {
                    link = nil
                } else if let argument, let url = webURL(argument) {
                    link = url
                } else if let end = remaining.range(of: "[/url]", options: .caseInsensitive) {
                    // `[url]https://…[/url]`: the address is the text.
                    let address = remaining[..<end.lowerBound]
                    append(address, linkTo: webURL(String(address)))
                    remaining = remaining[end.upperBound...]
                }
            case "r", "m", "a", "l":
                guard !isClosing, let argument, !argument.isEmpty else { break }
                if let id = Int(argument), let kind = Reference(rawValue: name) {
                    append("\(kind.noun) \(id)", linkTo: kind.url(id: id))
                } else {
                    append(argument)
                }
            default:
                break
            }
        }
        append(remaining)
        return result
    }

    /// `[/b]`, `[url=…]`, `[r123]`, `[r=123]`. The name is limited to the tags Discogs defines, so a
    /// bracket that is part of the text, such as "[sic]", stays as written.
    private nonisolated(unsafe) static let tag = /\[(\/?)(b|i|u|s|url|r|m|a|l)(=[^\]]*|\d+)?\]/
        .ignoresCase()

    private enum Reference: String {
        case r, m, a, l

        /// Also the page's path on discogs.com.
        var noun: String {
            switch self {
            case .r: "release"
            case .m: "master"
            case .a: "artist"
            case .l: "label"
            }
        }

        func url(id: Int) -> URL? {
            URL(string: "https://www.discogs.com/\(noun)/\(id)")
        }
    }

    /// Only web links: a note is someone else's text, and any other scheme could open an app.
    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }
}
