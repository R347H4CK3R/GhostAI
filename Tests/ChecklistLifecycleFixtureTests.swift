#if DEBUG
import XCTest
@testable import AsterionVeyra

final class ChecklistLifecycleFixtureTests: XCTestCase {
    func testReducedRouteRequiresExplicitScenarioAndIsolatedChecklistInput() {
        for scenario in ["editor", "form", "privacy-qa"] {
            let fixture = ChecklistLifecycleUITestFixture.fromLaunchArguments([
                "--uitest-chat", "checklists", "--uitest-checklist-lifecycle", scenario
            ])
            XCTAssertEqual(fixture?.scenario.rawValue, scenario)
            XCTAssertEqual(fixture?.checklist.goal, "Synthetic editable goal")
            XCTAssertEqual(fixture?.checklist.step, "Verify the original snapshot")
            XCTAssertEqual(fixture?.note.project, "General")
        }
    }

    func testMissingMalformedOrNonChecklistArgumentsDoNotSelectReducedApp() {
        for arguments in [[], ["--uitest-checklist-lifecycle", "editor"],
                          ["--uitest-chat", "checklists"],
                          ["--uitest-chat", "checklists", "--uitest-checklist-lifecycle"],
                          ["--uitest-chat", "checklists", "--uitest-checklist-lifecycle", "unknown"],
                          ["--uitest-chat", "success", "--uitest-checklist-lifecycle", "editor"]] {
            XCTAssertNil(ChecklistLifecycleUITestFixture.fromLaunchArguments(arguments))
        }
    }
}
#endif
