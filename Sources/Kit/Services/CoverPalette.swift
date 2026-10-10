import CoreGraphics
import Foundation

/// Two colours taken from a cover, for the sheets stacked behind it on the record page.
enum CoverPalette {
    struct RGB: Hashable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
    }

    /// The cover's two most common colours, the most common first. A cover in one colour gets a
    /// lighter or darker shade of it as the second.
    ///
    /// Both are kept within a brightness and saturation band, so a black or white cover still
    /// gives sheets that stand apart from the page in light and dark mode, and a neon one does not
    /// outshout the cover.
    nonisolated static func sheetColors(of image: CGImage) -> [RGB] {
        let pixels = sample(image)
        guard !pixels.isEmpty else { return [] }

        // Three bits per channel: close shades share a bucket, and the bucket's mean is its colour.
        var buckets: [Int: (sum: RGB, count: Int)] = [:]
        for pixel in pixels {
            let key = Int(pixel.red * 7.99) << 6 | Int(pixel.green * 7.99) << 3 | Int(pixel.blue * 7.99)
            var bucket = buckets[key] ?? (RGB(red: 0, green: 0, blue: 0), 0)
            bucket.sum.red += pixel.red
            bucket.sum.green += pixel.green
            bucket.sum.blue += pixel.blue
            bucket.count += 1
            buckets[key] = bucket
        }
        let ranked = buckets.values
            .sorted { $0.count > $1.count }
            .map { RGB(red: $0.sum.red / Double($0.count), green: $0.sum.green / Double($0.count), blue: $0.sum.blue / Double($0.count)) }

        let first = tame(ranked[0])
        let second = ranked.dropFirst().first { distance($0, ranked[0]) > 0.3 }.map(tame) ?? shade(of: first, by: 0.15)
        // The cover's main colour usually runs to its edge, so the front sheet takes a step off it
        // to stand apart from the cover.
        return [shade(of: first, by: 0.1), second]
    }

    /// Reads the cover file at `url`, decoded small: a few hundred pixels describe its colours.
    nonisolated static func sheetColors(at url: URL) -> [RGB] {
        guard let image = ImageCache.downsample(at: url, maximumPixelSize: 32) else { return [] }
        return sheetColors(of: image)
    }

    private nonisolated static func sample(_ image: CGImage) -> [RGB] {
        let edge = 32
        var bytes = [UInt8](repeating: 0, count: edge * edge * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: edge,
                height: edge,
                bitsPerComponent: 8,
                bytesPerRow: edge * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: edge, height: edge))
            return true
        }
        guard drawn else { return [] }
        return stride(from: 0, to: bytes.count, by: 4).map { index in
            RGB(red: Double(bytes[index]) / 255, green: Double(bytes[index + 1]) / 255, blue: Double(bytes[index + 2]) / 255)
        }
    }

    private nonisolated static func distance(_ a: RGB, _ b: RGB) -> Double {
        ((a.red - b.red) * (a.red - b.red) + (a.green - b.green) * (a.green - b.green) + (a.blue - b.blue) * (a.blue - b.blue)).squareRoot()
    }

    /// The same hue, moved towards the middle of the brightness range, so it stays in the band.
    private nonisolated static func shade(of color: RGB, by step: Double) -> RGB {
        var hsb = HSB(color)
        hsb.brightness += hsb.brightness > 0.6 ? -step : step
        return hsb.rgb
    }

    private nonisolated static func tame(_ color: RGB) -> RGB {
        var hsb = HSB(color)
        hsb.brightness = min(max(hsb.brightness, 0.32), 0.88)
        hsb.saturation = min(hsb.saturation, 0.7)
        return hsb.rgb
    }

    private struct HSB {
        var hue: Double
        var saturation: Double
        var brightness: Double

        nonisolated init(_ color: RGB) {
            let high = max(color.red, color.green, color.blue)
            let low = min(color.red, color.green, color.blue)
            let range = high - low
            brightness = high
            saturation = high == 0 ? 0 : range / high
            if range == 0 {
                hue = 0
            } else if high == color.red {
                hue = ((color.green - color.blue) / range).truncatingRemainder(dividingBy: 6) / 6
            } else if high == color.green {
                hue = ((color.blue - color.red) / range + 2) / 6
            } else {
                hue = ((color.red - color.green) / range + 4) / 6
            }
            if hue < 0 { hue += 1 }
        }

        nonisolated var rgb: RGB {
            let value = min(max(brightness, 0), 1)
            let chroma = value * saturation
            let sector = hue * 6
            let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
            let (r, g, b): (Double, Double, Double) = switch Int(sector) % 6 {
            case 0: (chroma, x, 0)
            case 1: (x, chroma, 0)
            case 2: (0, chroma, x)
            case 3: (0, x, chroma)
            case 4: (x, 0, chroma)
            default: (chroma, 0, x)
            }
            let m = value - chroma
            return RGB(red: r + m, green: g + m, blue: b + m)
        }
    }
}
