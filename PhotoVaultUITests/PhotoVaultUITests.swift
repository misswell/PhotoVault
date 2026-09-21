import XCTest

/// UI regression for the viewer's dismissal interaction.
///
/// The viewer's zoom-out is a system transition, and the failure this suite
/// guards against is that the *grid stays dead until the animation ends*: the
/// user taps 关闭, then cannot scroll or tap the next photo until the zoom-out
/// has finished. Every scenario below therefore drives the second interaction
/// as soon as the first one is issued, and asserts what the user actually got
/// — a specific photo opened, a content offset that really moved — instead of
/// "some cell still exists", which passes even when nothing responded.
///
/// These tests synthesize real iOS touches inside the simulator; macOS-side
/// synthetic mouse events die against the desktop window wall.
@MainActor
final class PhotoViewerDismissUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Launch and viewer helpers

    /// Launches the app and waits for the library grid. On compact width the
    /// sidebar can start expanded, in which case the grid is one tap away.
    @discardableResult
    private func launchToGrid(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launch()

        let grid = app.collectionViews["photo-grid"]
        if grid.waitForExistence(timeout: 15) { return app }

        let libraryRow = app.staticTexts["图库"].firstMatch
        if libraryRow.waitForExistence(timeout: 5) { libraryRow.tap() }
        XCTAssertTrue(grid.waitForExistence(timeout: 20), "图库网格应加载出照片")
        return app
    }

    private func openViewer(at index: Int, in app: XCUIApplication) {
        let cell = app.cells["photo-cell-\(index)"]
        XCTAssertTrue(cell.waitForExistence(timeout: 20), "第 \(index) 个 cell 应存在")
        cell.tap()
        XCTAssertTrue(
            app.buttons["viewer-close"].waitForExistence(timeout: 10),
            "点按 cell \(index) 后查看器应打开"
        )
    }

    /// The viewer's "current / total" label, e.g. `3 / 1284` → `3`.
    private func viewerIndex(in app: XCUIApplication) -> Int? {
        let counter = app.staticTexts["viewer-counter"]
        guard counter.exists else { return nil }
        return Int(
            counter.label
                .split(separator: "/")
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
        )
    }

    /// Waits for the viewer to settle on `expected`.
    ///
    /// Polled rather than `waitForExistence`, because the outgoing viewer's
    /// counter is still on screen while it animates out — a plain existence
    /// check would read the *old* index and pass for the wrong reason.
    private func expectViewerIndex(
        _ expected: Int,
        in app: XCUIApplication,
        timeout: TimeInterval = 15,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if viewerIndex(in: app) == expected { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail(
            "查看器应停在索引 \(expected)，实际 = "
                + "\(viewerIndex(in: app).map(String.init) ?? "<无>")"
                + (message.isEmpty ? "" : "（\(message)）"),
            file: file,
            line: line
        )
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
            app.buttons["viewer-close"].waitForExistence(timeout: 10),
            "退出后网格必须仍可交互：再点照片应重新打开查看器"
        )
    }

    // MARK: - Dismissal scenarios

    /// 打开 A → 点关闭 → 退出；网格仍可交互（关闭按钮路径）。
    func testCloseButtonDismissesAndGridResponds() throws {
        let app = launchToGrid()
        openViewer(at: 0, in: app)
        app.buttons["viewer-close"].tap()
        XCTAssertFalse(
            app.buttons["viewer-close"].waitForExistence(timeout: 3),
            "关闭按钮应让查看器消失"
        )
        assertGridIsAlive(after: app)
    }

    /// 打开 → 下拉退出 → 网格仍可交互（系统交互式缩放退回）。
    func testPullDownDismissesAndGridResponds() throws {
        let app = launchToGrid()
        openViewer(at: 0, in: app)
        let window = app.windows.firstMatch
        let start = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)
        )
        let end = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)
        )
        start.press(forDuration: 0.08, thenDragTo: end)

        XCTAssertFalse(
            app.buttons["viewer-close"].waitForExistence(timeout: 3),
            "下拉提交后查看器应消失"
        )
        assertGridIsAlive(after: app)
    }

    func testOpenAndDismissTransitionsAcceptReplacementRequest() throws {
        let app = launchToGrid(arguments: ["-viewer-interruption-probe"])
        let cell = app.cells["photo-cell-0"]
        XCTAssertTrue(cell.waitForExistence(timeout: 20))
        cell.tap()
        expectViewerIndex(3, in: app, "动画中的第二次请求必须打开第 3 张")
        app.swipeLeft()
        expectViewerIndex(4, in: app, "旧会话完成回调不得关闭或阻塞新查看器")
        app.buttons["viewer-close"].tap()
        assertGridIsAlive(after: app)
    }

    /// Predominantly downward motion must not become a page turn because of
    /// a small horizontal component. Exercise both directions from mid-library.
    func testDiagonalDownwardDragsDismissInsteadOfPaging() throws {
        let app = launchToGrid()
        for dx in [-0.18, 0.18] {
            openViewer(at: 2, in: app)
            let window = app.windows.firstMatch
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + dx, dy: 0.88))
            start.press(forDuration: 0.05, thenDragTo: end)
            XCTAssertTrue(app.buttons["viewer-close"].waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.cells["photo-cell-2"].isHittable)
        }
    }

    func testMostlyHorizontalDiagonalDragStillPages() throws {
        let app = launchToGrid()
        openViewer(at: 0, in: app)
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.4))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.47))
        start.press(forDuration: 0.05, thenDragTo: end)
        expectViewerIndex(2, in: app)
        XCTAssertTrue(app.buttons["viewer-close"].exists)
    }

    func testZoomedPhotoPanDoesNotDismiss() throws {
        let app = launchToGrid()
        openViewer(at: 0, in: app)
        app.pinch(withScale: 2, velocity: 1)
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: end)
        expectViewerIndex(1, in: app, "放大后的下滑应平移照片，不应退出或翻页")
        XCTAssertTrue(app.buttons["viewer-close"].exists)
        app.buttons["viewer-close"].tap()
        assertGridIsAlive(after: app)
    }

    /// 下拉很短没到提交阈值 → 查看器留在原地，翻页仍可用。
    func testShortPullDownCancelsAndKeepsViewer() throws {
        let app = launchToGrid()
        openViewer(at: 0, in: app)
        let window = app.windows.firstMatch
        let start = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)
        )
        let end = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58)
        )
        start.press(forDuration: 0.08, thenDragTo: end)

        XCTAssertTrue(
            app.buttons["viewer-close"].waitForExistence(timeout: 3),
            "短下拉应取消退出，查看器留在原地"
        )
        // 取消后查看器必须完全可用：左右翻页仍走 pager。
        app.swipeLeft()
        expectViewerIndex(2, in: app, "取消退出后应能继续翻页到第 2 张")
    }

    /// 短下拉取消之后**马上**再来一次长下拉：必须仍能退出。
    ///
    /// 回归的是"UIKit 刚决定取消就被当成 transition 已结束"。那一瞬间系统还在
    /// 跑回弹动画，状态机却已经回到 idle，于是第二次下拉被 downward intent
    /// recognizer 占住、系统 Zoom dismissal 又起不来——整笔触摸两边都不认，
    /// 既不退出也不翻页。
    ///
    /// 启动参数让 App 内探针在这次真实的取消回弹上核对闸门：回弹期间必须关、
    /// 结束后必须开，违反即 DEBUG `assert` 崩溃（表现为本用例失败）。两次下拉
    /// 之间不 sleep，就是为了落在回弹还没结束的那段窗口里。
    func testSecondPullDownImmediatelyAfterCancelledDismissStillWorks() throws {
        let app = launchToGrid(arguments: ["-viewer-cancel-reentry-probe"])
        openViewer(at: 0, in: app)
        let window = app.windows.firstMatch

        // 短下拉：远不到提交阈值，UIKit 会决定回弹。
        pullDown(in: window, from: 0.45, to: 0.50, holdFor: 0.05)
        XCTAssertTrue(
            app.buttons["viewer-close"].exists,
            "第一次短下拉应留在查看器里（探针日志 stage=cancelling 是它的凭据）"
        )

        // 不等回弹播完，直接再拉：这一段就是原来会被吞掉的触摸。
        pullDown(in: window, from: 0.30, to: 0.92, holdFor: 0.08)
        XCTAssertTrue(
            app.buttons["viewer-close"].waitForNonExistence(timeout: 5),
            "取消回弹期间发起的第二次下拉必须仍能退出查看器"
        )
        assertGridIsAlive(after: app)
    }

    /// 场景 C：连续 5 次短下拉，每一次都要能回弹（查看器仍在场），最后一次
    /// 拉过阈值必须正常退出。中途任何一次"完全没反应"都会让收尾的长下拉失败。
    func testRepeatedShortPullDownsKeepBouncingBack() throws {
        let app = launchToGrid(arguments: ["-viewer-cancel-reentry-probe"])
        openViewer(at: 0, in: app)
        guard let openedAt = viewerIndex(in: app) else {
            XCTFail("详情页应显示当前第几张")
            return
        }
        let window = app.windows.firstMatch

        for round in 1...5 {
            pullDown(in: window, from: 0.45, to: 0.50, holdFor: 0.05)
            XCTAssertTrue(
                app.buttons["viewer-close"].exists,
                "第 \(round) 次短下拉应留在查看器里"
            )
        }
        // 等回弹结束再核对：仍停在同一张，说明五次都是真回弹而不是攒出来的退出。
        Thread.sleep(forTimeInterval: 1.5)
        expectViewerIndex(openedAt, in: app, "连续短下拉后查看器应停在原处")

        pullDown(in: window, from: 0.30, to: 0.92, holdFor: 0.05)
        XCTAssertTrue(
            app.buttons["viewer-close"].waitForNonExistence(timeout: 5),
            "连续短下拉之后拉长下拉仍应退出"
        )
        assertGridIsAlive(after: app)
    }

    /// 场景 E：取消退出后马上右滑，仍要正常翻回上一张。
    ///
    /// 左滑那一条由 `testShortPullDownCancelsAndKeepsViewer` 覆盖；右滑单独
    /// 测是因为取消回弹期间被错误占住的正是分页 pan 的触摸方向。
    func testSwipeRightAfterCancelledPullDownStillPages() throws {
        let app = launchToGrid(arguments: ["-viewer-cancel-reentry-probe"])
        openViewer(at: 1, in: app)
        guard let openedAt = viewerIndex(in: app) else {
            XCTFail("详情页应显示当前第几张")
            return
        }
        app.swipeLeft()
        expectViewerIndex(openedAt + 1, in: app, "左滑应到下一张")

        let window = app.windows.firstMatch
        pullDown(in: window, from: 0.45, to: 0.50, holdFor: 0.05)
        // 等这一次回弹真正结束再翻页：这里要证的是"回弹结束后一切恢复"，
        // 回弹过程中的那一次触摸由上一条用例负责。
        Thread.sleep(forTimeInterval: 1.5)
        expectViewerIndex(
            openedAt + 1,
            in: app,
            "短下拉应取消退出并停在原处"
        )

        app.swipeRight()
        expectViewerIndex(
            openedAt,
            in: app,
            "取消退出后的右滑必须翻回上一张，而不是被回弹中的转场吃掉"
        )
        XCTAssertTrue(app.buttons["viewer-close"].exists)
    }

    /// Drags straight down from `fromY` to `toY` (normalized screen heights).
    ///
    /// ⚠️ 提交阈值按照片的**实际显示高度**算，不是按屏幕：同一笔 13% 屏幕高度
    /// 的下拉，在竖屏截图上是回弹，在横屏照片上（letterbox 后更矮）就是退出。
    /// 这里要"只回弹"的下拉一律压在 5% 屏幕高度以内。
    private func pullDown(
        in window: XCUIElement,
        from fromY: CGFloat,
        to toY: CGFloat,
        holdFor: TimeInterval
    ) {
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fromY))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: toY))
        start.press(forDuration: holdFor, thenDragTo: end)
    }

    /// 打开 A → 连续左滑翻页 → 关闭 → 网格仍可交互（索引已同步到当前照片）。
    func testPagingThenCloseKeepsGridAlive() throws {
        let app = launchToGrid()
        openViewer(at: 0, in: app)
        app.swipeLeft()
        app.swipeLeft()
        expectViewerIndex(3, in: app, "两次左滑后应到第 3 张")

        app.buttons["viewer-close"].tap()
        XCTAssertFalse(
            app.buttons["viewer-close"].waitForExistence(timeout: 3),
            "翻页后关闭应消失"
        )
        assertGridIsAlive(after: app)
    }

    /// 场景 2：退出之后立刻点另一张照片。
    ///
    /// B 的坐标在查看器打开**之前**取好，关闭后不再做任何查询就直接落到该
    /// 坐标上。断言的是**打开的那张就是被点的那张**（"3 / N"），而不是
    /// "又有查看器出现了"——后者在"点击丢失、只是重新打开了原来那张"时也
    /// 会通过。
    ///
    /// ⚠️ 同 `testGridIsFullyHittableAfterDismissal`：XCUITest 会把事件排在
    /// 动画结束之后，所以这一条证明的是"退出后单击必达且目标正确"，而不是
    /// "动画进行中的那一击"。后者的证据在 App 内探针日志里。
    func testTapAfterDismissalOpensTheTappedPhoto() throws {
        let app = launchToGrid()

        let targetCell = app.cells["photo-cell-2"]
        XCTAssertTrue(targetCell.waitForExistence(timeout: 20), "第 3 张应在屏幕上")
        let targetCoordinate = targetCell.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )

        openViewer(at: 0, in: app)
        expectViewerIndex(1, in: app, "应先打开第 1 张")

        app.buttons["viewer-close"].tap()
        waitForViewerToReleaseTouches(in: app)
        targetCoordinate.tap()

        expectViewerIndex(
            3,
            in: app,
            "退出动画期间点击的照片必须被打开，且只需点一次"
        )
    }

    /// 场景 3：退出之后网格必须立刻能接住触摸，且不得留下任何透明遮罩。
    ///
    /// ⚠️ 这里**不能**用 `swipeUp()` 或"动画中再点一下"来证明"动画期间"：
    /// XCUITest 在合成手势、以及 `tap()` 返回之前都会等 App 回到 idle，实测
    /// 上滑要等退出动画结束 407ms 之后才落到网格，`关闭.tap()` 返回时动画也
    /// 早已播完。**"动画进行中能不能操作"在 UI 测试进程里无法观测**，它由
    /// App 内探针负责（`dismiss_probe_mid_transition`：在转场动画块里用真实
    /// `window.hitTest` 回答"这一下会不会打到网格"，见
    /// `PhotoViewerPresentationBridge`）。
    ///
    /// UI 测试守住的是另一半：退出后整个视口都可命中。
    func testGridIsFullyHittableAfterDismissal() throws {
        let app = launchToGrid()

        XCTAssertTrue(
            app.cells["photo-cell-0"].waitForExistence(timeout: 20),
            "第一张应可见"
        )
        openViewer(at: 0, in: app)
        app.buttons["viewer-close"].tap()

        // 跨整屏取样：残留的透明遮罩往往只盖住一部分，只查 firstMatch 会漏。
        for index in [0, 5, 15] {
            let cell = app.cells["photo-cell-\(index)"]
            XCTAssertTrue(
                cell.waitForExistence(timeout: 10),
                "退出后 cell \(index) 应仍在视口内"
            )
            XCTAssertTrue(
                cell.isHittable,
                "退出后 cell \(index) 必须可命中 —— 不得残留拦截触摸的遮罩，"
                    + "也不得等 zoom-out 结束才恢复"
            )
        }
    }

    /// Waits until the viewer stops taking touches, or disappears.
    ///
    /// NOTE: in practice `关闭.tap()` has already waited out the zoom-out by
    /// the time it returns (XCUITest serializes on app idle), so this usually
    /// falls through on the first probe. It is kept because it makes the
    /// intent explicit and stays correct if that harness behaviour changes.
    private func waitForViewerToReleaseTouches(
        in app: XCUIApplication,
        timeout: TimeInterval = 3
    ) {
        let close = app.buttons["viewer-close"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !close.exists || !close.isHittable { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// 场景 5：连续快速 打开 → 关闭 → 点下一张，十轮。验证
    /// pending request 不丢、不重复呈现、不卡死、索引始终正确。
    func testRapidCloseAndReopenCyclesStayConsistent() throws {
        let app = launchToGrid()

        for round in 0..<10 {
            let index = round % 4
            // 上一轮关闭的动画可能还在跑，这里的 tap 正好落在动画中间 ——
            // 正是要压的那条路径。
            openViewer(at: index, in: app)
            expectViewerIndex(
                index + 1,
                in: app,
                "第 \(round + 1) 轮应打开第 \(index + 1) 张"
            )
            app.buttons["viewer-close"].tap()
        }

        // 收尾：网格仍能正常开查看器，说明没有卡在 transitioning。
        XCTAssertTrue(app.cells["photo-cell-0"].waitForExistence(timeout: 10))
        openViewer(at: 0, in: app)
        expectViewerIndex(1, in: app, "十轮之后网格仍应可交互")
    }

    /// 呈现稳定期（zoom 转场完全结束后）短暂停留，供外部 `simctl io screenshot`
    /// 抓取静止帧核对 letterbox 背景为黑色。
    func testViewerStableFramePause() throws {
        let app = launchToGrid()
        openViewer(at: 0, in: app)
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(app.buttons["viewer-close"].exists, "静止期查看器应保持在场")
        app.buttons["viewer-close"].tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10))
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
            app.buttons["viewer-close"].waitForExistence(timeout: 10),
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
            app.buttons["viewer-close"].waitForExistence(timeout: 3),
            "未整理查看器下拉后应消失"
        )
        assertGridIsAlive(after: app)
    }
}


