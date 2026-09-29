import Foundation

/// Bridges menu commands to the collection screen.
///
/// Menu commands are declared on the scene, but the work belongs to the view that owns the state.
/// Each request bumps a counter the view observes, so pressing the same shortcut twice fires twice.
@MainActor
@Observable
public final class AppCommands {
    public private(set) var addRequests = 0
    public private(set) var syncRequests = 0
    public private(set) var findRequests = 0
    /// Whether Add Record can run where the user is. The collection screen sets it, since only it
    /// knows; the menu item reads it.
    public internal(set) var isAddAvailable = false

    public init() {}

    public func requestAdd() { addRequests += 1 }
    public func requestSync() { syncRequests += 1 }
    public func requestFind() { findRequests += 1 }
}
