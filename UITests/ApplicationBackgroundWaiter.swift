import XCTest

/// Test-only observation scheduling. It never activates or relaunches the app.
@MainActor enum ApplicationBackgroundWaiter {
    struct Observation {
        let observedInTime: Bool
        let lastState: XCUIApplication.State
        let elapsed: TimeInterval
    }

    static func wait(timeout: TimeInterval = 5,
                     state: () -> XCUIApplication.State,
                     now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                     pump: (TimeInterval) -> Void = { RunLoop.current.run(until: Date(timeIntervalSinceNow: $0)) }) -> Observation {
        let started = now()
        let deadline = started + timeout
        var lastState = XCUIApplication.State.unknown
        guard timeout.isFinite, timeout > 0 else {
            return Observation(observedInTime: false, lastState: lastState, elapsed: 0)
        }
        while now() <= deadline {
            // Snapshot the public state once. Predicate expectations poll about
            // once per second and can miss an in-time state update near timeout.
            lastState = state()
            let observedAt = now()
            if observedAt > deadline { break }
            if lastState == .runningBackground || lastState == .runningBackgroundSuspended {
                return Observation(observedInTime: true, lastState: lastState, elapsed: observedAt - started)
            }
            // Only an observed foreground process may still be transitioning.
            // Stopped, unknown or future states cannot prove continuity. Fail
            // immediately so a later background state cannot erase that gap.
            guard lastState == .runningForeground else {
                return Observation(observedInTime: false, lastState: lastState, elapsed: observedAt - started)
            }
            let remaining = deadline - now()
            if remaining <= 0 { break }
            // Let XCTest's asynchronous application-state updates reach the main
            // run loop. Never add a second budget or accept an expired read.
            pump(min(0.05, remaining))
        }
        return Observation(observedInTime: false, lastState: lastState, elapsed: now() - started)
    }
}
