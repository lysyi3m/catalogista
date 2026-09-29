import CoreGraphics
import Foundation

/// Decoded covers held in memory, so a cell drawn again shows its cover at once instead of
/// starting on a placeholder and decoding from disk.
///
/// Switching folders, re-sorting and scrolling back all create cells whose images were decoded
/// moments ago. Keyed by the source URL as well as the release, so a cover Discogs replaced is a
/// miss and goes through `ImageCache`, which fetches the new image. `ImageCache` only stores an
/// image here when the file on disk came from that URL: an older file it serves while offline
/// never stands in for the new one.
///
/// Bounded by decoded bytes. `NSCache` also empties itself under memory pressure, and is safe to
/// use from any thread, which lets a view read it synchronously while it is drawn.
final class DecodedImageCache: @unchecked Sendable {
    /// About 250 grid covers at the default size on a Retina display, or 80 at the largest.
    static let defaultByteLimit = 100 * 1024 * 1024

    private final class Entry {
        let image: PlatformImage
        init(_ image: PlatformImage) { self.image = image }
    }

    private let storage = NSCache<NSString, Entry>()

    init(byteLimit: Int = DecodedImageCache.defaultByteLimit) {
        storage.totalCostLimit = byteLimit
    }

    func image(releaseID: Int, kind: ImageCache.Kind, source: URL, maximumPixelSize: CGFloat) -> PlatformImage? {
        storage.object(forKey: Self.key(releaseID, kind, source, maximumPixelSize))?.image
    }

    func insert(
        _ image: PlatformImage,
        byteCount: Int,
        releaseID: Int,
        kind: ImageCache.Kind,
        source: URL,
        maximumPixelSize: CGFloat
    ) {
        storage.setObject(
            Entry(image),
            forKey: Self.key(releaseID, kind, source, maximumPixelSize),
            cost: byteCount
        )
    }

    func removeAll() {
        storage.removeAllObjects()
    }

    /// The pixel size is part of the key: a cover decoded for a small grid cell is too coarse for
    /// the record page.
    private static func key(_ releaseID: Int, _ kind: ImageCache.Kind, _ source: URL, _ pixelSize: CGFloat) -> NSString {
        "\(kind.rawValue)/\(releaseID)/\(Int(pixelSize.rounded()))/\(source.absoluteString)" as NSString
    }
}
