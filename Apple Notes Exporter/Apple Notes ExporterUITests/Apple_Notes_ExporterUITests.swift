//
//  Apple_Notes_ExporterUITests.swift
//  Apple Notes Exporter
//
//  Copyright (C) 2026 Konstantin Zaremski
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import XCTest

final class Apple_Notes_ExporterUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testMainExporterControlsAndPDFPreviewUseSyntheticNotes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-exporter-main"]
        app.launch()

        let chooseNotes = app.buttons["noteSelectionButton"]
        XCTAssertTrue(chooseNotes.waitForExistence(timeout: 10))
        chooseNotes.click()

        let alphaSelection = app.buttons["note-selection-fixture-note-alpha"]
        XCTAssertTrue(alphaSelection.waitForExistence(timeout: 5))
        alphaSelection.click()
        app.buttons["Done"].click()

        let studyStyle = app.buttons["pdfStyleStudy"]
        XCTAssertTrue(studyStyle.waitForExistence(timeout: 5))
        studyStyle.click()
        XCTAssertEqual(studyStyle.value as? String, "Selezionato")

        let embedOnly = app.buttons["pdfAttachmentOnly"]
        XCTAssertTrue(embedOnly.exists)
        embedOnly.click()
        XCTAssertEqual(embedOnly.value as? String, "Selezionato")

        let advancedOptions = app.buttons["advancedOutputOptionsButton"]
        XCTAssertTrue(advancedOptions.waitForExistence(timeout: 5))
        advancedOptions.click()
        let organizationPicker = app.segmentedControls["folderOrganizationPicker"]
        XCTAssertTrue(organizationPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(organizationPicker.buttons["Tutte insieme"].exists)
        XCTAssertTrue(organizationPicker.buttons["Come in Note"].exists)
        organizationPicker.buttons["Come in Note"].click()
        app.buttons["Fine"].click()

        // The preference must survive an app restart, not only a re-render of
        // the advanced-options popover.
        app.terminate()
        app.launch()
        let reopenedAdvancedOptions = app.buttons["advancedOutputOptionsButton"]
        XCTAssertTrue(reopenedAdvancedOptions.waitForExistence(timeout: 10))
        reopenedAdvancedOptions.click()
        let reopenedOrganizationPicker = app.segmentedControls["folderOrganizationPicker"]
        XCTAssertTrue(reopenedOrganizationPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(reopenedOrganizationPicker.buttons["Come in Note"].isSelected)
        reopenedOrganizationPicker.buttons["Tutte insieme"].click()
        app.buttons["Fine"].click()

        app.buttons["previewButton"].click()
        let previewDocument = app.descendants(matching: .any)["pdfPreviewDocument"]
        XCTAssertTrue(previewDocument.waitForExistence(timeout: 20))
        let closeButton = app.buttons["pdfPreviewCloseButton"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        XCTAssertTrue(closeButton.isHittable)
        XCTAssertLessThanOrEqual(
            closeButton.frame.maxY,
            previewDocument.frame.minY,
            "The close control must remain in the fixed toolbar, outside the PDF page area"
        )

        let stylePicker = app.segmentedControls["previewStylePicker"]
        XCTAssertTrue(stylePicker.exists)
        stylePicker.buttons["Originale"].click()

        let status = app.descendants(matching: .any)["pdfPreviewStatus"]
        let refreshed = NSPredicate(format: "label == %@", "Aggiornamento automatico")
        expectation(for: refreshed, evaluatedWith: status)
        waitForExpectations(timeout: 20)

        closeButton.click()
        XCTAssertFalse(previewDocument.waitForExistence(timeout: 2))

        app.buttons["previewButton"].click()
        XCTAssertTrue(previewDocument.waitForExistence(timeout: 20))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(previewDocument.waitForExistence(timeout: 3), "Escape should dismiss the preview")
    }

    func testNoteSelectionIsIndependentAndSurvivesSearchAndFolderScopes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let alphaRow = app.buttons["note-row-fixture-note-alpha"]
        let alphaCheckbox = app.buttons["note-selection-fixture-note-alpha"]
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 10))
        XCTAssertEqual(alphaCheckbox.value as? String, "Not selected")

        // Highlighting a row is navigation only; the export checkbox is separate.
        alphaRow.click()
        XCTAssertEqual(alphaCheckbox.value as? String, "Not selected")
        XCTAssertEqual(app.descendants(matching: .any)["selected-note-count"].label, "0 notes selected")

        alphaCheckbox.click()
        XCTAssertEqual(alphaCheckbox.value as? String, "Selected")
        XCTAssertEqual(app.buttons["folder-selection-fixture-folder-projects"].value as? String, "partially selected")

        app.buttons["note-selection-fixture-note-beta"].click()
        XCTAssertEqual(app.buttons["folder-selection-fixture-folder-projects"].value as? String, "fully selected")
        XCTAssertEqual(app.descendants(matching: .any)["selected-note-count"].label, "2 notes selected")

        let search = app.textFields["Search all notes by title"]
        search.click()
        search.typeText("Synthetic Gamma")
        let gammaCheckbox = app.buttons["note-selection-fixture-note-gamma"]
        XCTAssertTrue(gammaCheckbox.waitForExistence(timeout: 5))
        gammaCheckbox.click()
        XCTAssertEqual(app.descendants(matching: .any)["selected-note-count"].label, "3 notes selected")

        app.buttons["Clear search"].click()
        XCTAssertTrue(alphaCheckbox.waitForExistence(timeout: 5))
        XCTAssertEqual(alphaCheckbox.value as? String, "Selected")
        XCTAssertEqual(app.buttons["account-selection-fixture-account"].value as? String, "fully selected")
    }

    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
