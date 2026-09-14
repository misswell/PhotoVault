import XCTest

/// UI regression for the viewer's "哪来的回哪" dismissal (zoom transition).
///
/// These tests synthesize real iOS touches inside the simulator — the one
/// input channel that actually reaches the app, which macOS-side synthetic
/// mouse events cannot (they die against the desktop window wall). Each test
/// doubles as a scenario from the viewer transition acceptance list: the
/// grid must come back alive after every dismissal path, because a stuck
/// `isViewerTransitioning` is exactly the "退出后点什么都没反应" failure.
@MainActor
final class PhotoViewerDismissUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Launches the app, waits for the library grid, opens the first photo
    /// and waits for the viewer chrome. Returns the running app.
    private func launchAndOpenViewer() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()

        let firstCell = app.cells.firstMatch
        XCTAssertTrue(
            firstCell.waitForExistence(timeout: 20),
            "图库网格应加载出照片"
        )
        firstCell.tap()

        XCTAssertTrue(
            app.buttons["关闭"].waitForExistence(timeout: 10),
            "点按照片后查看器应打开"
        )
        return app
    }

    /// After a dismissal the grid must be alive again: the strongest proof
    /// is that tapping a cell opens the viewer once more.
    private func assertGridIsAlive(after app: XCUIApplication) {
        let firstCell = app.cells.firstMatch
        XCTAssertTrue(
            firstCell.waitForExistence(timeout: 10),
            "退出后网格应可见"
        )
        firstCell.tap()
        XCTAssertTrue(
            app.buttons["关闭"].waitForExistence(timeout: 10),
            "退出后网格必须仍可交互：再点照片应重新打开查看器"
        )
    }

    // MARK: - Scenarios

    /// 打开 A → 点关闭 → 退出；网格仍可交互（关闭按钮路径）。
    func testCloseButtonDismissesAndGridResponds() throws {
        let app = launchAndOpenViewer()
        app.buttons["关闭"].tap()
        XCTAssertFalse(
            app.buttons["关闭"].waitForExistence(timeout: 3),
            "关闭按钮应让查看器消失"
        )
        assertGridIsAlive(after: app)
    }

    /// 打开 → 下拉退出 → 网格仍可交互（系统交互式缩放退回）。
    func testPullDownDismissesAndGridResponds() throws {
        let app = launchAndOpenViewer()
        let window = app.windows.firstMatch
        let start = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)
        )
        let end = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)
        )
        start.press(forDuration: 0.08, thenDragTo: end)

        XCTAssertFalse(
            app.buttons["关闭"].waitForExistence(timeout: 3),
            "下拉提交后查看器应消失"
        )
        assertGridIsAlive(after: app)
    }

    /// 下拉很短没到提交阈值 → 查看器留在原地（连续取消），翻页仍可用。
    func testShortPullDownCancelsAndKeepsViewer() throws {
        let app = launchAndOpenViewer()
        let window = app.windows.firstMatch
        let start = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)
        )
        let end = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58)
        )
        start.press(forDuration: 0.08, thenDragTo: end)

        XCTAssertTrue(
            app.buttons["关闭"].waitForExistence(timeout: 3),
            "短下拉应取消退出，查看器留在原地"
        )
        // 取消后查看器必须完全可用：左右翻页仍走 pager。
        app.swipeLeft()
        let counter = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "2 /")
        ).firstMatch
        XCTAssertTrue(
            counter.waitForExistence(timeout: 5),
            "取消退出后应能继续翻页到第 2 张"
        )
    }

    /// 打开 A → 连续左滑翻页 → 关闭 → 网格仍可交互（索引已同步到当前照片）。
    func testPagingThenCloseKeepsGridAlive() throws {
        let app = launchAndOpenViewer()
        app.swipeLeft()
        app.swipeLeft()

        let counter = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "3 /")
        ).firstMatch
        XCTAssertTrue(
            counter.waitForExistence(timeout: 5),
            "两次左滑后应到第 3 张"
        )

        app.buttons["关闭"].tap()
        XCTAssertFalse(
            app.buttons["关闭"].waitForExistence(timeout: 3),
            "翻页后关闭应消失"
        )
        assertGridIsAlive(after: app)
    }

    /// 呈现稳定期（zoom 转场完全结束后）短暂停留，供外部 `simctl io screenshot`
    /// 抓取静止帧核对 letterbox 背景为黑色。
    func testViewerStableFramePause() throws {
        let app = launchAndOpenViewer()
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(app.buttons["关闭"].exists, "静止期查看器应保持在场")
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10))
    }

    /// 退出动画进行中点击另一张照片：下一步操作必须立即受理——旧 zoom-out
    /// 一结束，新查看器自动打开（不需要等用户再点一次）。
    func testTapDuringDismissalReopensViewer() throws {
        let app = launchAndOpenViewer()
        app.buttons["关闭"].tap()
        // 紧接着点下一张：无论事件落在动画中还是动画后，都必须被受理。
        let secondCell = app.cells.element(boundBy: 1)
        XCTAssertTrue(secondCell.waitForExistence(timeout: 5), "第二张照片应存在")
        secondCell.tap()
        XCTAssertTrue(
            app.buttons["关闭"].waitForExistence(timeout: 5),
            "退出后点击另一张照片应重新打开查看器"
        )
        app.buttons["关闭"].tap()
        XCTAssertFalse(app.buttons["关闭"].waitForExistence(timeout: 3))
        assertGridIsAlive(after: app)
    }

    /// 退出动画进行中滚动网格：触摸必须穿透转场容器到达网格。
    func testGridScrollsDuringDismissalAnimation() throws {
        let app = launchAndOpenViewer()
        app.buttons["关闭"].tap()
        app.swipeUp()
        XCTAssertFalse(
            app.buttons["关闭"].waitForExistence(timeout: 3),
            "查看器应完成退出"
        )
        XCTAssertTrue(
            app.cells.firstMatch.waitForExistence(timeout: 10),
            "动画中滚动后网格应存活"
        )
    }

    /// 未整理页（Indexed 查看器）：下拉退出后网格仍可交互。
    /// 两套查看器共用同一座 UIKit 呈现桥，各自都要回归。
    func testUnsortedViewerPullDownDismissalKeepsGridAlive() throws {
        let app = XCUIApplication()
        app.launch()

        let libraryCell = app.cells.firstMatch
        XCTAssertTrue(
            libraryCell.waitForExistence(timeout: 20),
            "图库网格应加载出照片"
        )

        // compact 布局下侧栏是收起的：先点左上角的侧栏按钮，再进未整理。
        let sidebarToggle = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(
            sidebarToggle.waitForExistence(timeout: 5),
            "应存在展开侧栏的按钮"
        )
        sidebarToggle.tap()

        let unsortedRow = app.staticTexts["未整理"].firstMatch
        let rowAppeared = unsortedRow.waitForExistence(timeout: 8)
        if !rowAppeared {
            let tree = app.debugDescription
            XCTFail(
                "侧栏应出现未整理入口（前 2500 字符树）：\n"
                    + String(tree.prefix(2500))
            )
        }
        unsortedRow.tap()

        let firstCell = app.cells.firstMatch
        let appeared = firstCell.waitForExistence(timeout: 20)
        if !appeared {
            // 失败时把整棵可访问性树写进结果，能看到未整理页实际渲染了什么。
            let tree = app.debugDescription
            XCTFail(
                "未整理网格应加载出照片（前 3000 字符树）：\n"
                    + String(tree.prefix(3000))
            )
        }
        firstCell.tap()
        XCTAssertTrue(
            app.buttons["关闭"].waitForExistence(timeout: 10),
            "未整理查看器应打开"
        )

        let window = app.windows.firstMatch
        let start = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)
        )
        let end = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)
        )
        start.press(forDuration: 0.08, thenDragTo: end)

        XCTAssertFalse(
            app.buttons["关闭"].waitForExistence(timeout: 3),
            "未整理查看器下拉后应消失"
        )
        assertGridIsAlive(after: app)
    }
}
