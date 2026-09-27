import XCTest

/// One-time setup driver. Taps system alerts + the in-app pair button + the
/// notification forwarding flow. Attaches screenshots + debug descriptions at
/// each step so failures can be diagnosed from the .xcresult bundle.
///
/// Run with:
///   xcodebuild test -project NotifBridge-iOS.xcodeproj \
///     -scheme NotifBridge \
///     -destination "id=<UDID>" \
///     -only-testing:NotifBridgeUITests/GrantPermsAndForward/testGrantAll
@MainActor
final class GrantPermsAndForward: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testGrantAll() throws {
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        app.launch()

        // 1. Bluetooth permission alert.
        attach(label: "01-after-launch")
        tapAny(in: springboard, labels: ["Allow", "OK", "Erlauben"], timeout: 12)

        // 2. Tap in-app pair button → triggers ASAccessorySession.showPicker.
        let pairButton = app.buttons["pair-accessory-button"]
        XCTAssertTrue(pairButton.waitForExistence(timeout: 10), "Pair button missing")
        pairButton.tap()
        attach(label: "02-pair-tapped")

        // 3. ASK picker.
        let askAccessoryName = "NotifBridge Mac"
        let accessoryCell = springboard.staticTexts[askAccessoryName]
        if accessoryCell.waitForExistence(timeout: 30) {
            accessoryCell.tap()
            attach(label: "03-ask-cell-tapped")
            tapAny(in: springboard, labels: [
                "Set Up", "Einrichten",
                "Pair", "Verbinden",
                "Continue", "Fortfahren",
            ], timeout: 15)
            tapAny(in: springboard, labels: [
                "Pair", "Verbinden",
                "Done", "Fertig",
            ], timeout: 8)
            attach(label: "04-ask-confirmed")
        }

        // 4. Wait for accessory model to populate (button becomes enabled).
        let forwardingButton = app.buttons["request-forwarding-button"]
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if forwardingButton.exists, forwardingButton.isEnabled, forwardingButton.isHittable {
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard forwardingButton.exists, forwardingButton.isEnabled, forwardingButton.isHittable else {
            attach(label: "05a-forwarding-button-disabled")
            attachTree(of: app, label: "05a-app-tree")
            XCTFail("request-forwarding-button never became hittable after pairing")
            return
        }
        forwardingButton.tap()
        attach(label: "05-forwarding-tapped")

        // 5. Forwarding sheet. iOS 26 flow seen empirically:
        //    Continue → Full Access → Forward All → Done (top-right checkmark)
        Thread.sleep(forTimeInterval: 1.5)
        attachTree(of: springboard, label: "06-sheet-intro")
        tapAnyElement(in: springboard, labels: ["Continue", "Fortfahren"], timeout: 20)
        Thread.sleep(forTimeInterval: 1.5)
        attachTree(of: springboard, label: "07-after-continue")
        tapAnyElement(in: springboard, labels: ["Full Access", "Voller Zugriff"], timeout: 20)
        Thread.sleep(forTimeInterval: 1.5)
        attachTree(of: springboard, label: "08-after-full-access")
        tapAnyElement(in: springboard, labels: ["Forward All", "Alle weiterleiten"], timeout: 20)
        Thread.sleep(forTimeInterval: 1.5)
        attachTree(of: springboard, label: "09-after-forward-all")
        tapAnyElement(in: springboard, labels: [
            "Done", "Fertig", "Confirm", "Bestätigen", "OK",
        ], timeout: 20)
        Thread.sleep(forTimeInterval: 2.0)
        attach(label: "10-after-done")

        // Wait for app to settle, then schedule a test notification.
        Thread.sleep(forTimeInterval: 5.0)
        let testButton = app.buttons["send-test-notification-button"]
        if testButton.waitForExistence(timeout: 10), testButton.isHittable {
            testButton.tap()
            attach(label: "11-test-notif-tapped")
        }

        // Capture forwarding status string from the LabeledContent value.
        Thread.sleep(forTimeInterval: 3.0)
        let forwardingStatus = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Forwarding")).firstMatch
        if forwardingStatus.exists {
            attach(label: "12-final", note: forwardingStatus.label)
        }
        attachTree(of: app, label: "13-final-app-tree")

        // Give extensions time to forward.
        sleep(30)
    }

    // MARK: - helpers

    private func attach(label: String, note: String = "") {
        let screenshot = XCUIScreen.main.screenshot()
        let img = XCTAttachment(screenshot: screenshot)
        img.name = "\(label).png"
        img.lifetime = .keepAlways
        add(img)
        if !note.isEmpty {
            let txt = XCTAttachment(string: note)
            txt.name = "\(label).txt"
            txt.lifetime = .keepAlways
            add(txt)
        }
    }

    private func attachTree(of app: XCUIApplication, label: String) {
        let dump = app.debugDescription
        let txt = XCTAttachment(string: dump)
        txt.name = "\(label)-tree.txt"
        txt.lifetime = .keepAlways
        add(txt)
    }

    private func tapAny(
        in app: XCUIApplication,
        labels: [String],
        timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for label in labels {
                let button = app.buttons[label]
                if button.exists, button.isHittable {
                    button.tap()
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private func tapAnyElement(
        in app: XCUIApplication,
        labels: [String],
        timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for label in labels {
                let button = app.buttons[label]
                if button.exists, button.isHittable {
                    button.tap()
                    return
                }
                let text = app.staticTexts[label]
                if text.exists, text.isHittable {
                    text.tap()
                    return
                }
                let cell = app.cells.containing(.staticText, identifier: label).firstMatch
                if cell.exists, cell.isHittable {
                    cell.tap()
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}
