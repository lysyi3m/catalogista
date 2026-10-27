import QuickLook
import SwiftUI

/// The parts of a release page under its header, which the record page and the add confirmation
/// share: the tracklist and the release notes, both from the release fetch.
struct ReleaseSections: View {
    let loader: ReleaseDetailLoader?
    let releaseID: Int

    @State private var isTracklistExpanded = true

    private var detail: ReleaseDetailSnapshot? { loader?.snapshot }

    var body: some View {
        tracklist
        notes
    }

    // MARK: - Tracklist

    private var tracklist: some View {
        DisclosureGroup(isExpanded: $isTracklistExpanded) {
            tracklistContent
                .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Text("Tracklist").font(.pageHeading)
                if let count = detail?.playableTracks.count {
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                }
                if loader?.state == .loading {
                    ProgressView().controlSize(.small)
                }
            }
            #if os(iOS)
            // The whole row toggles, not only the words and the chevron at either end.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            #endif
        }
        #if os(iOS)
        // Left to the accent colour, the section heading reads as a link rather than a heading.
        .tint(.primary)
        #endif
    }

    @ViewBuilder
    private var notes: some View {
        if let notes = detail?.notes, !notes.isEmpty {
            // Named apart from a custom field the owner may also have called Notes, in Copy.
            PageSection("Release Notes") {
                NotesText(notes: DiscogsMarkup.attributed(notes))
            }
        }
    }

    @ViewBuilder
    private var tracklistContent: some View {
        switch loader?.state {
        case .loaded(let snapshot) where !snapshot.tracks.isEmpty:
            VStack(alignment: .leading, spacing: 0) {
                // By position in the list: position and title together are not unique — a release
                // can repeat an unnumbered heading, and repeated ids make SwiftUI reuse rows.
                ForEach(Array(snapshot.tracks.enumerated()), id: \.offset) { index, track in
                    TrackRow(track: track)
                    if index < snapshot.tracks.count - 1 { Divider() }
                }
            }
        case .loaded:
            Text("No tracklist on Discogs")
                .foregroundStyle(.secondary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).foregroundStyle(.red)
                Button("Try Again") {
                    Task { await loader?.load(releaseID: releaseID) }
                }
            }
        case .loading, nil:
            Text("Loading details…")
                .foregroundStyle(.secondary)
        }
    }
}

/// The age of release details a refresh could not replace. See `ReleaseDetailLoader.staleSince`.
struct StaleDetailsLabel: View {
    let since: Date

    var body: some View {
        Label(
            "Details updated \(since.formatted(.relative(presentation: .named)))",
            systemImage: "clock.arrow.circlepath"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct TrackRow: View {
    let track: CachedTrack
    /// Grows with the text size, so a position such as "A10" stays on one line.
    @ScaledMetric(relativeTo: Self.supportingTextStyle) private var positionWidth: CGFloat = 44

    var body: some View {
        if track.isTrack {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(track.position)
                    .font(Self.supportingFont)
                    .foregroundStyle(.secondary)
                    .frame(width: positionWidth, alignment: .leading)
                Text(track.title)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if !track.duration.isEmpty {
                    // Monospaced digits keep the column's right edge straight.
                    Text(track.duration)
                        .font(Self.supportingFont)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        } else {
            Text(track.title)
                .fontWeight(.semibold)
                .textSelection(.enabled)
                .padding(.top, 12)
                .padding(.bottom, 4)
        }
    }

    #if os(iOS)
    /// One step under the title: at body size a position and a duration compete with it.
    private static let supportingTextStyle = Font.TextStyle.subheadline
    #else
    private static let supportingTextStyle = Font.TextStyle.body
    #endif
    private static let supportingFont = Font.system(supportingTextStyle)
}

// MARK: - Images

/// A release's images in Quick Look, opened from its cover.
@MainActor
@Observable
final class ReleaseImages {
    private(set) var isLoading = false
    /// The release's images on disk, and the one Quick Look shows. Quick Look opens when it is set.
    private(set) var files: [URL] = []
    var previewed: URL?
    var failed = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// The release's images, the cover first. Until the release is fetched, the cover alone.
    static func sources(detail: ReleaseDetailSnapshot?, cover: String?) -> [URL] {
        if let urls = detail?.imageURLs, !urls.isEmpty { return urls.compactMap(URL.init(string:)) }
        return [cover].compactMap { $0.flatMap(URL.init(string:)) }
    }

    func open(releaseID: Int, title: String, sources: [URL], imageCache: ImageCache) {
        guard !isLoading, !sources.isEmpty else { return }
        isLoading = true
        task = Task {
            defer { isLoading = false }
            do {
                files = try await imageCache.releaseImages(releaseID: releaseID, title: title, remoteURLs: sources)
                try Task.checkCancellation()
                previewed = files.first
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }

    /// Stops the request for the release's images, so it starts no more downloads. Downloads already
    /// under way are shared and keep going; `ImageCache.discard(releaseIDs:)` stops those.
    func cancel() {
        task?.cancel()
        task = nil
    }
}

extension View {
    /// Presents `images` in Quick Look once they are on disk, or an alert when none could be.
    func releaseImages(_ images: ReleaseImages) -> some View {
        modifier(ReleaseImagesPresenter(images: images))
    }
}

private struct ReleaseImagesPresenter: ViewModifier {
    @Bindable var images: ReleaseImages

    func body(content: Content) -> some View {
        content
            .quickLookPreview($images.previewed, in: images.files)
            .alert("The images could not be loaded.", isPresented: $images.failed) {
                Button("OK") {}
            } message: {
                Text("Check your connection and try again.")
            }
    }
}
