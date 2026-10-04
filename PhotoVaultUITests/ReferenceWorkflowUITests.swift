import XCTest

@MainActor
final class ReferenceWorkflowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-PhotoVault.startup.destination", "library"] + arguments
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["允许完全访问", "Allow Full Access"] {
            let button = springboard.buttons[title]
            if button.waitForExistence(timeout: 2) { button.tap(); app.terminate(); app.launch(); break }
        }
        return app
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func openViewer(_ app: XCUIApplication, photosOnly: Bool = true) {
        let grid = app.collectionViews["photo-grid"]
        if !grid.waitForExistence(timeout: 15) {
            let library = app.staticTexts["图库"].firstMatch
            if library.exists { library.tap() }
        }
        XCTAssertTrue(grid.waitForExistence(timeout: 15))
        if photosOnly {
            let filter = app.buttons["筛选与排序"]
            if filter.exists { filter.tap(); app.buttons["照片"].firstMatch.tap() }
        }
        let cell = grid.cells.matching(identifier: "photo-cell-0").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10)); cell.tap()
        XCTAssertTrue(app.buttons["viewer-edit"].waitForExistence(timeout: 10))
    }

    func testImageProcessingGeometryFormatsAndMetadata() {
        let app = launch(["--pv-edit-probe"])
        let result = app.staticTexts["photo-edit-probe-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        let success = NSPredicate(format: "label CONTAINS 'failures=0'")
        expectation(for: success, evaluatedWith: result)
        waitForExpectations(timeout: 60)
    }

    func testEditorCropUndoCompressionSaveAndHistory() {
        let app = launch(["-PhotoVault.library.browseMode", "expanded"])
        openViewer(app)
        app.buttons["viewer-edit"].tap()
        let rotate = app.buttons["右旋 90°"].firstMatch
        XCTAssertTrue(rotate.waitForExistence(timeout: 15)); rotate.tap()
        capture("editor-crop", app: app)
        let undo = app.buttons["撤销"].firstMatch
        XCTAssertTrue(undo.isEnabled); undo.tap()
        app.buttons["editor-export"].tap()
        let save = app.buttons["compression-save-copy"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 30)
        capture("compression-settings", app: app); save.tap()
        XCTAssertTrue(app.staticTexts["compression-saved"].waitForExistence(timeout: 30))
        app.buttons["查看对比"].tap()
        XCTAssertTrue(app.navigationBars["查看对比"].waitForExistence(timeout: 10))
        app.buttons["compression-history-record"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["压缩前后对比"].waitForExistence(timeout: 10))
        capture("compression-comparison", app: app)
    }

    func testOverwriteAndRestoreOriginal() {
        let app = launch(["-PhotoVault.library.browseMode", "expanded"])
        openViewer(app); app.buttons["viewer-edit"].tap()
        let rotate = app.buttons["右旋 90°"].firstMatch
        XCTAssertTrue(rotate.waitForExistence(timeout: 15)); rotate.tap()
        app.buttons["editor-export"].tap()
        let replace = app.buttons["compression-replace"]
        XCTAssertTrue(replace.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: replace)
        waitForExpectations(timeout: 30); replace.tap()
        XCTAssertTrue(app.staticTexts["compression-saved"].waitForExistence(timeout: 30))
        app.buttons["查看对比"].tap()
        let record = app.buttons["compression-history-record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        let recordID = record.value as? String
        record.tap()
        let revert = app.buttons["compression-revert"]
        XCTAssertTrue(revert.waitForExistence(timeout: 10)); capture("reversible-edit", app: app); revert.tap()
        XCTAssertTrue(revert.waitForNonExistence(timeout: 20))
        if let recordID {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'compression-history-record' AND value == %@", recordID)).firstMatch.waitForNonExistence(timeout: 10), "还原后的旧压缩记录应被移除")
        }
    }

    func testVideoCompressionSavesAndCanComparePlayback() {
        let app = launch(["-PhotoVault.library.browseMode", "expanded"])
        XCTAssertTrue(app.buttons["筛选与排序"].waitForExistence(timeout: 15))
        app.buttons["筛选与排序"].tap(); app.buttons["视频"].firstMatch.tap()
        openViewer(app, photosOnly: false); app.buttons["viewer-edit"].tap()
        let save = app.buttons["video-compression-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 15)); save.tap()
        XCTAssertTrue(app.staticTexts["video-compression-saved"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '640 × 480'")).firstMatch.waitForExistence(timeout: 10), "测试视频应保持原尺寸，不得放大")
        app.swipeUp()
        app.buttons["查看对比"].tap()
        let record = app.buttons["compression-history-record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 10)); record.tap()
        XCTAssertTrue(app.navigationBars["压缩前后对比"].waitForExistence(timeout: 10))
        capture("video-comparison", app: app)
    }

    func testTimelineModesAndReturnToGrid() {
        let app = launch()
        let modes = app.segmentedControls["library-browse-modes"]
        if !modes.waitForExistence(timeout: 15) { app.staticTexts["图库"].firstMatch.tap() }
        XCTAssertTrue(modes.waitForExistence(timeout: 15))
        for title in ["年", "月", "日", "日记"] {
            modes.buttons[title].tap()
            XCTAssertTrue(app.scrollViews["library-timeline"].waitForExistence(timeout: 10))
            if title == "月" { capture("monthly-calendar", app: app) }
        }
        modes.buttons["展开"].tap()
        XCTAssertTrue(app.collectionViews["photo-grid"].waitForExistence(timeout: 10))
    }

    func testCompactAndExpandedImmediatelyChangeCellSize() {
        let app = launch()
        let modes = app.segmentedControls["library-browse-modes"]
        XCTAssertTrue(modes.waitForExistence(timeout: 15))
        modes.buttons["紧凑"].tap()
        let cell = app.collectionViews["photo-grid"].cells["photo-cell-0"]
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        let compactWidth = cell.frame.width
        modes.buttons["展开"].tap()
        expectation(for: NSPredicate { _, _ in cell.frame.width > compactWidth * 1.5 }, evaluatedWith: cell)
        waitForExpectations(timeout: 10)
        let expandedWidth = cell.frame.width
        modes.buttons["紧凑"].tap()
        expectation(for: NSPredicate { _, _ in cell.frame.width < expandedWidth / 1.5 }, evaluatedWith: cell)
        waitForExpectations(timeout: 10)
    }

    func testVideoTimelineDrilldownPreservesFilter() {
        let app = launch()
        XCTAssertTrue(app.buttons["筛选与排序"].waitForExistence(timeout: 15))
        app.buttons["筛选与排序"].tap(); app.buttons["视频"].firstMatch.tap()
        let modes = app.segmentedControls["library-browse-modes"]
        modes.buttons["月"].tap()
        let period = app.buttons["timeline-period"].firstMatch
        XCTAssertTrue(period.waitForExistence(timeout: 15)); period.tap()
        let grid = app.collectionViews["photo-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(grid.cells.count, 0)
        XCTAssertEqual(grid.cells.matching(NSPredicate(format: "label == '照片'")).count, 0, "视频月份不能混入照片")
    }

    func testViewerDeleteCancellationAndConfirmedDeletion() {
        let app = launch(["-PhotoVault.library.browseMode", "expanded"])
        openViewer(app)
        func prompt() -> XCUIElement {
            app.buttons["更多照片操作"].tap()
            app.buttons["从照片库删除"].firstMatch.tap()
            let local = app.sheets.firstMatch
            if local.waitForExistence(timeout: 5) { return local }
            let system = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
            XCTAssertTrue(system.waitForExistence(timeout: 10)); return system
        }
        let cancelled = prompt()
        let cancel = cancelled.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel", "Don’t Allow", "Don't Allow", "不允许"])).firstMatch
        XCTAssertTrue(cancel.exists); cancel.tap()
        XCTAssertTrue(app.buttons["viewer-edit"].exists, "取消删除应保留查看器")
        let confirmed = prompt()
        let delete = confirmed.buttons.matching(NSPredicate(format: "label CONTAINS '删除' OR label CONTAINS 'Delete'")).firstMatch
        XCTAssertTrue(delete.exists); delete.tap()
        XCTAssertTrue(app.buttons["viewer-edit"].waitForNonExistence(timeout: 20), "确认删除后应返回网格")
        let cell = app.collectionViews["photo-grid"].cells["photo-cell-0"]
        XCTAssertTrue(cell.waitForExistence(timeout: 15)); XCTAssertTrue(cell.isHittable); cell.tap()
        XCTAssertTrue(app.buttons["viewer-edit"].waitForExistence(timeout: 10), "删除后网格应可再次打开照片")
    }

    func testSmallSlowHorizontalDragBouncesBack() {
        let app = launch(["-PhotoVault.library.browseMode", "expanded"])
        openViewer(app)
        let counter = app.staticTexts["viewer-counter"]
        let before = counter.label
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.4))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.63, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 0.2)
        XCTAssertEqual(counter.label, before, "12% 宽度的慢拖应回弹，不应误翻页")
        app.swipeLeft()
        expectation(for: NSPredicate(format: "label != %@", before), evaluatedWith: counter)
        waitForExpectations(timeout: 10)
    }

    func testNoteSavedAndSearchableInDiscovery() {
        let app = launch(["-PhotoVault.library.browseMode", "expanded"])
        openViewer(app)
        app.buttons["更多照片操作"].tap()
        app.buttons["备注 / 日记"].tap()
        let editor = app.textViews["photo-note-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.tap()
        editor.typeText("Reference workflow note")
        app.buttons["photo-note-save"].tap()
        app.buttons["关闭"].firstMatch.tap()
        app.tabBars.buttons["发现"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Reference workflow note")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Reference workflow note'")).firstMatch.waitForExistence(timeout: 10))
    }

    func testCleanupScansLocalMediaAndMapOpens() {
        let app = launch(["-PhotoVault.library.browseMode", "expanded"])
        XCTAssertTrue(app.tabBars.buttons["清理"].waitForExistence(timeout: 15)); app.tabBars.buttons["清理"].tap()
        let scan = app.buttons["开始扫描"].firstMatch
        if scan.waitForExistence(timeout: 5) { scan.tap() } else { app.buttons["更新扫描"].firstMatch.tap() }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '已读取本机媒体'")).firstMatch.waitForExistence(timeout: 60))
        capture("cleanup-results", app: app)
        app.tabBars.buttons["地图"].tap()
        XCTAssertTrue(app.navigationBars["照片地图"].waitForExistence(timeout: 10))
        capture("photo-map", app: app)
    }
}
