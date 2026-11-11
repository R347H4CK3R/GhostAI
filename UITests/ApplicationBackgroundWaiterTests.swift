import XCTest

@MainActor final class ApplicationBackgroundWaiterTests: XCTestCase {
    func testAlreadyBackgroundAndSuspendedStatesNeedNoExtraWait() {
        for state in [XCUIApplication.State.runningBackground, .runningBackgroundSuspended] {
            var time: TimeInterval = 0
            let result = ApplicationBackgroundWaiter.wait(timeout: 5, state: { state },
                now: { time }, pump: { time += $0; XCTFail("An observed background state needs no extra wait") })
            XCTAssertTrue(result.observedInTime)
            XCTAssertEqual(result.lastState, state)
        }
    }

    func testTransitionWithinLastHalfSecondIsNotLostBetweenPredicatePolls() {
        var time: TimeInterval = 0
        let result = ApplicationBackgroundWaiter.wait(timeout: 5,
            state: { time >= 4.45 ? .runningBackground : .runningForeground },
            now: { time }, pump: { time += $0 })
        XCTAssertTrue(result.observedInTime)
        XCTAssertGreaterThanOrEqual(result.elapsed, 4.45)
        XCTAssertLessThanOrEqual(result.elapsed, 5)
    }

    func testForegroundStoppedAndUnknownStatesNeverAuthorizeActivation() {
        for state in [XCUIApplication.State.runningForeground, .notRunning, .unknown] {
            var time: TimeInterval = 0
            let result = ApplicationBackgroundWaiter.wait(timeout: 0.12, state: { state },
                now: { time }, pump: { time += $0 })
            XCTAssertFalse(result.observedInTime)
            XCTAssertEqual(result.lastState, state)
            XCTAssertLessThanOrEqual(result.elapsed, 0.12)
        }
    }

    func testStoppedObservationCannotBeRecoveredByALaterBackgroundState() {
        for laterState in [XCUIApplication.State.runningBackground, .runningBackgroundSuspended] {
            var time: TimeInterval = 0
            var reads = 0
            let states: [XCUIApplication.State] = [.runningForeground, .notRunning, laterState]
            let result = ApplicationBackgroundWaiter.wait(timeout: 5,
                state: { let state = states[min(reads, 2)]; reads += 1; return state },
                now: { time }, pump: { time += $0 })
            XCTAssertFalse(result.observedInTime, "A stopped process cannot establish uninterrupted continuity")
            XCTAssertEqual(result.lastState, .notRunning)
            XCTAssertEqual(reads, 2, "Failure must latch before observing a possible replacement process")
            XCTAssertEqual(result.elapsed, 0.05, accuracy: 0.000_001)
        }
    }

    func testUnknownObservationCannotBeRecoveredByALaterBackgroundState() {
        for laterState in [XCUIApplication.State.runningBackground, .runningBackgroundSuspended] {
            var time: TimeInterval = 0
            var reads = 0
            let states: [XCUIApplication.State] = [.runningForeground, .unknown, laterState]
            let result = ApplicationBackgroundWaiter.wait(timeout: 5,
                state: { let state = states[min(reads, 2)]; reads += 1; return state },
                now: { time }, pump: { time += $0 })
            XCTAssertFalse(result.observedInTime, "An unknown state cannot establish uninterrupted continuity")
            XCTAssertEqual(result.lastState, .unknown)
            XCTAssertEqual(reads, 2, "A later known state must not erase the failed continuity observation")
            XCTAssertEqual(result.elapsed, 0.05, accuracy: 0.000_001)
        }
    }

    func testBackgroundTransitionAfterDeadlineIsRejected() {
        var time: TimeInterval = 0
        let result = ApplicationBackgroundWaiter.wait(timeout: 5,
            state: { time > 5 ? .runningBackground : .runningForeground },
            now: { time }, pump: { time += $0 })
        XCTAssertFalse(result.observedInTime)
        XCTAssertLessThanOrEqual(result.elapsed, 5)
    }

    func testMatchingStateReadThatReturnsAfterDeadlineIsRejected() {
        var time: TimeInterval = 0
        let result = ApplicationBackgroundWaiter.wait(timeout: 5,
            state: { time = 5.01; return .runningBackground },
            now: { time }, pump: { _ in XCTFail("An expired read must not restart the budget") })
        XCTAssertFalse(result.observedInTime)
        XCTAssertEqual(result.lastState, .runningBackground)
    }

    func testDelayedRunLoopCannotAcceptALaterBackgroundState() {
        var time: TimeInterval = 0
        var reads = 0
        let result = ApplicationBackgroundWaiter.wait(timeout: 5,
            state: { reads += 1; return reads == 1 ? .runningForeground : .runningBackground },
            now: { time }, pump: { _ in time = 5.01 })
        XCTAssertFalse(result.observedInTime)
        XCTAssertEqual(reads, 1, "Do not perform a fresh observation after the original deadline")
    }
}