/// Slideshow launch options: the sheet is the single place a slideshow is set
/// up, and it can be opened from the grid toolbar ("play everything in view")
/// or from the detail page ("start here, on this photo").
///
/// The interval is pinned through the UserDefaults argument domain so the
/// assertions do not race autoplay: reading "3 / 33" a second later would
/// otherwise be "4 / 33".
@MainActor
final class SlideshowOptionsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchToGrid(interval: String = "12") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-PhotoVault.slideshow.interval", interval,
            "-PhotoVault.slideshow.fillsScreen", "NO",
            "-PhotoVault.slideshow.shuffles", "NO",
            // The launch sheet persists what the user last chose, and the
            // argument domain outranks it. Without this the content filter
            // leaks in from whatever a previous run selected — and a filtered
            // playlist legitimately starts on a *different* position, which
            // would make this class order-dependent. Only safe where the test
            // does not itself change the filter: the argument domain is
            // read-only, so a picker write there is silently ignored.
            "-PhotoVault.slideshow.contentFilter", "all",
            "-PhotoVault.slideshow.skipsScreenshots", "NO",
            "-PhotoVault.slideshow.onlyFavorites", "NO",
            "-PhotoVault.slideshow.photosOnly", "NO",
        ]
        app.launch()

        let grid = app.collectionViews["photo-grid"]
        if grid.waitForExistence(timeout: 15) { return app }

        let libraryRow = app.staticTexts["图库"].firstMatch
        if libraryRow.waitForExistence(timeout: 5) { libraryRow.tap() }
        XCTAssertTrue(grid.waitForExistence(timeout: 20), "图库网格应加载出照片")
        return app
    }

    /// Waits until an element is both present and hittable.
    ///
    /// The grid toolbar is rebuilt whenever the launch window or the album scan
    /// publishes, and XCUITest resolves an element *before* it taps it: a tap
    /// aimed at "播放" can land on its neighbour "选择" instead. Waiting for
    /// hittable (rather than merely existing) removes most of that window.
    private func waitUntilHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = 10
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Opens the slideshow sheet from the grid toolbar, retrying the tap.
    private func openSlideshowOptions(fromGrid app: XCUIApplication) {
        let play = app.buttons["播放"]
        XCTAssertTrue(play.waitForExistence(timeout: 20), "图库页应有播放按钮")

        for attempt in 1...3 {
            XCTAssertTrue(waitUntilHittable(play), "播放按钮应可点击")
            play.tap()
            if app.buttons["slideshow-start"].waitForExistence(timeout: 6) { return }

            if app.buttons["完成"].waitForExistence(timeout: 0.5) {
                // The tap landed on 选择: leave selection mode and try again.
                app.buttons["完成"].tap()
            }
            if attempt == 3 {
                XCTFail("点播放后应弹出幻灯片设置面板")
            }
        }
    }

    /// Opens 未整理 (the SQLite-index paged grid) and taps into its viewer.
    ///
    /// In compact width the sidebar starts collapsed, so the unsorted list is
    /// behind the leading navigation-bar button.
    private func openUnsortedViewer(
        interval: String = "12",
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-PhotoVault.slideshow.interval", interval,
            "-PhotoVault.slideshow.fillsScreen", "NO",
            "-PhotoVault.slideshow.shuffles", "NO",
        ] + extraArguments
        app.launch()

        XCTAssertTrue(
            app.cells.firstMatch.waitForExistence(timeout: 20),
            "图库网格应加载出照片"
        )

        let sidebarToggle = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 5), "应有侧栏按钮")
        sidebarToggle.tap()

        let unsortedRow = app.staticTexts["未整理"].firstMatch
        XCTAssertTrue(unsortedRow.waitForExistence(timeout: 8), "侧栏应有未整理入口")
        unsortedRow.tap()

        let firstCell = app.cells.firstMatch
        XCTAssertTrue(firstCell.waitForExistence(timeout: 20), "未整理网格应加载出照片")
        firstCell.tap()
        XCTAssertTrue(
            app.buttons["viewer-close"].waitForExistence(timeout: 10),
            "未整理查看器应打开"
        )
        return app
    }

    /// The viewer's "current / total" label, e.g. `3 / 33` -> 3.
    ///
    /// Same snapshot rule as the slideshow counter: settle the app before
    /// resolving `.label`.
    private func viewerIndex(in app: XCUIApplication) -> Int? {
        let counter = app.staticTexts["viewer-counter"]
        guard counter.waitForExistence(timeout: 10) else { return nil }
        return Int(
            counter.label
                .split(separator: "/")
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
        )
    }

    /// The slideshow's "current / total" label, e.g. `3 / 33` -> 3.
    ///
    /// Same snapshot rule as the viewer counter: settle the app before
    /// resolving `.label`, otherwise XCTest fails the test instead of
    /// returning a value.
    private func slideshowIndex(in app: XCUIApplication) -> Int? {
        let counter = app.staticTexts["slideshow-counter"]
        guard counter.waitForExistence(timeout: 10) else { return nil }
        return Int(
            counter.label
                .split(separator: "/")
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
        )
    }

    func testLibraryPlaybackSheetStartsSlideshow() {
        let app = launchToGrid()

        openSlideshowOptions(fromGrid: app)
        // The options the user asked for must be on the sheet, named for what
        // they keep rather than what they drop.
        XCTAssertTrue(app.staticTexts["图库幻灯片"].exists, "面板标题应是图库幻灯片")
        XCTAssertTrue(app.staticTexts["播放内容"].exists, "面板应有播放内容分组")
        XCTAssertTrue(app.switches["排除截屏"].exists, "面板应有排除截屏开关")
        XCTAssertTrue(app.switches["填充满画面"].exists, "面板应有填充满画面开关")

        // The status line is the sheet's own proof that it resolved the real
        // sequence (and not an empty fallback) before offering to start.
        let status = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "将播放"))
            .firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), "面板应统计出将播放的张数")

        app.buttons["slideshow-start"].tap()

        XCTAssertEqual(
            slideshowIndex(in: app),
            1,
            "从图库播放应从第一张开始"
        )

        app.buttons["slideshow-close"].tap()
        XCTAssertTrue(
            app.collectionViews["photo-grid"].waitForExistence(timeout: 10),
            "关闭幻灯片后应回到图库网格"
        )
    }

    /// 幻灯片必须自己往下走：没人碰屏幕，计数器也要从第 1 张走到第 2 张。
    ///
    /// 这条此前没被覆盖过：其它用例只断言从哪张开始播，间隔被钉成 12 秒，
    /// 自动推进坏掉是看不出来的（实测就是坏掉的状态被用户先发现）。
    func testSlideshowAdvancesOnItsOwn() {
        let app = launchToGrid(interval: "3")
        openSlideshowOptions(fromGrid: app)
        app.buttons["slideshow-start"].tap()

        let counter = app.staticTexts["slideshow-counter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 15), "幻灯片应开始播放")
        let first = counter.label
        XCTAssertTrue(first.hasPrefix("1 /"), "应从第 1 张开始，实际 \(first)")

        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", first),
            object: counter
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [moved], timeout: 20),
            .completed,
            "间隔 3 秒，20 秒内幻灯片应自动切到下一张（一直停在 \(first)）"
        )
    }

    /// 同一条自动推进，但从详情页的 `viewer-slideshow` 起播（用户实际用的入口）。
    func testSlideshowFromDetailAdvancesOnItsOwn() {
        let app = launchToGrid(interval: "3")
        let firstCell = app.collectionViews["photo-grid"].cells.firstMatch
        XCTAssertTrue(firstCell.waitForExistence(timeout: 20))
        firstCell.tap()

        let slideshowButton = app.buttons["viewer-slideshow"]
        XCTAssertTrue(waitUntilHittable(slideshowButton, timeout: 15), "详情页应有播放幻灯片按钮")
        slideshowButton.tap()

        let start = app.buttons["slideshow-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "详情页也应弹出设置面板")
        start.tap()

        let counter = app.staticTexts["slideshow-counter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 15), "幻灯片应开始播放")
        let first = counter.label

        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", first),
            object: counter
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [moved], timeout: 20),
            .completed,
            "详情页起播的幻灯片也应自动切换（一直停在 \(first)）"
        )
    }

    /// 未整理详情页起播的幻灯片也要自己往下走：它和普通详情页同源——两者都在
    /// UIKit 承载的查看器里，`\.scenePhase` 在那里恒为 `.background`。
    func testUnsortedSlideshowAdvancesOnItsOwn() {
        let app = openUnsortedViewer(
            interval: "3",
            extraArguments: ["-PhotoVault.slideshow.contentFilter", "all"]
        )
        let slideshowButton = app.buttons["viewer-slideshow"]
        XCTAssertTrue(waitUntilHittable(slideshowButton, timeout: 15), "未整理详情页应有播放按钮")
        slideshowButton.tap()

        let start = app.buttons["slideshow-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "应弹出设置面板")
        start.tap()

        let counter = app.staticTexts["slideshow-counter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 15), "未整理幻灯片应开始播放")
        let first = counter.label

        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", first),
            object: counter
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [moved], timeout: 20),
            .completed,
            "未整理幻灯片也应自动切换（一直停在 \(first)）"
        )
    }

    func testDetailSlideshowStartsFromTheCurrentPhoto() {
        let app = launchToGrid()

        let cell = app.cells["photo-cell-2"]
        XCTAssertTrue(cell.waitForExistence(timeout: 20), "第 2 个 cell 应存在")
        cell.tap()
        XCTAssertTrue(
            app.buttons["viewer-close"].waitForExistence(timeout: 10),
            "点按 cell 后详情页应打开"
        )

        // Which cell the tap actually landed on is not the point of this test;
        // that the slideshow starts on the photo the viewer is showing is. Read
        // the viewer's own index instead of assuming the tap hit cell 2.
        guard let openedAt = viewerIndex(in: app) else {
            XCTFail("详情页应显示当前第几张")
            return
        }

        let slideshowButton = app.buttons["viewer-slideshow"]
        XCTAssertTrue(
            waitUntilHittable(slideshowButton, timeout: 5),
            "详情页底部操作栏应有播放幻灯片按钮"
        )
        slideshowButton.tap()

        XCTAssertTrue(
            app.buttons["slideshow-start"].waitForExistence(timeout: 5),
            "详情页点播放幻灯片后应弹出设置面板"
        )
        app.buttons["slideshow-start"].tap()

        XCTAssertEqual(
            slideshowIndex(in: app),
            openedAt,
            "从详情页播放幻灯片应从当前这张（第 \(openedAt) 张）开始"
        )

        app.buttons["slideshow-close"].tap()
        XCTAssertTrue(
            app.buttons["viewer-close"].waitForExistence(timeout: 10),
            "关闭幻灯片后应回到详情页"
        )
    }

    /// 未整理详情页：筛选走 SQLite 索引，播放顺序是过滤后的顺序。
    func testUnsortedDetailSlideshowHonoursContentFilter() {
        let app = openUnsortedViewer()

        let slideshowButton = app.buttons["viewer-slideshow"]
        XCTAssertTrue(
            waitUntilHittable(slideshowButton, timeout: 5),
            "未整理详情页应有播放幻灯片按钮"
        )
        slideshowButton.tap()

        XCTAssertTrue(
            app.buttons["slideshow-start"].waitForExistence(timeout: 8),
            "未整理详情页点播放后应弹出设置面板"
        )
        // Reset to the first option first: the sheet persists the last choice,
        // and tapping the already-selected row would not prove the picker (or
        // the SQL recount behind it) actually responds.
        let allPhotos = app.buttons["全部照片"]
        XCTAssertTrue(allPhotos.waitForExistence(timeout: 5), "面板应有全部照片选项")
        allPhotos.tap()

        let landscape = app.buttons["横屏照片"]
        XCTAssertTrue(landscape.waitForExistence(timeout: 5), "面板应有横屏照片选项")
        landscape.tap()

        let status = app.staticTexts
            .matching(NSPredicate(
                format: "label BEGINSWITH %@ AND label CONTAINS %@",
                "将播放",
                "横屏照片"
            ))
            .firstMatch
        if !status.waitForExistence(timeout: 15) {
            XCTFail(
                "面板应显示横屏筛选后的张数（此时统计来自索引）；"
                    + "texts=\(app.staticTexts.allElementsBoundByIndex.map { $0.label })"
            )
        }

        app.buttons["slideshow-start"].tap()
        XCTAssertEqual(
            slideshowIndex(in: app),
            1,
            "从网格播放应从筛选后的第一张开始"
        )

        app.buttons["slideshow-close"].tap()
        XCTAssertTrue(
            app.buttons["viewer-close"].waitForExistence(timeout: 10),
            "关闭幻灯片后应回到未整理详情页"
        )
    }
}
