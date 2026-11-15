import XCTest

/// Drives the real edit-profile flow and saves a screenshot after each step to $SHOT_DIR (default /tmp).
final class EditProfileFlowTests: XCTestCase {
    let app = XCUIApplication()
    var step = 0
    var dir: String { ProcessInfo.processInfo.environment["SHOT_DIR"] ?? NSTemporaryDirectory() }

    func shot(_ name: String) {
        step += 1
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%02d_%@.png", step, name)))
    }

    func testRedoInterviewAndSave() throws {
        continueAfterFailure = true
        app.launchArguments = ["-demo", "YES"]
        app.launch()
        sleep(3)
        shot("scan")
        let chip = app.staticTexts.matching(NSPredicate(format: "label == 'DEMO MODE'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "profile chip")
        chip.tap()
        XCTAssertTrue(app.staticTexts["EDIT PROFILE"].waitForExistence(timeout: 5))
        shot("edit_open")
        app.buttons["REDO INTERVIEW"].tap()
        let answers = ["CS 3rd year", "science", "tennis", "coding", "an app", "python", "ml", "I love chai"]
        for (i, a) in answers.enumerated() {
            let field = app.descendants(matching: .any).matching(identifier: "answer").firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10), "answer field q\(i + 1)")
            field.tap(); field.typeText(a)
            if i == 0 || i == answers.count - 1 { shot("q\(i + 1)") }
            let next = app.buttons[i == answers.count - 1 ? "FINISH" : "NEXT"]
            XCTAssertTrue(next.waitForExistence(timeout: 10), "button q\(i + 1)")
            next.tap()
            sleep(1)
        }
        XCTAssertTrue(app.staticTexts["YOUR LINES"].waitForExistence(timeout: 20), "back on edit")
        sleep(1)
        shot("after_interview")
        app.swipeUp()
        shot("after_interview_scrolled")
        app.buttons["SAVE"].tap()
        sleep(2)
        shot("after_save")
        app.staticTexts["DEMO MODE"].firstMatch.tap()
        sleep(2)
        shot("edit_reopened")

        // Edit the name, close with ✕ (no SAVE): the change must stick.
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap(); nameField.typeText("X")
        app.buttons["editClose"].tap()
        sleep(2)
        XCTAssertTrue(app.staticTexts["Test UserX"].waitForExistence(timeout: 5), "name kept after closing with X")
        shot("closed_with_x")
        // Put it back.
        app.staticTexts["DEMO MODE"].firstMatch.tap()
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap(); nameField.typeText(XCUIKeyboardKey.delete.rawValue)
        app.buttons["editClose"].tap()
        sleep(1)
        XCTAssertTrue(app.staticTexts["Test User"].waitForExistence(timeout: 5), "name restored")
    }

    func testInterviewBack() throws {
        app.launchArguments = ["-demo", "YES"]
        app.launch()
        let chip = app.staticTexts["DEMO MODE"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10)); chip.tap()
        app.buttons["REDO INTERVIEW"].tap()
        _ = app.staticTexts["INTERVIEW"].waitForExistence(timeout: 10)
        let field = app.descendants(matching: .any).matching(identifier: "answer").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("CS 3rd year")
        app.buttons["NEXT"].tap()
        XCTAssertTrue(app.staticTexts["Question 2 of 8"].waitForExistence(timeout: 5))
        app.buttons["BACK"].tap()
        XCTAssertTrue(app.staticTexts["Question 1 of 8"].waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "CS 3rd year", "answer restored on BACK")
        shot("interview_back")
    }
}
