import CoreGraphics
import Testing
@testable import CatalogistaKit

@Suite("Cover palette")
struct CoverPaletteTests {
    /// Columns of solid colour, each as wide as its share.
    private func image(_ columns: [(red: Double, green: Double, blue: Double, share: Int)]) throws -> CGImage {
        let width = columns.reduce(0) { $0 + $1.share }
        let context = try #require(CGContext(
            data: nil, width: width, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        var x = 0
        for column in columns {
            context.setFillColor(red: column.red, green: column.green, blue: column.blue, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: column.share, height: 10))
            x += column.share
        }
        return try #require(context.makeImage())
    }

    @Test("The two most common colours come back, the most common first")
    func dominantColours() throws {
        let colors = CoverPalette.sheetColors(of: try image([(0.8, 0.2, 0.1, 6), (0.1, 0.2, 0.7, 3), (0.1, 0.6, 0.2, 1)]))
        #expect(colors.count == 2)
        #expect(colors[0].red > colors[0].blue, "red covers most of it")
        #expect(colors[1].blue > colors[1].red, "blue is second")
    }

    @Test("A black or white cover still gives sheets that stand apart from the page", arguments: [0.0, 1.0])
    func extremesAreTamed(level: Double) throws {
        let colors = CoverPalette.sheetColors(of: try image([(level, level, level, 1)]))
        #expect(colors.count == 2)
        for color in colors {
            let brightness = max(color.red, color.green, color.blue)
            #expect((0.3...0.9).contains(brightness))
        }
        #expect(colors[0] != colors[1], "a cover in one colour gets a second shade")
    }
}
