import XCTest
@testable import ClearScan

final class ScannerCaptureSettingsTests: XCTestCase {
    func testScannerDefaultsToSilentStandardLensWithTimerOff() {
        let scanner = DocumentScannerModel()

        XCTAssertEqual(scanner.captureQuality, .silentVideoFrame)
        XCTAssertEqual(scanner.captureTimer, .off)
        XCTAssertEqual(scanner.activeCameraLens, .standard)
        XCTAssertTrue(scanner.silentCapturePreferred)
    }

    func testTimerOptionsExposeExpectedCountdowns() {
        XCTAssertEqual(ScannerCaptureTimer.off.countdownValues, [])
        XCTAssertEqual(ScannerCaptureTimer.threeSeconds.countdownValues, [3, 2, 1])
        XCTAssertEqual(ScannerCaptureTimer.fiveSeconds.countdownValues, [5, 4, 3, 2, 1])
        XCTAssertEqual(ScannerCaptureTimer.threeSeconds.title, "3초")
    }

    func testCaptureQualityDescriptionsStateRealTradeoffs() {
        XCTAssertEqual(ScannerCaptureQuality.silentVideoFrame.title, "완전 무음")
        XCTAssertTrue(
            ScannerCaptureQuality.silentVideoFrame.limitationDescription.contains("해상도")
        )
        XCTAssertTrue(
            ScannerCaptureQuality.highQualityPhoto.limitationDescription.contains("셔터음")
        )
        XCTAssertNotEqual(
            ScannerCaptureQuality.silentVideoFrame.rawValue,
            ScannerCaptureQuality.highQualityPhoto.rawValue
        )
    }

    func testUnsupportedUltraWideFallsBackToStandardLens() {
        let capabilities = ScannerCameraCapabilities(availableLenses: [.standard])

        XCTAssertEqual(capabilities.availableLenses, [.standard])
        XCTAssertEqual(
            capabilities.resolvedLens(requested: .ultraWide),
            .standard
        )
    }

    func testUltraWideIsOnlyExposedWhenAvailable() {
        let capabilities = ScannerCameraCapabilities(
            availableLenses: [.standard, .ultraWide]
        )

        XCTAssertEqual(capabilities.availableLenses, [.ultraWide, .standard])
        XCTAssertEqual(
            capabilities.resolvedLens(requested: .ultraWide),
            .ultraWide
        )
    }

    func testCountdownPhaseCarriesVisibleRemainingSeconds() {
        XCTAssertEqual(
            ScannerPhase.countdown(remainingSeconds: 3),
            .countdown(remainingSeconds: 3)
        )
        XCTAssertNotEqual(
            ScannerPhase.countdown(remainingSeconds: 3),
            .countdown(remainingSeconds: 2)
        )
    }
}
