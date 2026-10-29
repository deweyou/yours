import XCTest

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@MainActor
final class YoursUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["YOURS_UI_TEST_SESSION"] = UUID().uuidString
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        #if os(macOS)
            // Window restoration is process-global for the bundle identifier. A prior
            // run that quit without an open window must not suppress the test window.
            app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        app.launch()
        #if os(macOS)
            app.activate()
            if !app.windows.firstMatch.waitForExistence(timeout: 3) {
                // AppKit can finish terminating the previous UI-test instance after
                // the next launch request. Relaunch once when that race leaves only
                // the application menu and no document window.
                app.terminate()
                app.launch()
                app.activate()
            }
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        #endif
    }

    override func tearDownWithError() throws {
        if let app {
            #if os(macOS)
                let window = app.windows.firstMatch
                let screenshot = window.exists ? window.screenshot() : app.screenshot()
            #else
                let screenshot = app.screenshot()
            #endif
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    func testLargeGalleryScrollPerformance() {
        app.terminate()
        app.launchEnvironment["YOURS_UI_TEST_GALLERY_COUNT"] = "1000"
        app.launch()
        #if os(macOS)
            app.activate()
            app.buttons["workspace-documents"].click()
            let gallery = app.scrollViews["record-gallery"]
        #else
            app.buttons["全部记录"].firstMatch.tap()
            let gallery = app.collectionViews["record-gallery"]
        #endif
        XCTAssertTrue(gallery.waitForExistence(timeout: 15))
        #if os(macOS)
            XCTAssertTrue(recordCard(titled: "Gallery 0000").waitForExistence(timeout: 10))
        #else
            XCTAssertTrue(app.staticTexts["Gallery 0000"].waitForExistence(timeout: 10))
        #endif
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app), XCTCPUMetric(application: app)], options: options) {
            for _ in 0..<5 {
                #if os(macOS)
                    gallery.scroll(byDeltaX: 0, deltaY: -600)
                #else
                    gallery.swipeUp(velocity: .fast)
                #endif
            }
            for _ in 0..<5 {
                #if os(macOS)
                    gallery.scroll(byDeltaX: 0, deltaY: 600)
                #else
                    gallery.swipeDown(velocity: .fast)
                #endif
            }
        }
        XCTAssertTrue(gallery.exists)
        #if os(macOS)
            gallery.scroll(byDeltaX: 0, deltaY: -900)
        #else
            gallery.swipeUp()
        #endif
        let cards = gallery.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "note-row-"))
        guard let card = cards.allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.minY >= gallery.frame.minY + 20 }) else {
            return XCTFail("Expected an accessible, visible card after scrolling")
        }
        let identifier = card.identifier
        let originalY = card.frame.minY
        #if os(macOS)
            card.click()
        #else
            card.tap()
        #endif
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        #if os(macOS)
            app.buttons["workspace-documents"].click()
        #else
            app.navigationBars.buttons.element(boundBy: 0).tap()
        #endif
        let restored = app.buttons[identifier]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertEqual(restored.frame.minY, originalY, accuracy: 4, "Returning to the gallery must preserve the viewport")
    }

    private var editor: XCUIElement { app.textViews["note-editor"] }

    private func newNote() {
        #if os(macOS)
            // Inbox keeps the add action available even when empty.
            app.buttons["workspace-documents"].click()
            let button = app.buttons["new-note"]
        #else
            let button = app.buttons["new-note"]
        #endif
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        #if os(macOS)
            button.click()
        #else
            button.tap()
        #endif
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        #if os(macOS)
            editor.click()
        #else
            editor.tap()
        #endif
    }

    private func expectText(_ text: String) {
        let predicate = NSPredicate(format: "value == %@", text)
        expectation(for: predicate, evaluatedWith: editor)
        waitForExpectations(timeout: 5)
    }

    #if os(macOS)
        private func recordCard(titled title: String) -> XCUIElement {
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "note-row-", title)
            ).firstMatch
        }

        func testMacHistoryRestoresDocumentAndClearsForwardBranch() {
            let back = app.buttons["navigation-back"]
            let forward = app.buttons["navigation-forward"]
            XCTAssertFalse(back.isEnabled)
            XCTAssertFalse(forward.isEnabled)
            newNote()
            editor.typeText("Keep this document")
            app.buttons["workspace-settings"].click()
            XCTAssertTrue(app.popUpButtons["settings-theme"].waitForExistence(timeout: 5))
            back.click()
            expectText("Keep this document")
            back.click()
            XCTAssertTrue(app.scrollViews["record-gallery"].waitForExistence(timeout: 5))
            forward.click()
            expectText("Keep this document")
            app.buttons["workspace-tasks"].click()
            XCTAssertFalse(forward.isEnabled)
        }

        func testMacEnglishSettingsAndThemeSelection() {
            app.buttons["workspace-settings"].click()
            XCTAssertTrue(app.popUpButtons["settings-theme"].waitForExistence(timeout: 5))
            let chineseSettings = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            chineseSettings.name = "Settings Chinese"
            chineseSettings.lifetime = .keepAlways
            add(chineseSettings)
            app.terminate()
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
            app.launch()
            app.buttons["workspace-settings"].click()
            let theme = app.popUpButtons["settings-theme"]
            XCTAssertTrue(theme.waitForExistence(timeout: 5))
            XCTAssertEqual(theme.label, "Theme")
            theme.click()
            app.menuItems["Dark"].click()
            XCTAssertEqual(theme.value as? String, "Dark")
            theme.click()
            app.menuItems["Light"].click()
            XCTAssertEqual(theme.value as? String, "Light")
            XCTAssertTrue(app.popUpButtons["settings-language"].exists)
            // The native small macOS switch exposes a toggle button rather than an iOS-style Switch.
            let cloudToggle = app.descendants(matching: .any)["settings-icloud-sync"].firstMatch
            XCTAssertTrue(cloudToggle.exists)
            XCTAssertFalse(cloudToggle.isEnabled, "Automated test sessions must never connect to CloudKit")
            XCTAssertEqual(cloudToggle.frame.maxX, theme.frame.maxX, accuracy: 1)
            XCTAssertLessThanOrEqual(cloudToggle.frame.height, theme.frame.height)
            let profile = app.staticTexts["settings-storage-profile"]
            XCTAssertTrue(profile.exists)
            let profileText = profile.label + (profile.value as? String ?? "")
            XCTAssertTrue(profileText.contains("Automated tests"))
        }

        func testMacSettingsLanguageConfirmationAndCompactLoading() throws {
            app.terminate()
            app.launchEnvironment["YOURS_UI_TEST_SYNC_LOADING"] = "1"
            app.launch()
            app.activate()
            newNote()
            app.textFields["note-title"].click()
            app.textFields["note-title"].typeText("Language restart check\n")
            editor.click()
            editor.typeText("语言重启验证")
            app.buttons["workspace-settings"].click()
            let language = app.popUpButtons["settings-language"]
            XCTAssertTrue(language.waitForExistence(timeout: 5))
            let storageProfile = app.staticTexts["settings-storage-profile"]
            let storageIdentity = try XCTUnwrap(storageProfile.value as? String)
            let testSession = try XCTUnwrap(app.launchEnvironment["YOURS_UI_TEST_SESSION"])
            XCTAssertTrue(storageIdentity.hasPrefix(testSession + "|"))
            let progress = app.descendants(matching: .any)["settings-sync-progress"].firstMatch
            XCTAssertTrue(progress.exists, app.debugDescription)
            XCTAssertLessThanOrEqual(progress.frame.height, 16)
            let loading = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            loading.name = "Compact sync loading"
            loading.lifetime = .keepAlways
            add(loading)
            language.click()
            app.menuItems["English"].click()
            XCTAssertTrue(app.sheets.buttons["settings-language-confirm"].waitForExistence(timeout: 5))
            app.sheets.buttons["取消"].click()
            XCTAssertEqual(language.value as? String, "中文")
            language.click()
            app.menuItems["English"].click()
            app.sheets.buttons["settings-language-confirm"].click()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
            app.activate()
            XCTAssertTrue(app.buttons["workspace-settings"].waitForExistence(timeout: 5))
            app.buttons["workspace-settings"].click()
            XCTAssertEqual(app.popUpButtons["settings-language"].value as? String, "English")
            XCTAssertEqual(app.popUpButtons["settings-theme"].label, "Theme")
            XCTAssertEqual(
                storageProfile.value as? String, storageIdentity,
                "Restart must reopen the same isolated storage root and session")
            app.buttons["workspace-documents"].click()
            let savedNote = recordCard(titled: "Language restart check")
            XCTAssertTrue(savedNote.waitForExistence(timeout: 5))
            savedNote.click()
            expectText("语言重启验证")
        }

        func testMacCleanWorkspaceAndInbox() {
            XCTAssertFalse(app.scrollViews["record-gallery"].exists)
            app.buttons["workspace-documents"].click()
            XCTAssertTrue(app.buttons["documents-inbox"].exists)
            XCTAssertFalse(app.buttons["new-folder"].exists)
            XCTAssertFalse(app.buttons["import-markdown"].exists)
            XCTAssertFalse(app.searchFields.firstMatch.exists)
            newNote()
            app.textFields["note-title"].click()
            app.textFields["note-title"].typeText("First record\n")
            editor.click()
            editor.typeText("A quick thought")
            XCTAssertFalse(app.menuButtons["Markdown"].exists)
            XCTAssertFalse(app.menuButtons["textformat"].exists)
            XCTAssertFalse(app.buttons["format-bold"].exists)
            app.buttons["documents-inbox"].click()
            app.buttons["new-note"].click()
            app.textFields["note-title"].click()
            app.textFields["note-title"].typeText("Second record\n")
            editor.click()
            editor.typeText("Another thought")
            app.buttons["documents-inbox"].click()
            XCTAssertTrue(recordCard(titled: "First record").waitForExistence(timeout: 5))
            recordCard(titled: "First record").click()
            expectText("A quick thought")
            app.buttons["workspace-documents"].click()
            XCTAssertTrue(app.scrollViews["record-gallery"].waitForExistence(timeout: 5))
            recordCard(titled: "Second record").click()
            expectText("Another thought")
            app.terminate()
            app.launch()
            app.buttons["workspace-documents"].click()
            recordCard(titled: "First record").click()
            expectText("A quick thought")
        }
    #endif

    func testCreateEditAndRestoreAfterRelaunch() {
        newNote()
        let title = app.textFields["note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        let titleText = "Independent title that wraps when the available width becomes narrow"
        title.typeText(titleText)
        title.typeText("\n")
        editor.typeText("A persistent note\nSecond line")
        expectText("A persistent note\nSecond line")
        app.terminate()
        app.launch()
        // Reopen the saved document through the platform navigation.
        if !editor.waitForExistence(timeout: 2) {
            #if os(iOS)
                app.buttons["全部记录"].firstMatch.tap()
                app.staticTexts[titleText].firstMatch.tap()
            #else
                app.buttons["workspace-documents"].click()
                recordCard(titled: titleText).tap()
            #endif
        }
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        expectText("A persistent note\nSecond line")
        XCTAssertEqual(app.textFields["note-title"].value as? String, titleText)
    }

    func testMarkdownShortcutRemovesMarkersAndContinuesList() {
        newNote()
        // Deliver keystrokes instead of a paste, matching the shortcut contract.
        for character in "Text**bold**" { editor.typeText(String(character)) }
        expectText("Textbold")
        editor.typeText("\n")
        for character in "- " { editor.typeText(String(character)) }
        editor.typeText("First\nSecond")
        expectText("Textbold\nFirst\nSecond")
    }

    #if os(iOS)
        func testEmptyNoteCanStartTaskListFromToolbar() {
            newNote()
            let tasks = app.buttons["待办列表"]
            XCTAssertTrue(tasks.waitForExistence(timeout: 5))
            tasks.tap()
            editor.tap()
            editor.typeText("First task")
            expectText("First task")
        }

    #endif

    #if os(iOS)
        func testIPadEditorSurvivesRotation() throws {
            guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad window scenario") }
            app.buttons["workspace-notes"].firstMatch.tap()
            app.buttons["empty-new-note"].tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            editor.tap()
            editor.typeText("Keep this editor through rotation")
            XCUIDevice.shared.orientation = .landscapeLeft
            expectText("Keep this editor through rotation")
            XCTAssertTrue(app.buttons["workspace-notes"].isHittable)
            editor.typeText(" continued")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "iPad wide editor"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCUIDevice.shared.orientation = .portrait
            expectText("Keep this editor through rotation continued")
        }

        func testMobileSearchAndReturn() {
            app.buttons["全部记录"].firstMatch.tap()
            app.buttons["empty-new-note"].tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            app.textFields["note-title"].tap()
            app.textFields["note-title"].typeText("Searchable note\n")
            editor.tap()
            editor.typeText("Distinctive body token")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText("Distinctive")
            XCTAssertTrue(app.staticTexts["Searchable note"].exists)
            search.typeText("zzz")
            XCTAssertFalse(app.staticTexts["Searchable note"].exists)
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
            app.staticTexts["Searchable note"].tap()
            expectText("Distinctive body token")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let cancelSearch = app.buttons.matching(
                NSPredicate(format: "label IN %@", ["关闭", "Close", "取消", "Cancel"])
            ).firstMatch
            XCTAssertTrue(cancelSearch.waitForExistence(timeout: 5))
            cancelSearch.tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["workspace-tasks"].waitForExistence(timeout: 5))
            app.buttons["workspace-tasks"].tap()
            let quickAdd = app.textFields["todo-quick-add"]
            XCTAssertTrue(quickAdd.waitForExistence(timeout: 5))
            quickAdd.tap()
            quickAdd.typeText("Mobile task\n")
            let taskTitle = app.textViews.matching(NSPredicate(format: "value == %@", "Mobile task")).firstMatch
            XCTAssertTrue(taskTitle.waitForExistence(timeout: 5))
        }

        func testMobileLibraryOrganizationAndRestoration() {
            app.buttons["new-folder"].tap()
            let name = app.alerts.textFields.firstMatch
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.typeText("Mobile folder")
            app.alerts.buttons["保存"].tap()
            app.buttons["empty-new-note"].tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            let title = app.textFields["note-title"]
            title.tap()
            title.typeText("Mobile note\n")
            editor.tap()
            editor.typeText("Persistent mobile content")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.staticTexts["Mobile note"].waitForExistence(timeout: 5))
            app.staticTexts["Mobile note"].tap()
            app.buttons["organize-note"].tap()
            app.buttons["移动到分类"].tap()
            app.buttons["未分类"].tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["empty-new-note"].waitForExistence(timeout: 5))
            app.terminate()
            app.launch()
            app.buttons["全部记录"].firstMatch.tap()
            app.staticTexts["Mobile note"].tap()
            expectText("Persistent mobile content")
        }
    #endif

    #if os(iOS)
        func testTableTouchEditingAndReturnToDocument() {
            newNote()
            app.buttons["insert-table"].tap()
            XCTAssertTrue(app.buttons["table-apply"].waitForExistence(timeout: 5))
            app.buttons["table-apply"].tap()
            let header = app.textFields["table-cell-0-0"]
            XCTAssertTrue(header.waitForExistence(timeout: 5))
            header.tap()
            header.typeText("Name")
            let value = app.textFields["table-cell-1-0"]
            value.tap()
            value.typeText("Touch edit")
            app.buttons["table-exit"].tap()
            editor.typeText("After table")
            XCTAssertEqual(value.value as? String, "Touch edit")
            XCTAssertTrue((editor.value as? String)?.hasSuffix("After table") == true)
        }

        func testTouchSelectionFormattingPreservesTarget() {
            newNote()
            editor.typeText("Selected")
            editor.doubleTap()
            let format = app.menuItems["格式"]
            XCTAssertTrue(format.waitForExistence(timeout: 5), app.debugDescription)
            format.tap()
            let bold = app.collectionViews.buttons["加粗"].firstMatch
            XCTAssertTrue(bold.waitForExistence(timeout: 5), app.debugDescription)
            bold.tap()
            editor.typeText("Replacement")
            expectText("Replacement")
        }

        func testTouchSlashSearchAndContinuedInput() {
            newNote()
            editor.typeText("/h2")
            let heading = app.buttons["slash-command-heading-2"]
            XCTAssertTrue(heading.waitForExistence(timeout: 5))
            heading.tap()
            expectText("")
            editor.typeText("Heading\nBody")
            expectText("Heading\nBody")
        }

        func testSecondReturnExitsTaskAndQuoteOnTouchEditor() {
            newNote()
            for character in "[] " { editor.typeText(String(character)) }
            editor.typeText("Task")
            editor.typeText("\n")
            XCTAssertEqual(editor.value as? String, "Task\n", "第一次 Return 后应保留空待办；label=\(editor.label)")
            editor.typeText("\n")
            XCTAssertEqual(editor.value as? String, "Task\n", "第二次 Return 应退出空待办；label=\(editor.label)")
            editor.typeText("Body")
            expectText("Task\nBody")

            editor.typeText("\n")
            for character in "> " { editor.typeText(String(character)) }
            editor.typeText("Quote")
            editor.typeText("\n")
            editor.typeText("\n")
            editor.typeText("After quote")
            expectText("Task\nBody\nQuote\nAfter quote")
        }
    #endif

    #if os(macOS)
        func testSlashSearchConversionUndoAndContinuedInput() {
            newNote()
            editor.typeText("/h2")
            XCTAssertTrue(app.buttons["slash-command-heading-2"].waitForExistence(timeout: 5))
            editor.typeKey(.return, modifierFlags: [])
            expectText("")
            editor.typeKey("z", modifierFlags: .command)
            expectText("/h2")
            XCTAssertFalse(app.buttons["slash-command-heading-2"].exists)
            editor.typeKey("z", modifierFlags: [.command, .shift])
            expectText("")
            editor.typeText("Heading\nBody")
            expectText("Heading\nBody")
            app.terminate()
            app.launch()
            app.activate()
            app.buttons["workspace-documents"].click()
            let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "note-row-")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            card.click()
            expectText("Heading\nBody")
        }

        func testSlashCancellationAndNoResultPreserveLiteralText() {
            newNote()
            editor.typeText("/h2")
            XCTAssertTrue(app.buttons["slash-command-heading-2"].waitForExistence(timeout: 5))
            editor.typeKey(.escape, modifierFlags: [])
            expectText("/h2")
            XCTAssertFalse(app.buttons["slash-command-heading-2"].exists)
            editor.typeText("\n/zzzznomatch")
            editor.typeKey(.return, modifierFlags: [])
            editor.typeText("Literal https://example.com/a/b")
            expectText("/h2\n/zzzznomatch\nLiteral https://example.com/a/b")
            XCTAssertFalse(app.buttons["slash-command-body"].exists)
        }

        func testSlashTableInsertsAndFocusesFirstCell() {
            newNote()
            editor.typeText("Intro ")
            editor.typeText("/")
            editor.typeText("table")
            XCTAssertTrue(app.buttons["slash-command-table"].waitForExistence(timeout: 5))
            editor.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(app.buttons["table-apply"].waitForExistence(timeout: 5))
            app.buttons["table-apply"].click()
            let header = app.textFields["table-cell-0-0"]
            XCTAssertTrue(header.waitForExistence(timeout: 5))
            // Send to the current first responder without clicking the cell.
            app.typeText("Name")
            XCTAssertEqual(header.value as? String, "Name")
            XCTAssertTrue((editor.value as? String)?.hasPrefix("Intro ") == true)
        }

        func testSelectionFormattingRetainsReplacementTarget() {
            newNote()
            editor.typeText("Selected text")
            editor.typeKey("a", modifierFlags: .command)
            let bold = app.buttons["selection-bold"]
            XCTAssertTrue(bold.waitForExistence(timeout: 5))
            bold.click()
            expectText("Selected text")
            editor.typeText("Replacement")
            expectText("Replacement")
            editor.typeKey("z", modifierFlags: .command)
            expectText("Selected text")
        }

        func testSelectionLinkPanelCancelAndApplyKeepText() {
            newNote()
            editor.typeText("Link label")
            editor.typeKey("a", modifierFlags: .command)
            let link = app.buttons["selection-link"]
            XCTAssertTrue(link.waitForExistence(timeout: 5))
            link.click()
            let address = app.textFields["link-address"]
            XCTAssertTrue(address.waitForExistence(timeout: 5))
            address.click()
            address.typeText("https://example.com")
            app.buttons["link-cancel"].click()
            expectText("Link label")
            XCTAssertTrue(link.waitForExistence(timeout: 5))
            link.click()
            XCTAssertTrue(address.waitForExistence(timeout: 5))
            address.click()
            address.typeKey("a", modifierFlags: .command)
            address.typeText("https://example.com")
            app.buttons["link-apply"].click()
            expectText("Link label")
            XCTAssertTrue(link.waitForExistence(timeout: 5))
            link.click()
            XCTAssertTrue(address.waitForExistence(timeout: 5))
            XCTAssertEqual(address.value as? String, "https://example.com")
            app.buttons["link-cancel"].click()
            editor.typeText("Replaced link")
            expectText("Replaced link")
        }

        func testSecondReturnExitsEmptyBulletItem() {
            newNote()
            for character in "- " { editor.typeText(String(character)) }
            editor.typeText("First")
            editor.typeKey(.escape, modifierFlags: [])
            editor.typeText("\n")
            editor.typeText("\n")
            editor.typeText("Body")
            expectText("First\nBody")
        }

        func testSecondReturnExitsEmptyTaskItem() {
            newNote()
            for character in "[] " { editor.typeText(String(character)) }
            editor.typeText("Task")
            editor.typeKey(.escape, modifierFlags: [])
            editor.typeText("\n")
            editor.typeText("\n")
            editor.typeText("Body")
            expectText("Task\nBody")
        }

        func testSecondReturnExitsQuoteBeforeFollowingBody() {
            newNote()
            for character in "> " { editor.typeText(String(character)) }
            editor.typeText("1")
            editor.typeKey(.escape, modifierFlags: [])
            editor.typeText("\n")
            editor.typeText("\n")
            editor.typeText("Body")
            expectText("1\nBody")
        }

        func testBackspaceOnEmptiedHeadingClearsHeadingStyle() {
            newNote()
            for character in "# " { editor.typeText(String(character)) }
            editor.typeText("Heading")
            editor.typeKey("a", modifierFlags: .command)
            editor.typeKey(.delete, modifierFlags: [])
            editor.typeKey(.delete, modifierFlags: [])
            editor.typeText("Body")
            expectText("Body")
        }

        func testDeletingInlineCodeContentClearsTypingStyle() {
            newNote()
            editor.typeText("`")
            editor.typeText("code")
            editor.typeText("`")
            expectText("code")
            editor.typeKey("a", modifierFlags: .command)
            editor.typeKey(.delete, modifierFlags: [])
            editor.typeText("next")
            expectText("next")
        }

        func testCodeLanguageIndentAndUndo() {
            newNote()
            for character in "```swift" { editor.typeText(String(character)) }
            editor.typeText("\n")
            editor.typeText("let value = 42")
            expectText("let value = 42\n")
            // SwiftUI exposes the menu title and disclosure chevron as two AX menu buttons.
            let languageMenu = app.menuButtons["code-language"].firstMatch
            XCTAssertTrue(languageMenu.waitForExistence(timeout: 5))
            app.typeKey(.tab, modifierFlags: [])
            expectText("  let value = 42\n")
            app.typeKey("z", modifierFlags: .command)
            expectText("let value = 42\n")
            app.typeKey("z", modifierFlags: [.command, .shift])
            expectText("  let value = 42\n")
            app.typeKey(.return, modifierFlags: [])
            app.typeText("next")
            expectText("  let value = 42\n  next\n")
            app.buttons["copy-code"].tap()
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "  let value = 42\n  next\n")
            languageMenu.tap()
            app.menuItems["Python"].tap()
            expectText("  let value = 42\n  next\n")
        }

        func testStrikeShortcutUndoAndOrdinaryContinuation() {
            newNote()
            for character in "~~done~~" { editor.typeText(String(character)) }
            expectText("done")
            editor.typeKey("z", modifierFlags: .command)
            expectText("~~done~~")
            editor.typeKey("z", modifierFlags: [.command, .shift])
            expectText("done")
            editor.typeText(" next")
            expectText("done next")
        }
    #endif

    #if os(macOS)
        func testUndoShortcutRestoresLiteralSyntax() {
            newNote()
            for character in "**bold**" { editor.typeText(String(character)) }
            expectText("bold")
            editor.typeKey("z", modifierFlags: .command)
            expectText("**bold**")
        }
    #endif
}
