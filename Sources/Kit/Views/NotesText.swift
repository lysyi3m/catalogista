import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Notes as one selectable block, links and emphasis included: a release's notes, or a custom
/// free-text field.
///
/// macOS draws them with a read-only `NSTextView`. A selectable SwiftUI `Text` of several lines is
/// laid out one way while its pane has focus and another way when it does not, so its lines moved
/// by a point whenever focus went to the sidebar. A text view lays out the same way in both.
struct NotesText: View {
    let notes: AttributedString

    /// About 80 characters of body text. Prose across the full page width runs well past 100 a
    /// line, too long to read comfortably; the page's tables and lists keep the full width.
    static let readingWidth: CGFloat = 540

    /// Extra space between the lines of a paragraph. Paragraphs stay apart by their blank lines.
    static let lineSpacing: CGFloat = 3

    var body: some View {
        Group {
            #if os(macOS)
            NotesTextView(text: Self.appKitString(notes))
            #else
            Text(notes)
                .font(.body)
                .lineSpacing(Self.lineSpacing)
                .textSelection(.enabled)
            #endif
        }
        .frame(maxWidth: Self.readingWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(macOS)
    /// The SwiftUI attributes a text view does not read, in AppKit terms: the font, with the
    /// emphasis `DiscogsMarkup` sets as a presentation intent, and the label colour.
    static func appKitString(_ text: AttributedString) -> NSAttributedString {
        let base = NSFont.preferredFont(forTextStyle: .body)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let result = NSMutableAttributedString()
        for run in text.runs {
            var traits: NSFontDescriptor.SymbolicTraits = []
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { traits.insert(.bold) }
            if run.inlinePresentationIntent?.contains(.emphasized) == true { traits.insert(.italic) }
            let font = traits.isEmpty
                ? base
                : NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: base.pointSize) ?? base
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }
    #endif
}

#if os(macOS)
private struct NotesTextView: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        // TextKit 1, the engine `sizeThatFits` measures with. The default TextKit 2 view spaces
        // lines differently once a paragraph style adds line spacing, and the measured height
        // then clipped the last line.
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A link as the rest of the app draws one: the accent colour, no underline.
        view.linkTextAttributes = [
            .foregroundColor: NSColor(Color.accentColor),
            .cursor: NSCursor.pointingHand,
        ]
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        if view.textStorage?.isEqual(to: text) != true {
            view.textStorage?.setAttributedString(text)
        }
    }

    /// As tall as the text is at the width offered, and as wide as offered.
    ///
    /// Measured on a layout of its own: SwiftUI tries several widths before it settles, and laying
    /// out the visible view at each would leave it wrapped at whichever came last.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
}
#endif
