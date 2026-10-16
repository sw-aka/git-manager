import Foundation
import Observation

public enum SidebarDropTarget: Equatable, Sendable {
    case repository(String)
    case emptyGroup(UUID?)
    case group(UUID?, GroupDropPosition)
}

/// One drag session and one insertion indicator for the entire sidebar.
@Observable @MainActor
public final class SidebarDragState {
    public private(set) var payload: SidebarDragPayload?
    public private(set) var target: SidebarDropTarget?
    public private(set) var sessionID: UUID?

    public init() {}

    @discardableResult
    public func begin(_ payload: SidebarDragPayload) -> UUID {
        let id = UUID()
        sessionID = id
        self.payload = payload
        target = nil
        return id
    }

    public func hover(_ target: SidebarDropTarget) {
        guard payload != nil else { return }
        self.target = target
    }

    public func leave(_ target: SidebarDropTarget) {
        if self.target == target { self.target = nil }
    }

    public func clearTarget() { target = nil }

    public func end(_ id: UUID) {
        guard sessionID == id else { return }
        payload = nil
        target = nil
        sessionID = nil
    }

    public func acceptsRepositoryDrop(before id: String?) -> Bool {
        guard case .repository(let draggedID) = payload else { return false }
        return draggedID != id
    }
}
