import CoreGraphics
import Dispatch
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
/// Bounded by decoded bytes, dropping the least recently drawn covers first, and emptied when the
/// system reports memory pressure. Not `NSCache`: it evicts on heuristics of its own, so what it
/// keeps cannot be tested. A lock rather than an actor, so a view can read it synchronously while
/// it is drawn.
final class DecodedImageCache: @unchecked Sendable {
    /// About 250 grid covers at the default size on a Retina display, or 80 at the largest.
    static let defaultByteLimit = 100 * 1024 * 1024

    private struct Entry {
        let image: PlatformImage
        let byteCount: Int
        var lastUse: UInt64
    }

    private let byteLimit: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var byteCount = 0
    private var clock: UInt64 = 0
    private var pressureSource: (any DispatchSourceMemoryPressure)?

    /// - Parameter respondsToMemoryPressure: off in tests, where a pressure event from the rest of
    ///   the machine would empty the cache mid-test.
    init(byteLimit: Int = DecodedImageCache.defaultByteLimit, respondsToMemoryPressure: Bool = true) {
        self.byteLimit = byteLimit
        guard respondsToMemoryPressure else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
        source.setEventHandler { [weak self] in self?.removeAll() }
        source.activate()
        pressureSource = source
    }

    deinit {
        pressureSource?.cancel()
    }

    func image(releaseID: Int, kind: ImageCache.Kind, source: URL, maximumPixelSize: CGFloat) -> PlatformImage? {
        let key = Self.key(releaseID, kind, source, maximumPixelSize)
        return lock.withLock {
            guard var entry = entries[key] else { return nil }
            clock += 1
            entry.lastUse = clock
            entries[key] = entry
            return entry.image
        }
    }

    func insert(
        _ image: PlatformImage,
        byteCount: Int,
        releaseID: Int,
        kind: ImageCache.Kind,
        source: URL,
        maximumPixelSize: CGFloat
    ) {
        // One image larger than the whole budget would evict everything and still not fit.
        guard byteCount <= byteLimit else { return }
        let key = Self.key(releaseID, kind, source, maximumPixelSize)
        lock.withLock {
            clock += 1
            if let replaced = entries.updateValue(Entry(image: image, byteCount: byteCount, lastUse: clock), forKey: key) {
                self.byteCount -= replaced.byteCount
            }
            self.byteCount += byteCount
            // A linear scan per eviction. It runs only when the budget is exceeded, over a few
            // hundred entries, which costs less than one decode.
            while self.byteCount > byteLimit,
                  let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                entries.removeValue(forKey: oldest.key)
                self.byteCount -= oldest.value.byteCount
            }
        }
    }

    func removeAll() {
        lock.withLock {
            entries.removeAll()
            byteCount = 0
        }
    }

    /// The pixel size is part of the key: a cover decoded for a small grid cell is too coarse for
    /// the record page.
    private static func key(_ releaseID: Int, _ kind: ImageCache.Kind, _ source: URL, _ pixelSize: CGFloat) -> String {
        "\(kind.rawValue)/\(releaseID)/\(Int(pixelSize.rounded()))/\(source.absoluteString)"
    }
}
