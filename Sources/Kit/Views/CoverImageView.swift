import SwiftUI

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

/// Cover art loaded from the disk cache, downsampled to the size it is drawn at.
///
/// Decoding at display size is what keeps a wall of covers memory-bounded: a full-res cover is
/// several megabytes decoded, and the grid may show hundreds at once.
struct CoverImageView: View {
    let releaseID: Int
    let remoteURL: String?
    let kind: ImageCache.Kind
    /// Drawn edge length in points. The image is decoded at this size times the screen scale.
    let edge: CGFloat

    @Environment(AppServices.self) private var services
    /// The scale of the display showing this view. It follows the window the cover is drawn in;
    /// `UIScreen.main` assumes one screen and is deprecated.
    @Environment(\.displayScale) private var displayScale
    @State private var image: PlatformImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            // A cover decoded moments ago is drawn at once rather than after a load, so a cell
            // recreated by a folder switch or a re-sort never starts on the placeholder.
            if let image = memoryCached ?? image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: didFail ? "exclamationmark.triangle" : "opticaldisc")
                            .font(.system(size: max(edge * 0.25, 10)))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        // The URL is part of the identity: for a copy with no `cover_image`, the record page starts
        // with the collection's thumb and switches to the release's cover once that arrives, and
        // the load has to follow it.
        .task(id: TaskKey(releaseID: releaseID, kind: kind, url: remoteURL, edge: bucketedEdge)) {
            await load()
        }
    }

    /// Rounding the requested size to a step stops a drag of the density slider from kicking off a
    /// fresh decode on every frame.
    private var bucketedEdge: CGFloat {
        (edge / 40).rounded(.up) * 40
    }

    private var remote: URL? { remoteURL.flatMap(URL.init(string:)) }

    private var memoryCached: PlatformImage? {
        guard let remote else { return nil }
        return services.imageCache.cachedImage(
            releaseID: releaseID,
            kind: kind,
            remoteURL: remote,
            maximumPixelSize: bucketedEdge * displayScale
        )
    }

    private struct TaskKey: Hashable {
        let releaseID: Int
        let kind: ImageCache.Kind
        let url: String?
        let edge: CGFloat
    }

    private func load() async {
        guard let url = remote else {
            didFail = true
            return
        }
        if let cached = memoryCached {
            image = cached
            didFail = false
            return
        }
        do {
            image = try await services.imageCache.image(
                releaseID: releaseID,
                kind: kind,
                remoteURL: url,
                maximumPixelSize: bucketedEdge * displayScale
            )
            didFail = false
        } catch is CancellationError {
            // A scrolled-away cell cancels its own load; nothing to report.
        } catch {
            didFail = true
        }
    }
}
