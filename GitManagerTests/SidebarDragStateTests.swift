import XCTest
@testable import GitManagerCore

@MainActor
final class SidebarDragStateTests: XCTestCase {
    func testMovingAcrossRowsKeepsOnlyTheCurrentIndicator() {
        let state = SidebarDragState()
        state.begin(.repository("source"))
        state.hover(.repository("first"))
        state.hover(.repository("second"))
        // AppKit may deliver the old exit after entering the next destination.
        state.leave(.repository("first"))
        XCTAssertEqual(state.target, .repository("second"))
        state.leave(.repository("second"))
        XCTAssertNil(state.target)
    }

    func testEndingADragClearsIndicatorsForDropCancellationAndOutsideRelease() {
        let state = SidebarDragState()
        for target in [SidebarDropTarget.repository("other"), .group(UUID(), .inside), .emptyGroup(nil)] {
            let session = state.begin(.repository("source"))
            state.hover(target)
            state.end(session)
            XCTAssertNil(state.target)
            XCTAssertNil(state.payload)
            XCTAssertNil(state.sessionID)
            // A late destination update must not resurrect the indicator.
            state.hover(target)
            XCTAssertNil(state.target)
        }
    }

    func testANewDragClearsThePreviousTargetAndIgnoresItsLateCompletion() {
        let state = SidebarDragState()
        let previous = state.begin(.repository("first"))
        state.hover(.repository("second"))
        let current = state.begin(.repository("second"))
        XCTAssertNil(state.target)
        state.hover(.group(nil, .inside))
        state.end(previous)
        XCTAssertEqual(state.sessionID, current)
        XCTAssertEqual(state.payload, .repository("second"))
        XCTAssertEqual(state.target, .group(nil, .inside))
    }

    func testRepositoryRowsRejectSelfGroupAndExternalDrags() {
        let state = SidebarDragState()
        XCTAssertFalse(state.acceptsRepositoryDrop(before: "other"))
        state.begin(.group(UUID()))
        XCTAssertFalse(state.acceptsRepositoryDrop(before: "other"))
        state.begin(.repository("source"))
        XCTAssertFalse(state.acceptsRepositoryDrop(before: "source"))
        XCTAssertTrue(state.acceptsRepositoryDrop(before: "other"))
        XCTAssertTrue(state.acceptsRepositoryDrop(before: nil))
    }

    func testDroppingClearsTheIndicatorBeforeTheSessionEnds() {
        let state = SidebarDragState()
        let session = state.begin(.repository("source"))
        state.hover(.repository("other"))
        state.clearTarget()
        XCTAssertNil(state.target)
        XCTAssertEqual(state.payload, .repository("source"))
        state.end(session)
        XCTAssertNil(state.payload)
    }
}
