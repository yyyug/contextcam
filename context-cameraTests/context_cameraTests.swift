//
//  context_cameraTests.swift
//  context-cameraTests
//
//  Created by Conway Anderson on 1/29/24.
//

import XCTest
@testable import context_camera

final class context_cameraTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // This method is called after the invocation of each test method in the class.
    }

    func testTranslationDoesNotRunWhenDisabled() {
        XCTAssertFalse(
            CaptionTranslationSupport.shouldAttemptTranslation(
                for: "A brown dog running through the park.",
                isTranslationEnabled: false,
                targetLanguageIdentifier: "es"
            )
        )
    }

    func testTranslationDoesNotRunWithoutSelectedLanguage() {
        XCTAssertFalse(
            CaptionTranslationSupport.shouldAttemptTranslation(
                for: "A brown dog running through the park.",
                isTranslationEnabled: true,
                targetLanguageIdentifier: nil
            )
        )
    }

    func testTranslationRunsForDifferentLanguage() {
        XCTAssertTrue(
            CaptionTranslationSupport.shouldAttemptTranslation(
                for: "A brown dog running through the park.",
                isTranslationEnabled: true,
                targetLanguageIdentifier: "es"
            )
        )
    }

    func testTranslationSkipsWhenCaptionMatchesTargetLanguage() {
        XCTAssertFalse(
            CaptionTranslationSupport.shouldAttemptTranslation(
                for: "Un perro marron corre por el parque.",
                isTranslationEnabled: true,
                targetLanguageIdentifier: "es"
            )
        )
    }

    func testShortcutLaunchManagerTracksPendingCapture() {
        ShortcutLaunchManager.consumePendingCaptureRequest()
        XCTAssertFalse(ShortcutLaunchManager.hasPendingCaptureRequest())

        ShortcutLaunchManager.requestCaptureOnNextLaunch()
        XCTAssertTrue(ShortcutLaunchManager.hasPendingCaptureRequest())

        ShortcutLaunchManager.consumePendingCaptureRequest()
        XCTAssertFalse(ShortcutLaunchManager.hasPendingCaptureRequest())
    }

    func testPerformanceExample() throws {
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }
}
