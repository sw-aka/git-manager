import XCTest
@testable import GitManager

private actor ConcurrencyProbe {
    var active = 0
    var maximum = 0
    var completed = 0
    func enter() { active += 1; maximum = max(maximum, active) }
    func leave() { active -= 1; completed += 1 }
    func result() -> (Int, Int) { (maximum, completed) }
}

@MainActor
final class WorkLimiterTests: XCTestCase {
    func testLimitsConcurrentWorkToFour() async {
        let limiter = WorkLimiter(limit: 4)
        let probe = ConcurrencyProbe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await limiter.acquire()
                    await probe.enter()
                    try? await Task.sleep(for: .milliseconds(20))
                    await probe.leave()
                    await limiter.release()
                }
            }
        }
        let (maximum, completed) = await probe.result()
        XCTAssertEqual(maximum, 4)
        XCTAssertEqual(completed, 20)
    }
}
