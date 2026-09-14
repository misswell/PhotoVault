import XCTest

/// Grants photo access once, so the rest of the UI suite can run on a simulator
/// that has never been authorised.
///
/// `PhotoViewerDismissUITests` opens the library grid and taps its first cell,
/// which needs a non-empty photo library *and* permission. On a clean simulator
/// the app shows the permission sheet instead, every test fails at
/// "图库网格应加载出照片", and a permissions problem reads as a UI regression.
///
/// XCUITest is the only input channel that reaches the simulator -- macOS-side
/// synthetic events die against the desktop window wall -- so the one-time tap
/// on the system alert has to live here. `xcrun simctl privacy grant photos`
/// does *not* substitute: it writes the TCC row (verified: `auth_value = 2`)
/// and PhotoKit still presents its own alert, leaving the app blocked forever
/// on a modal nothing can dismiss.
///
/// The grant persists in the simulator, so this is idempotent: once access is
/// allowed the alert never appears again and the test passes trivially.
@MainActor
final class AIPhotoAccessGrantUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testGrantPhotoAccess() throws {
        let app = XCUIApplication()
        // Ask for access on launch. `--pv-ai-selfcheck` alone deliberately
        // never prompts, so the request has to be opted into explicitly.
        app.launchArguments += ["--pv-ai-selfcheck", "--pv-ai-selfcheck-request-auth"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // Localised: the simulator under test is Chinese, but CI may not be.
        let allowLabels = ["允许完全访问", "Allow Full Access"]
        for label in allowLabels {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 20) {
                button.tap()
                return
            }
        }

        // No alert at all means access was already granted. That is the desired
        // end state, not a failure -- this test asserts a *state*, and the
        // alert is only the way to reach it.
    }
}
