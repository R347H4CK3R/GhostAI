import XCTest

@MainActor final class AssistantUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testGeneralShowsGitHubSetupInsteadOfOfflineWhileChatting() {
        let app = launchChatFixture("success")
        let heading = app.descendants(matching: .any).matching(identifier: "chatIdentityAndConnection").firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertTrue(heading.label.contains("GitHub not selected"))
        let field = composer(in: app)
        field.tap(); app.typeText("What repositories can you reach?")
        app.buttons["chatSend"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic reply: What repositories can you reach?"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Apple on device · No live source used"].exists)
        XCTAssertFalse(app.staticTexts["Offline fallback"].exists)
        saveScreenshot(app, name: "General requires GitHub selection, not offline memory")
    }

    func testLongChatRemainsVisibleWhileTypingAndSwipeDownDismissesKeyboard() {
        let app = launchChatFixture("success")
        let field = composer(in: app)
        field.tap(); app.typeText("A draft that must survive keyboard dismissal")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let transcript = app.scrollViews["chatTranscript"]
        XCTAssertTrue(transcript.exists)
        XCTAssertGreaterThan(transcript.frame.height, 120, "Keyboard must not squeeze the transcript away")
        let latest = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic project answer 12.")).firstMatch
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: latest)
        waitForExpectations(timeout: 5)
        saveScreenshot(app, name: "Visible latest message while keyboard is open")
        XCTAssertLessThanOrEqual(field.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        // The scroll container can have no hittable point while its message children do.
        // Start on the verified visible message, not the scroll view's full content bounds.
        let start = latest.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        let finish = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        start.press(forDuration: 0.05, thenDragTo: finish)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "A draft that must survive keyboard dismissal")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["chatKeyboardDone"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        saveScreenshot(app, name: "Long chat after interactive keyboard dismissal")
    }

    func testAcceptedSendClearsDraftDismissesKeyboardAndShowsReply() {
        let app = launchChatFixture("success")
        let field = composer(in: app)
        field.tap(); app.typeText("Show my latest reply")
        app.buttons["chatSend"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "")
        let reply = app.staticTexts["Synthetic reply: Show my latest reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        XCTAssertTrue(reply.isHittable, "A new answer must be scrolled into view")
        XCTAssertFalse(app.buttons["chatSend"].isEnabled, "The cleared composer must not submit an empty message")
        saveScreenshot(app, name: "Visible latest answer and bottom composer")
    }

    func testPendingReplyIsVisibleWhileTypingAndStopPreservesNextDraft() {
        let app = launchChatFixture("pending")
        let field = composer(in: app)
        field.tap(); app.typeText("A request awaiting a response")
        app.buttons["chatSend"].tap()
        let pending = app.staticTexts["chatPendingStatus"]
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        field.tap(); app.typeText("Draft for later")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(pending.isHittable)
        XCTAssertGreaterThan(app.scrollViews["chatTranscript"].frame.height, 120)
        saveScreenshot(app, name: "Pending response with keyboard open")
        app.buttons["chatStop"].tap()
        XCTAssertTrue(pending.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Draft for later")
    }

    func testRejectedSendKeepsDraftAndShowsInlineErrorAfterAlertDismissal() {
        let app = launchChatFixture("success")
        let field = composer(in: app)
        field.tap(); app.typeText("password = synthetic-only")
        app.buttons["chatSend"].tap()
        let alert = app.alerts["Jarvis"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5)); alert.buttons["OK"].tap()
        XCTAssertEqual(field.value as? String, "password = synthetic-only")
        let error = app.staticTexts["chatInlineError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.isHittable)
        XCTAssertFalse(app.buttons["chatStop"].exists)
    }

    func testEmptyModelReplyShowsRecoverableErrorInsteadOfAnEmptyBubble() {
        let app = launchChatFixture("empty")
        let field = composer(in: app)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("Request an answer")
        waitForExactText("Request an answer", in: field, app: app)
        app.buttons["chatSend"].tap()
        let alert = app.alerts["Jarvis"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10)); alert.buttons["OK"].tap()
        let error = app.staticTexts["chatInlineError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("empty answer"))
        XCTAssertTrue(error.isHittable)
        // Distinguish a missing recovery action from a late/partial composer input.
        XCTAssertEqual(field.value as? String, "", "Accepted requests must clear the composer")
        let restore = app.buttons["chatRestoreDraft"]
        if !restore.exists { saveFailureDiagnostics(app, name: "Missing failed-request recovery") }
        XCTAssertTrue(restore.exists, "An accepted request must remain recoverable after the error alert is dismissed")
        app.buttons["chatRestoreDraft"].tap()
        XCTAssertEqual(field.value as? String, "Request an answer")
    }

    func testUnsentDraftSurvivesVoiceSheetAndTabNavigation() {
        let app = launchChatFixture("success")
        let field = composer(in: app)
        field.tap(); app.typeText("Keep this unfinished thought")
        app.buttons["chatVoiceSettings"].tap()
        XCTAssertTrue(app.buttons["chatStartVoiceCall"].waitForExistence(timeout: 5))
        app.buttons["voiceSettingsDone"].tap()
        XCTAssertEqual(field.value as? String, "Keep this unfinished thought")
        app.tabBars.buttons["Memory"].tap()
        app.tabBars.buttons["Assistant"].tap()
        XCTAssertEqual(field.value as? String, "Keep this unfinished thought")
    }

    func testDraftsCannotLeakIntoAnotherProject() {
        let app = launchChatFixture("success")
        let field = composer(in: app)
        field.tap(); app.typeText("General project draft")
        app.buttons["chatKeyboardDone"].tap()
        app.tabBars.buttons["Projects"].tap()
        let otherProject = app.buttons["Synthetic second project"]
        for _ in 0..<8 where !otherProject.isHittable { app.swipeUp() }
        XCTAssertTrue(otherProject.isHittable); otherProject.tap()
        app.tabBars.buttons["Assistant"].tap()
        XCTAssertEqual(field.value as? String, "")
        XCTAssertFalse(app.buttons["chatSend"].isEnabled)
        field.tap(); app.typeText("Second project draft")
        app.buttons["chatKeyboardDone"].tap()
        app.tabBars.buttons["Projects"].tap()
        let general = app.buttons["General"]
        for _ in 0..<8 where !general.isHittable { app.swipeUp() }
        XCTAssertTrue(general.isHittable); general.tap()
        app.tabBars.buttons["Assistant"].tap()
        XCTAssertEqual(field.value as? String, "General project draft")
    }

    func testSavedLumaReferenceRequiresExplicitReviewAndPreservesTypedDraft() {
        let app = launchChatFixture("planning")
        let field = composer(in: app)
        field.tap(); app.typeText("Keep this separate chat draft")
        waitForExactText("Keep this separate chat draft", in: field, app: app)
        app.buttons["chatKeyboardDone"].tap()
        app.buttons["planning.open"].tap()
        let choose = app.buttons["planning.reference.choose"]
        XCTAssertTrue(revealInContent(choose, in: app), "Planning must offer an explicit saved-reference selection"); choose.tap()
        XCTAssertTrue(app.navigationBars["Saved planning reference"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Synthetic workspace for draft isolation"].exists)
        let selected = app.buttons["planning.reference.select.99999999-1111-4111-8111-111111111111"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5)); selected.tap()
        let goal = app.descendants(matching: .any).matching(identifier: "planning.goal").firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        let enteredGoal = goal.value as? String ?? ""
        XCTAssertTrue(enteredGoal.isEmpty || enteredGoal == (goal.placeholderValue ?? ""), "Reference prose must not become an automatically trusted goal")
        XCTAssertFalse(app.buttons["planning.ask"].exists)
        XCTAssertTrue(revealInContent(goal, in: app)); goal.tap()
        app.typeText("Choose my next safe step")
        waitForExactText("Choose my next safe step", in: goal, app: app)
        app.buttons["planning.keyboardDone"].tap()
        let review = app.buttons["planning.reviewQuestion"]
        XCTAssertTrue(revealInContent(review, in: app)); review.tap()
        let question = app.staticTexts["planning.question.preview"]
        XCTAssertTrue(revealInContent(question, in: app, readOnlyText: true))
        XCTAssertTrue(question.label.contains("Choose my next safe step"))
        XCTAssertTrue(question.label.contains("Synthetic release"))
        XCTAssertTrue(question.label.contains("untrusted"))
        XCTAssertLessThanOrEqual(question.label.count, 2000)
        let reviewedQuestion = question.label
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic reply: Help me plan")).firstMatch.exists)
        saveScreenshot(app, name: "Reviewed Luma reference and exact planning question")
        let ask = app.buttons["planning.ask"]
        XCTAssertTrue(revealInContent(ask, in: app)); ask.tap()
        let reply = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic reply: Help me plan")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        XCTAssertEqual(reply.label, "Synthetic reply: " + reviewedQuestion)
        XCTAssertEqual(field.value as? String, "Keep this separate chat draft")
        app.tabBars.buttons["Memory"].tap()
        let original = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Luma checklist snapshot (reference only, not an executable job)")).firstMatch
        XCTAssertTrue(revealInContent(original, in: app), "Planning must preserve the imported original")
    }

    func testSavedReferencePickerCancellationAndRemovalInvalidateOnlyTheReview() {
        let app = launchChatFixture("planning")
        app.buttons["planning.open"].tap()
        let choose = app.buttons["planning.reference.choose"]
        XCTAssertTrue(revealInContent(choose, in: app)); choose.tap()
        let selected = app.buttons["planning.reference.select.99999999-1111-4111-8111-111111111111"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5)); selected.tap()
        let goal = app.descendants(matching: .any).matching(identifier: "planning.goal").firstMatch
        let review = app.buttons["planning.reviewQuestion"]
        XCTAssertFalse(review.isEnabled, "A selected note does not replace a user-entered goal")
        XCTAssertTrue(revealInContent(goal, in: app)); goal.tap(); app.typeText("My own planning goal")
        waitForExactText("My own planning goal", in: goal, app: app)
        app.buttons["planning.keyboardDone"].tap()
        XCTAssertTrue(revealInContent(review, in: app)); review.tap()
        let question = app.staticTexts["planning.question.preview"]
        XCTAssertTrue(revealInContent(question, in: app, readOnlyText: true)); let originalQuestion = question.label
        XCTAssertTrue(revealInContent(choose, in: app, searchUpIfMissing: true)); choose.tap()
        let cancel = app.buttons["planning.reference.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        XCTAssertTrue(revealInContent(question, in: app, readOnlyText: true))
        XCTAssertEqual(question.label, originalQuestion, "Cancelling the picker must preserve the already reviewed selection")
        let remove = app.buttons["planning.reference.remove"]
        XCTAssertTrue(revealInContent(remove, in: app, searchUpIfMissing: true)); remove.tap()
        XCTAssertTrue(question.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["planning.ask"].exists)
        // Traverse the former review region before preparing a replacement.
        // An offscreen List row alone is not proof that removal invalidated it.
        let followingSection = app.staticTexts["Bring your Luma notes with you"]
        XCTAssertTrue(revealInContent(followingSection, in: app, checkingContent: {
            XCTAssertFalse(question.exists, "Removing the reference must invalidate the previous question")
            XCTAssertFalse(app.buttons["planning.ask"].exists, "The old question must no longer be sendable")
        }))
        XCTAssertTrue(revealInContent(goal, in: app, searchUpIfMissing: true))
        XCTAssertEqual(goal.value as? String, "My own planning goal")
        XCTAssertTrue(revealInContent(review, in: app)); review.tap()
        XCTAssertTrue(revealInContent(question, in: app, readOnlyText: true))
        XCTAssertFalse(question.label.contains("Synthetic release"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic reply: Help me plan")).firstMatch.exists)
        app.tabBars.buttons["Memory"].tap()
        let original = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Luma checklist snapshot (reference only, not an executable job)")).firstMatch
        XCTAssertTrue(revealInContent(original, in: app))
    }

    func testPlanningSavesReviewedChecklistAndPreservesTypedDraft() {
        let app = launchChatFixture("success")
        let field = composer(in: app)
        field.tap(); app.typeText("Keep my original typed draft")
        waitForExactText("Keep my original typed draft", in: field, app: app)
        app.buttons["chatKeyboardDone"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["planning.open"].tap()
        let goal = app.descendants(matching: .any).matching(identifier: "planning.goal").firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        goal.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("Synthetic release checklist")
        waitForExactText("Synthetic release checklist", in: goal, app: app)
        app.buttons["planning.keyboardDone"].tap()
        let makeChecklist = app.buttons["planning.checklist"]
        XCTAssertTrue(revealInContent(makeChecklist, in: app)); makeChecklist.tap()
        let save = app.buttons["planning.save"]
        XCTAssertTrue(revealInContent(save, in: app)); save.tap()
        let status = app.staticTexts["Saved to this workspace. Existing approved sync settings apply. This is a reference checklist, not a scheduled job."]
        XCTAssertTrue(revealInContent(status, in: app))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(field.value as? String, "Keep my original typed draft")
        app.tabBars.buttons["Memory"].tap()
        let saved = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Goal: Synthetic release checklist")).firstMatch
        XCTAssertTrue(revealInContent(saved, in: app))
        saveScreenshot(app, name: "Jarvis reviewed planning saved to canonical memory")
    }

    func testFailedPlanningQuestionCanBeRestoredInChat() {
        let app = launchChatFixture("empty")
        app.buttons["planning.open"].tap()
        let goal = app.descendants(matching: .any).matching(identifier: "planning.goal").firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        goal.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("Synthetic planning retry")
        waitForExactText("Synthetic planning retry", in: goal, app: app)
        app.buttons["planning.keyboardDone"].tap()
        let review = app.buttons["planning.reviewQuestion"]
        XCTAssertTrue(revealInContent(review, in: app)); review.tap()
        let ask = app.buttons["planning.ask"]
        XCTAssertTrue(revealInContent(ask, in: app)); ask.tap()
        let alert = app.alerts["Jarvis"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10)); alert.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["chatRestoreDraft"].waitForExistence(timeout: 5))
        app.buttons["chatRestoreDraft"].tap()
        XCTAssertTrue((composer(in: app).value as? String ?? "").contains("Synthetic planning retry"))
        saveScreenshot(app, name: "Jarvis planning failure retains retry prompt")
    }

    func testLumaEditableCopiesRequireSeparateOptInThatResetsOnClose() {
        let app = launchChatFixture("planning")
        app.tabBars.buttons["Memory"].tap()
        let open = app.buttons["conversationImport.open"]
        XCTAssertTrue(revealInContent(open, in: app)); open.tap()
        let format = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ChatGPT conversations JSON")).firstMatch
        XCTAssertTrue(revealInContent(format, in: app)); format.tap()
        app.buttons["Luma plain backup JSON"].tap()
        let option = app.switches["conversationImport.editableChecklists"]
        XCTAssertTrue(option.waitForExistence(timeout: 5), "The separate Luma copy option must exist")
        XCTAssertTrue(revealInContent(option, in: app), "Luma import must offer a separate reviewed editable-copy choice")
        XCTAssertEqual(option.value as? String, "0")
        option.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(option.value as? String, "1")
        app.buttons["conversationImport.close"].tap()
        XCTAssertTrue(revealInContent(open, in: app, searchUpIfMissing: true)); open.tap()
        XCTAssertTrue(revealInContent(format, in: app)); format.tap()
        app.buttons["Luma plain backup JSON"].tap()
        XCTAssertTrue(revealInContent(option, in: app)); XCTAssertEqual(option.value as? String, "0")
        app.buttons["conversationImport.close"].tap()
        let original = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Luma checklist snapshot (reference only, not an executable job)")).firstMatch
        XCTAssertTrue(revealInContent(original, in: app, searchUpIfMissing: true))
    }

    func testEditableChecklistSaveKeepsOriginalSnapshotAndCompletionSurvivesReopening() {
        let app = launchChatFixture("checklists")
        app.tabBars.buttons["Memory"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "checklist.edit.")).firstMatch
        XCTAssertTrue(revealInContent(edit, in: app)); edit.tap()
        let goal = app.descendants(matching: .any).matching(identifier: "checklist.goal").firstMatch
        let step = app.descendants(matching: .any).matching(identifier: "checklist.step").firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        XCTAssertEqual(goal.value as? String, "Synthetic editable goal")
        XCTAssertEqual(step.value as? String, "Verify the original snapshot")
        appendAtEnd("\nReviewed goal", to: goal, expected: "Synthetic editable goal\nReviewed goal", app: app)
        app.buttons["checklist.keyboardDone"].tap()
        XCTAssertTrue(revealInContent(step, in: app))
        appendAtEnd("\nReviewed step", to: step, expected: "Verify the original snapshot\nReviewed step", app: app)
        app.buttons["checklist.keyboardDone"].tap()
        let done = app.switches["checklist.done"]
        XCTAssertTrue(revealInContent(done, in: app)); XCTAssertEqual(done.value as? String, "0")
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(done.value as? String, "1")
        let save = app.buttons["checklist.save"]
        XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.buttons["checklist.cancel"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(revealInContent(edit, in: app, searchUpIfMissing: true)); edit.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5)); XCTAssertEqual(done.value as? String, "1")
        XCTAssertEqual(goal.value as? String, "Synthetic editable goal\nReviewed goal")
        XCTAssertEqual(step.value as? String, "Verify the original snapshot\nReviewed step")
        app.buttons["checklist.cancel"].tap()
        let original = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Luma checklist snapshot (reference only, not an executable job)")).firstMatch
        XCTAssertTrue(revealInContent(original, in: app, readOnlyText: true, searchUpIfMissing: true))
        XCTAssertTrue(original.label.contains("Status: Not completed"))
        saveScreenshot(app, name: "Editable Luma copy saved while original snapshot stays unchanged")
    }

    func testEditableChecklistCancelDiscardsChangesAndUnknownVersionRemainsVisible() {
        let app = launchChatFixture("checklists")
        app.tabBars.buttons["Memory"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "checklist.edit.")).firstMatch
        XCTAssertTrue(revealInContent(edit, in: app)); edit.tap()
        let goal = app.descendants(matching: .any).matching(identifier: "checklist.goal").firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        appendAtEnd("\nDiscard this goal", to: goal, expected: "Synthetic editable goal\nDiscard this goal", app: app)
        app.buttons["checklist.keyboardDone"].tap()
        let step = app.descendants(matching: .any).matching(identifier: "checklist.step").firstMatch
        XCTAssertTrue(revealInContent(step, in: app))
        appendAtEnd("\nDiscard this step", to: step, expected: "Verify the original snapshot\nDiscard this step", app: app)
        app.buttons["checklist.keyboardDone"].tap()
        let done = app.switches["checklist.done"]
        XCTAssertTrue(revealInContent(done, in: app))
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(done.value as? String, "1")
        app.buttons["checklist.cancel"].tap()
        XCTAssertTrue(revealInContent(edit, in: app, searchUpIfMissing: true)); edit.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5)); XCTAssertEqual(done.value as? String, "0")
        XCTAssertEqual(goal.value as? String, "Synthetic editable goal")
        XCTAssertEqual(step.value as? String, "Verify the original snapshot")
        app.buttons["checklist.cancel"].tap()
        let unsupported = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Synthetic future checklist payload is preserved")).firstMatch
        XCTAssertTrue(revealInContent(unsupported, in: app, readOnlyText: true))
        XCTAssertFalse(app.buttons["checklist.edit.99999999-2222-8222-8222-222222222222"].exists)
    }

    func testEditableChecklistDeletionIdentifiesTheGoalAndCancelPreservesIt() {
        let app = launchChatFixture("checklists")
        app.tabBars.buttons["Memory"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "checklist.edit.")).firstMatch
        XCTAssertTrue(revealInContent(edit, in: app))
        let delete = app.buttons["Delete checklist: Synthetic editable goal"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Accessible deletion must identify which checklist will be removed")
        XCTAssertTrue(revealInContent(delete, in: app)); delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Synthetic editable goal")).firstMatch.exists)
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(revealInContent(edit, in: app, searchUpIfMissing: true))
    }

    func testChecklistEditorSurvivesBackgroundWithoutVoiceRequest() {
        let app = launchChatFixture("checklists")
        app.tabBars.buttons["Memory"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "checklist.edit.")).firstMatch
        XCTAssertTrue(revealInContent(edit, in: app)); edit.tap()
        let goal = app.descendants(matching: .any).matching(identifier: "checklist.goal").firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        appendAtEnd("\nKeep this unsaved draft", to: goal, expected: "Synthetic editable goal\nKeep this unsaved draft", app: app)
        app.buttons["checklist.keyboardDone"].tap()
        for _ in 0..<2 {
            backgroundAndReturn(app)
            XCTAssertTrue(goal.waitForExistence(timeout: 5))
            XCTAssertEqual(goal.value as? String, "Synthetic editable goal\nKeep this unsaved draft")
            XCTAssertFalse(app.buttons["chatStartVoiceCall"].exists)
        }
        app.buttons["checklist.cancel"].tap()
    }

    private func backgroundAndReturn(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // project.yml fixes CFBundleDisplayName to Jarvis, including the synthetic fixture.
        let icons = springboard.icons.matching(identifier: "Jarvis")
        var rejectedState: XCUIApplication.State?
        func invalidAppStateObserved() -> Bool {
            let state = app.state
            switch state {
            case .runningForeground, .runningBackground, .runningBackgroundSuspended: break
            default: rejectedState = state
            }
            return rejectedState != nil
        }
        func fail(_ message: String) {
            let diagnostics = XCTAttachment(string: """
                \(message)
                App state: \(app.state.rawValue); rejected state: \(rejectedState.map { String($0.rawValue) } ?? "none")
                SpringBoard hierarchy:
                \(springboard.debugDescription)
                """)
            diagnostics.name = "Checklist Home-and-return failure"
            diagnostics.lifetime = .keepAlways; add(diagnostics)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Checklist Home-and-return failure screen"
            screenshot.lifetime = .keepAlways; add(screenshot)
            XCTFail(message)
        }
        guard !invalidAppStateObserved() else {
            fail("Cannot press Home with an unknown or not-running app state"); return
        }
        guard !icons.allElementsBoundByIndex.contains(where: { $0.exists && $0.isHittable }) else {
            fail("The Jarvis Home icon must not be hittable before pressing Home"); return
        }
        XCUIDevice.shared.press(.home)
        var homeVisible = false
        let home = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            // Stop promptly on a known bad state. Cached foreground (4) is not
            // background or liveness proof; only the actual Home icon satisfies this wait.
            if invalidAppStateObserved() { return true }
            homeVisible = icons.allElementsBoundByIndex.contains { icon in
                guard icon.exists else { return false }
                let frame = icon.frame
                return !frame.isEmpty && springboard.frame.contains(frame) && icon.isHittable
            }
            return homeVisible
        }, object: springboard)
        let result = XCTWaiter.wait(for: [home], timeout: 5)
        guard !invalidAppStateObserved() else {
            fail("Cannot reactivate after observing an unknown or not-running app state"); return
        }
        guard result == .completed && homeVisible else {
            fail("The Jarvis Home icon must become visible and hittable within 5 seconds; wait result: \(result.rawValue)"); return
        }
        // This proves user-visible Home followed by the callers' exact retained editor/draft,
        // not a PID or scene-callback count. Fixture launches reset state and discard the
        // local unsaved draft, so the unchanged caller assertions reject an implicit relaunch.
        app.activate()
    }

    func testVoiceRequestWaitsForChecklistSaveWithoutLosingDraft() {
        verifyChecklistVoiceDeferral(dismissal: .save, repeatRequest: true)
    }

    func testVoiceRequestWaitsForChecklistCancelWithoutSavingDraft() {
        verifyChecklistVoiceDeferral(dismissal: .cancel)
    }

    func testVoiceRequestWaitsForInteractiveChecklistDismissalWithoutSavingDraft() {
        verifyChecklistVoiceDeferral(dismissal: .swipe)
    }

    private enum ChecklistDismissal: Equatable { case save, cancel, swipe }
    private func verifyChecklistVoiceDeferral(dismissal: ChecklistDismissal, repeatRequest: Bool = false) {
        let app = launchChatFixture("checklists", extraArguments: ["--uitest-checklist-voice-on-return"])
        app.tabBars.buttons["Memory"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "checklist.edit.")).firstMatch
        XCTAssertTrue(revealInContent(edit, in: app)); edit.tap()
        let goal = app.descendants(matching: .any).matching(identifier: "checklist.goal").firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        let reviewedGoal = "Synthetic editable goal\nKeep this unsaved draft"
        appendAtEnd("\nKeep this unsaved draft", to: goal, expected: reviewedGoal, app: app)
        app.buttons["checklist.keyboardDone"].tap()
        let voiceStart = app.buttons["chatStartVoiceCall"]
        for _ in 0..<(repeatRequest ? 2 : 1) {
            backgroundAndReturn(app)
            XCTAssertTrue(goal.waitForExistence(timeout: 5), "Backgrounding or voice navigation must not discard an unsaved checklist")
            XCTAssertEqual(goal.value as? String, reviewedGoal)
            XCTAssertFalse(voiceStart.exists, "Voice controls must wait until this editor actually dismisses")
            XCTAssertFalse(app.alerts.firstMatch.exists, "A navigation request must not ask for microphone permission")
        }
        saveScreenshot(app, name: "Voice request preserves the unsaved checklist editor")
        switch dismissal {
        case .save: app.buttons["checklist.save"].tap()
        case .cancel: app.buttons["checklist.cancel"].tap()
        case .swipe:
            let navigation = app.navigationBars["Edit checklist"]
            XCTAssertTrue(navigation.exists)
            navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96)))
        }
        XCTAssertTrue(voiceStart.waitForExistence(timeout: 8), "The queued request must survive dismissal and open voice controls")
        XCTAssertEqual(voiceStart.label, "Start voice call")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.buttons["voiceSettingsDone"].tap()
        XCTAssertTrue(app.tabBars.buttons["Assistant"].isSelected)
        app.tabBars.buttons["Memory"].tap()
        XCTAssertTrue(revealInContent(edit, in: app, searchUpIfMissing: true)); edit.tap()
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        XCTAssertEqual(goal.value as? String, dismissal == .save ? reviewedGoal : "Synthetic editable goal")
        app.buttons["checklist.cancel"].tap()
        XCTAssertTrue(app.buttons["checklist.cancel"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Memory"].isSelected, "The same request must not navigate a second time")
        XCTAssertFalse(voiceStart.exists)
    }

    private func appendAtEnd(_ suffix: String, to field: XCUIElement, expected: String, app: XCUIApplication) {
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // The bottom-right of a multiline field places the insertion point after its text.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        app.typeText(suffix)
        waitForExactText(expected, in: field, app: app)
    }

    private func waitForExactText(_ text: String, in field: XCUIElement, app: XCUIApplication,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: field)
        let result = XCTWaiter.wait(for: [matches], timeout: 5)
        let actual = field.value as? String
        if result != .completed || actual != text {
            saveFailureDiagnostics(app, name: "Exact input failure: \(field.identifier)")
        }
        // Assert the value first: a waiter timeout must not hide what actually arrived.
        XCTAssertEqual(actual, text, "Exact input wait result: \(result.rawValue)", file: file, line: line)
        XCTAssertEqual(result, .completed, "Input must settle within the existing deadline", file: file, line: line)
    }

    private func saveFailureDiagnostics(_ app: XCUIApplication, name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        saveScreenshot(app, name: name)
    }

    private func launchChatFixture(_ scenario: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-chat", scenario] + extraArguments
        app.launch()
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 15))
        return app
    }

    private func composer(in app: XCUIApplication) -> XCUIElement {
        let field = app.descendants(matching: .any).matching(identifier: "chatComposer").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        return field
    }

    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func revealInContent(_ element: XCUIElement, in app: XCUIApplication,
                                 readOnlyText: Bool = false, searchUpIfMissing: Bool = false,
                                 checkingContent: (() -> Void)? = nil) -> Bool {
        // iOS 26 can report a List row as hittable behind the navigation bar.
        // Scroll only inside the unobscured content, and require the whole target
        // to be below navigation and above the keyboard/tab bar before tapping.
        for attempt in 0...8 {
            checkingContent?()
            let bounds = app.frame
            let navigation = app.navigationBars.firstMatch
            let tabs = app.tabBars.firstMatch
            let keyboard = app.keyboards.firstMatch
            let keyboardAccessory = app.otherElements.matching(identifier: "SystemInputAssistantView").firstMatch
            let top = max(bounds.minY, navigation.exists ? navigation.frame.maxY : bounds.minY) + 8
            var bottom = min(bounds.maxY, tabs.exists ? tabs.frame.minY : bounds.maxY,
                             keyboard.exists ? keyboard.frame.minY : bounds.maxY) - 8
            if keyboard.exists && keyboardAccessory.exists { bottom = min(bottom, keyboardAccessory.frame.minY - 8) }
            guard bottom - top > 80 else { return false }
            let frame = element.exists ? element.frame : .zero
            if !frame.isEmpty && frame.minY >= top && frame.maxY <= bottom && element.isHittable { return true }
            // The exact question can be taller than one screen. Materialize its
            // List row by scrolling before reading its complete accessible label.
            // This exception is only for static text, never for a tap target.
            if readOnlyText && !frame.isEmpty && element.elementType == .staticText &&
                frame.minX >= bounds.minX && frame.maxX <= bounds.maxX &&
                min(frame.maxY, bottom) - max(frame.minY, top) >= 80 && element.isHittable { return true }
            guard attempt < 8 else {
                saveFailureDiagnostics(app, name: "Content visibility failure: \(element.identifier)")
                return false
            }
            let moveDown = frame.isEmpty ? searchUpIfMissing : frame.minY < top
            let upper = top + (bottom - top) * 0.25
            let lower = top + (bottom - top) * 0.75
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: bounds.width / 2, dy: (moveDown ? upper : lower) - bounds.minY))
            let finish = origin.withOffset(CGVector(dx: bounds.width / 2, dy: (moveDown ? lower : upper) - bounds.minY))
            start.press(forDuration: 0.05, thenDragTo: finish)
        }
        return false
    }

    func testLaunchMemoryPersistenceAndDeletion() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Memory"].waitForExistence(timeout: 20))
        let launch = XCTAttachment(screenshot: app.screenshot()); launch.name = "Assistant launch"; launch.lifetime = .keepAlways; add(launch)
        app.tabBars.buttons["Memory"].tap()
        let note = "UI verification " + UUID().uuidString.prefix(8)
        let field = app.descendants(matching: .any).matching(identifier: "memoryNoteInput").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText(note)
        // The event synthesizer can return before all characters reach the field.
        // Do not submit the first character while the rest are still arriving.
        let inputMatches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", note), object: field)
        // A standalone waiter lets the equality assertion report the actual input
        // even when a timeout would otherwise stop this test immediately.
        let inputWaitResult = XCTWaiter.wait(for: [inputMatches], timeout: 10)
        let actualInput = field.value as? String
        XCTAssertEqual(actualInput, note, "Exact note input wait result: \(inputWaitResult.rawValue)")
        XCTAssertEqual(inputWaitResult, .completed,
                       "Exact note input timed out; actual: \(String(describing: actualInput)); expected: \(note)")
        let remember = app.buttons["memoryNoteSaveKeyboard"]
        XCTAssertTrue(remember.waitForExistence(timeout: 5))
        XCTAssertTrue(remember.isEnabled)
        XCTAssertTrue(remember.isHittable)
        XCTAssertLessThanOrEqual(remember.frame.maxY, app.keyboards.firstMatch.frame.minY)
        remember.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let saved = app.staticTexts[note]
        XCTAssertTrue(revealInContent(saved, in: app), "The exact note must be saved before relaunch")
        app.terminate(); app.launch()
        app.tabBars.buttons["Memory"].tap()
        for _ in 0..<5 where !saved.isHittable { app.swipeUp() }
        XCTAssertTrue(saved.exists)
        let memory = XCTAttachment(screenshot: app.screenshot()); memory.name = "Saved offline memory"; memory.lifetime = .keepAlways; add(memory)
        let delete = app.buttons["Delete note: " + note]
        for _ in 0..<3 where !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.exists); delete.tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(saved.exists, "Cancelling must preserve the note")
        delete.tap()
        app.buttons["Delete note"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: saved)
        waitForExpectations(timeout: 5)
        app.terminate(); app.launch()
        app.tabBars.buttons["Memory"].tap()
        XCTAssertFalse(app.staticTexts[note].exists, "Deletion must persist across launches")
    }

    func testAppUpdatesNavigationDoesNotStartNetworkOrInstallAutomatically() {
        let app = XCUIApplication(); app.launch()
        let about = app.tabBars.buttons["About"]
        XCTAssertTrue(about.waitForExistence(timeout: 15)); about.tap()
        let openUpdates = app.buttons["updates.open"]
        XCTAssertTrue(openUpdates.waitForExistence(timeout: 5)); openUpdates.tap()
        let title = app.navigationBars["App updates"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["updates.status"].label, "Check for a published iPhone update.")
        XCTAssertTrue(app.buttons["updates.check"].isEnabled)
        XCTAssertFalse(app.buttons["updates.install"].exists)
        saveScreenshot(app, name: "App updates requires an explicit check and SideStore approval")
        let back = title.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        XCTAssertTrue(openUpdates.waitForExistence(timeout: 5)); openUpdates.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["updates.status"].label, "Check for a published iPhone update.")
        XCTAssertFalse(app.buttons["updates.install"].exists)
        app.tabBars.buttons["Assistant"].tap()
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 5))
    }

    func testCapabilitiesAndVoiceControlsAreVisible() {
        let app = XCUIApplication(); app.launch()
        let voice = app.buttons["chatVoiceSettings"]
        XCTAssertTrue(voice.waitForExistence(timeout: 15)); voice.tap()
        XCTAssertTrue(app.buttons["chatStartVoiceCall"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["Continue active voice in background"].exists)
        app.buttons["voiceSettingsDone"].tap()
        app.tabBars.buttons["About"].tap()
        let title = app.navigationBars["Capabilities"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Capabilities"; shot.lifetime = .keepAlways; add(shot)
    }
    func testEncryptedTransferCancelsWithoutExport() {
        let app = XCUIApplication(); app.launch()
        app.tabBars.buttons["Memory"].tap()
        let open = app.buttons["encryptedTransferOpen"]
        for _ in 0..<4 where !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        let passphrase = app.secureTextFields["encryptedExportPassphrase"]
        XCTAssertTrue(passphrase.waitForExistence(timeout: 10))
        passphrase.tap(); app.typeText("synthetic test phrase")
        let repeatField = app.secureTextFields["encryptedExportRepeat"]
        repeatField.tap(); app.typeText("synthetic test phrase")
        let review = app.buttons["encryptedExportReview"]
        for _ in 0..<3 where !review.isHittable { app.swipeUp() }
        review.tap()
        let confirmation = app.alerts["Export encrypted memory?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        confirmation.buttons["Cancel"].tap()
        XCTAssertFalse(review.isEnabled, "Cancelling must clear export passphrases")
        app.buttons["Done"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 10))
    }

    func testPrivateGitHubConsentCanCancelWithoutConnecting() {
        let app = XCUIApplication(); app.launch()
        app.tabBars.buttons["Projects"].tap()
        let direct = app.switches["github-direct-install-toggle"]
        // A partly visible row can be hittable while its thumb is under the floating tab bar.
        XCTAssertTrue(revealInContent(direct, in: app), "Direct-install acknowledgment must be fully above the tab bar")
        // SwiftUI exposes the whole labeled row as a Switch; tap its actual thumb.
        direct.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.tabBars.buttons["Projects"].isSelected, "Tapping the switch must not select a tab behind it")
        XCTAssertEqual(direct.value as? String, "1", "The direct-install acknowledgment must be enabled")
        let token = app.secureTextFields["github-token-field"]
        XCTAssertTrue(revealInContent(token, in: app), "Token field must be unobscured before entering the synthetic token")
        token.tap(); app.typeText("github_pat_SYNTHETIC_TEST_ONLY_123")
        let connect = app.buttons["github-connect-button"]
        XCTAssertTrue(revealInContent(connect, in: app), "Consent button must not be behind the navigation bar or keyboard")
        XCTAssertTrue(connect.isEnabled)
        connect.tap()
        let consent = app.alerts["Use this GitHub token?"]
        XCTAssertTrue(consent.waitForExistence(timeout: 10))
        // iOS 26 exposes the same alert action as a nested button and wrapper.
        // Scope to the action identifier inside this alert, then select its first representation.
        consent.buttons.matching(identifier: "github-cancel-connect").firstMatch.tap()
        XCTAssertTrue(consent.waitForNonExistence(timeout: 10))
        XCTAssertFalse(connect.isEnabled, "Cancelled consent must clear the synthetic token")
        XCTAssertFalse(app.staticTexts["Checking GitHub account"].exists)
    }

}

