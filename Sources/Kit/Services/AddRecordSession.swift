import Foundation

/// One opening of the Add Record sheet: the release picked for its second step, and every release
/// its results listed.
///
/// Owned by the view that presents the sheet, which closes it from the sheet's `onDismiss`. The
/// sheet's own `onDisappear` is not documented to mean the sheet is gone, and closing early would
/// delete images Quick Look may still show.
@MainActor
@Observable
final class AddRecordSession {
    struct Preview {
        let releaseID: Int
        /// Fetches the release without storing it. See `ReleaseDetailLoader.fetched`.
        let loader: ReleaseDetailLoader
        let images: ReleaseImages
    }

    private(set) var preview: Preview?
    /// Read only on close, so a list that grows does not redraw the sheet.
    @ObservationIgnored private var listedReleaseIDs: Set<Int> = []

    func noteListed(_ releaseIDs: some Sequence<Int>) {
        listedReleaseIDs.formUnion(releaseIDs)
    }

    /// The preview of this release. Back, then the same release again, keeps its fetch.
    func preview(of releaseID: Int, services: AppServices) -> Preview {
        if let preview, preview.releaseID == releaseID { return preview }
        // Its downloads would outlive the close, which cancels only the current preview's.
        self.preview?.images.cancel()
        let preview = Preview(
            releaseID: releaseID,
            loader: ReleaseDetailLoader(services: services, persists: false),
            images: ReleaseImages()
        )
        self.preview = preview
        return preview
    }

    /// Deletes the images of every listed release that is not in the collection, whether a release
    /// was added or not. The collection is read only now, so a release just added keeps its images.
    func close(services: AppServices) {
        preview?.images.cancel()
        let listed = listedReleaseIDs
        guard !listed.isEmpty else { return }
        Task {
            guard let kept = try? await services.store.releaseIDs() else { return }
            await services.imageCache.discard(releaseIDs: listed.subtracting(kept))
        }
    }
}
