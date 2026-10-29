import XCTest

/// Smoke test: a fresh launch (setup not finished) opens the setup window.
final class LaunchTests: XCTestCase {
    func testFirstLaunchOpensSetup() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasFinishedSetup", "NO", "-setup.stepsSeen", "()"]
        app.launch()
        XCTAssertTrue(app.windows["Obscura Setup"].waitForExistence(timeout: 30))
    }
}
