import XCTest

/// Fills the profile as an astrophysics PhD through the real interview, slowly enough to screen-record.
final class FillAstroProfileTests: XCTestCase {
    func testFillAstroProfile() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES"]
        app.launch()
        sleep(2)
        let chip = app.staticTexts["DEMO MODE"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10)); chip.tap()
        sleep(1)
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        name.typeText("Dhyan")
        sleep(1)
        app.buttons["REDO INTERVIEW"].tap()
        let answers = [
            "Astrophysics PhD, final year",
            "Exoplanets, orbital mechanics and space telescopes",
            "Astrophotography and rock climbing",
            "Running telescope data simulations for my thesis",
            "Finding exoplanet atmospheres with machine learning",
            "Orbital mechanics or reading telescope data",
            "Speeding up my Python ML pipeline",
            "I host stargazing nights on the roof every Friday",
        ]
        let field = app.descendants(matching: .any).matching(identifier: "answer").firstMatch
        for (i, a) in answers.enumerated() {
            XCTAssertTrue(field.waitForExistence(timeout: 10), "q\(i + 1)")
            sleep(1)
            field.tap(); field.typeText(a)
            sleep(1)
            app.buttons[i == answers.count - 1 ? "FINISH" : "NEXT"].tap()
        }
        XCTAssertTrue(app.staticTexts["YOUR LINES"].waitForExistence(timeout: 25))
        sleep(2)
        app.swipeUp(); sleep(2)
        app.swipeUp(); sleep(2)
        app.buttons["SAVE"].tap()
        sleep(2)
        // Show the result on the scan screen, then reopen the profile to show it saved.
        chip.tap(); sleep(2)
        app.swipeUp(); sleep(2)
        app.buttons["editClose"].tap()
        sleep(2)
    }
}
