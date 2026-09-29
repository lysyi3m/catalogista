import DiscogsKit
import Foundation

/// Applies collection writes optimistically: the cache changes first, Discogs second, and a failure
/// rolls the cache back.
///
/// The grid therefore reacts the moment the user confirms, and never shows a change Discogs
/// rejected.
@MainActor
@Observable
final class CollectionEditor {
    private(set) var isWorking = false
    private(set) var failure: Failure?

    /// A write the user asked for that did not happen, and the operation that would try it again.
    ///
    /// Unlike a refresh, a write is something the user is waiting on, so it is worth interrupting
    /// for — and an interruption is only worth it if it can offer the retry.
    struct Failure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// Absent when retrying could do damage — an unconfirmed write may already have been
        /// applied, and repeating it would add a second copy.
        let retry: (@MainActor () async -> Void)?
    }

    /// The same failure as a status line, for the surfaces that show sync state alongside it.
    var errorMessage: String? { failure?.message }

    func clearFailure() { failure = nil }

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// Adds a copy to the folder, optimistically.
    ///
    /// The row appears immediately from search data under a provisional id, then takes the real
    /// `instance_id` from the response. A release fetch afterwards replaces the search-derived
    /// artist and title with Discogs' own; that refinement is best-effort, because the add itself
    /// has already succeeded by then.
    @discardableResult
    func add(
        _ result: SearchResult,
        folderID: Int = DiscogsFolder.uncategorized
    ) async -> Bool {
        guard !isWorking, let client = services.client else { return false }
        isWorking = true
        failure = nil
        defer { isWorking = false }

        func rejected(_ error: any Error) {
            failure = Failure(
                title: "Couldn't add \(result.title)",
                message: error.localizedDescription,
                retry: { [weak self] in _ = await self?.add(result, folderID: folderID) }
            )
        }

        // Captured before the write: an ambiguous outcome is settled by looking for a copy that
        // was not there before, which is the only evidence that this add is the one that landed.
        let copiesBefore = (try? await services.store.instanceIDs(ofRelease: result.id)) ?? []

        let provisionalID = PendingAddition.provisionalInstanceID()
        let pending = PendingAddition(from: result, instanceID: provisionalID, folderID: folderID)

        do {
            try await services.store.insert(pending)
        } catch {
            rejected(error)
            return false
        }

        // Only a failure of the POST itself means the copy was not added. Anything that goes
        // wrong afterwards happens with the copy already on Discogs, and rolling the row back
        // there would hide a record the user really does own.
        let addition: CollectionAddition
        do {
            let username = try await services.username()
            addition = try await client.addToCollection(
                user: username,
                folderID: folderID,
                releaseID: result.id
            )
        } catch {
            try? await services.store.deleteItem(instanceID: provisionalID)
            // Only a definite rejection means the copy is not on Discogs. Anything else may have
            // been applied before the answer went missing, so ask Discogs rather than guess —
            // rolling back and offering a retry is how a second copy gets added.
            if (error as? DiscogsError)?.didNotReachDiscogs ?? false {
                rejected(error)
                return false
            }
            return await reconcileAdd(of: result, folderID: folderID, knownCopies: copiesBefore, after: error)
        }

        do {
            try await services.store.reassignInstanceID(from: provisionalID, to: addition.instanceID)
        } catch {
            // The copy exists upstream but this device could not record its id. A refresh
            // reconciles by instance_id, replacing the provisional row with the real one.
            await services.syncController.sync()
            return true
        }

        await refine(releaseID: result.id, instanceID: addition.instanceID, client: client)
        return true
    }

    /// Removes a copy from the collection, optimistically.
    ///
    /// Keyed by `instanceID`: removing one of two copies of the same release must not touch the
    /// other. The row disappears from the grid immediately and comes back if Discogs rejects the
    /// delete.
    @discardableResult
    func remove(instanceID: Int) async -> Bool {
        guard !isWorking, let client = services.client else { return false }
        isWorking = true
        failure = nil
        defer { isWorking = false }

        func rejected(_ error: any Error, title: String) {
            failure = Failure(
                title: title,
                message: error.localizedDescription,
                retry: { [weak self] in _ = await self?.remove(instanceID: instanceID) }
            )
        }

        let snapshot: CollectionItemSnapshot?
        do {
            snapshot = try await services.store.item(instanceID: instanceID)
        } catch {
            rejected(error, title: "Couldn't remove the copy")
            return false
        }
        guard let snapshot else { return false }

        do {
            try await services.store.deleteItem(instanceID: instanceID)
        } catch {
            rejected(error, title: "Couldn't remove \(snapshot.title)")
            return false
        }

        do {
            let username = try await services.username()
            try await client.removeFromCollection(
                user: username,
                folderID: snapshot.folderID,
                releaseID: snapshot.releaseID,
                instanceID: snapshot.instanceID
            )
            return true
        } catch let error as DiscogsError where error.isNotFound {
            // Already gone from Discogs, which is the state the user asked for. Putting the row
            // back because the server said "no such copy" would undo a removal that has happened.
            return true
        } catch {
            guard (error as? DiscogsError)?.didNotReachDiscogs ?? false else {
                // The delete may have been applied. Let Discogs settle it rather than restoring a
                // copy that is no longer there.
                return await reconcileRemove(of: snapshot, after: error)
            }
            rejected(error, title: "Couldn't remove \(snapshot.title)")
            try? await services.store.restore(snapshot)
            return false
        }
    }

    // MARK: - Reconciliation

    /// Settles a write whose outcome Discogs never confirmed, by asking Discogs what is true.
    ///
    /// A sync is authoritative: it reconciles the whole collection by `instance_id`. If it cannot run —
    /// offline, most likely — the outcome stays genuinely unknown, and saying so is better than
    /// offering a retry that might duplicate the copy.
    private func reconcileAdd(
        of result: SearchResult,
        folderID: Int,
        knownCopies: Set<Int>,
        after error: any Error
    ) async -> Bool {
        guard await services.syncController.syncAfterWrite() else {
            failure = Failure(
                title: "Couldn't confirm the add",
                message: "\(result.title) may or may not have been added. Sync when you are back online to find out.",
                retry: nil
            )
            return false
        }
        let copiesNow = (try? await services.store.instanceIDs(ofRelease: result.id)) ?? []
        // A copy that was not there before this write is the add that landed. Merely finding the
        // release is not evidence: the user may have owned one all along.
        if copiesNow.subtracting(knownCopies).isEmpty == false { return true }
        // Verified absent, so a retry is safe to offer.
        failure = Failure(
            title: "Couldn't add \(result.title)",
            message: error.localizedDescription,
            retry: { [weak self] in _ = await self?.add(result, folderID: folderID) }
        )
        return false
    }

    private func reconcileRemove(of snapshot: CollectionItemSnapshot, after error: any Error) async -> Bool {
        guard await services.syncController.syncAfterWrite() else {
            failure = Failure(
                title: "Couldn't confirm the removal",
                message: "\(snapshot.title) may or may not have been removed. Sync when you are back online to find out.",
                retry: nil
            )
            return false
        }
        // The sync restores the copy if Discogs still has it, and leaves it gone if not.
        if (try? await services.store.item(instanceID: snapshot.instanceID)) == nil { return true }
        failure = Failure(
            title: "Couldn't remove \(snapshot.title)",
            message: error.localizedDescription,
            retry: { [weak self] in _ = await self?.remove(instanceID: snapshot.instanceID) }
        )
        return false
    }


    /// Best-effort accuracy pass. A failure here leaves the copy added with search-derived text,
    /// which the next full sync corrects anyway.
    private func refine(releaseID: Int, instanceID: Int, client: DiscogsClient) async {
        do {
            let release = try await client.release(id: releaseID)
            try await services.store.apply(release, toInstanceID: instanceID)
            try await services.store.upsertReleaseDetail(release)
        } catch {
            // Intentionally silent: the add succeeded, and this only sharpens the cached text.
        }
    }
}
