import XCTest

final class HintUITests: XCTestCase {
    @MainActor
    func testFixedMixVisualAndVoiceInLandscapeAndPortrait() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--hint-demo-fixed", "--hint-demo-mix"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        let request = app.buttons["requestVisualHint"]
        XCTAssertTrue(request.waitForExistence(timeout: 15))
        request.tap()
        XCTAssertTrue(app.staticTexts["hintInstruction"].waitForExistence(timeout: 12))
        XCTAssertEqual(app.staticTexts["hintInstruction"].label, "看看两种颜色碰到一起的地方。")
        XCTAssertTrue(app.buttons["replayHint"].exists)
        attach("mix-fixed-landscape", app)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["replayHint"].waitForExistence(timeout: 5))
        attach("mix-fixed-portrait", app)
        app.buttons["dismissHint"].tap()
        XCTAssertTrue(request.waitForExistence(timeout: 5))
    }

    @MainActor
    func testAdaptivePressureShowsActionAndDoesNotChangeOriginalApp() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--hint-demo-pressure"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCTAssertTrue(app.buttons["requestVisualHint"].waitForExistence(timeout: 15))
        app.buttons["requestVisualHint"].tap()
        XCTAssertTrue(app.staticTexts["hintInstruction"].waitForExistence(timeout: 15))
        XCTAssertTrue(["下一条轻一点，不用使劲压。", "看看刚画的线，再看看目标线。"].contains(app.staticTexts["hintInstruction"].label))
        attach("pressure-adaptive-landscape", app)
    }

    @MainActor
    func testLiveDeepSeekMixWithBootstrap() throws {
        guard ProcessInfo.processInfo.environment["INKSTUDY_LIVE_HINT_TEST"] == "1" else { throw XCTSkip("Live API test is explicitly opt-in.") }
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
            for label in ["Allow", "允许", "OK", "好"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        app.launchArguments = ["--hint-bootstrap", "--hint-demo-mix"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCTAssertTrue(app.buttons["requestVisualHint"].waitForExistence(timeout: 20))
        app.tap()
        app.buttons["requestVisualHint"].tap()
        XCTAssertTrue(app.staticTexts["hintInstruction"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["hintSource"].label, "DeepSeek 已响应")
        attach("live-deepseek-mix-ipad", app)
    }

    @MainActor
    private func attach(_ name: String, _ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["replayHint"].isHittable)
        let landscape = name.contains("landscape") || name.contains("live-")
        let orientation = NSPredicate { _, _ in landscape ? app.frame.width > app.frame.height : app.frame.height > app.frame.width }
        let ready = expectation(for: orientation, evaluatedWith: app)
        wait(for: [ready], timeout: 5)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
