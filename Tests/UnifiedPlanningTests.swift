import XCTest
@testable import AsterionVeyra

final class UnifiedPlanningTests: XCTestCase {
    func testPlanUsesAllStepsWithoutClaimingExecution() throws {
        let text = try UnifiedPlanning.checklist(goal: "Prepare release", kit: .project)
        XCTAssertTrue(text.contains("[ ]"))
        XCTAssertTrue(text.contains("Prepare release"))
        XCTAssertTrue(text.contains("not executed"))
    }
    func testRejectsEmptyLongAndUnsafeGoals() {
        for goal in [" ", String(repeating: "a", count: 301), "api_key=sample"] {
            XCTAssertThrowsError(try UnifiedPlanning.checklist(goal: goal, kit: .daily))
        }
    }
    func testPairedGoalIsReadOnlyAndExcludesImplicitMemory() throws {
        let goal = try UnifiedPlanning.pairedGoal(goal: "Investigate failing tests")
        XCTAssertTrue(goal.contains("Read-only"))
        XCTAssertTrue(goal.contains("Investigate failing tests"))
        XCTAssertTrue(goal.contains("Do not modify"))
        XCTAssertLessThan(goal.count, 2000)
        XCTAssertThrowsError(try UnifiedPlanning.pairedGoal(goal: "api_key=sample"))
    }
    func testModelDraftIsBoundedAndDoesNotGrantTools() throws {
        let prompt = try UnifiedPlanning.question(goal: "Prepare release", kit: .project)
        XCTAssertLessThanOrEqual(prompt.count, 2000)
        XCTAssertTrue(prompt.contains("Do not claim"))
    }
}
