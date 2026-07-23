import XCTest

@MainActor
final class ClearScanUIKitUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchEnvironment["CLEARSCAN_SEED_SAMPLE"] = "1"
    app.launch()
  }

  func testPageEditorActionsAndMultiPageExportEntry() throws {
    let sampleFolder = app.cells["folder.학습 자료"]
    XCTAssertTrue(sampleFolder.waitForExistence(timeout: 5))
    sampleFolder.tap()

    let sampleDocument = app.cells["document.UI 테스트 문서"]
    XCTAssertTrue(sampleDocument.waitForExistence(timeout: 5))
    sampleDocument.tap()

    let firstPage = app.cells["page.1"]
    let secondPage = app.cells["page.2"]
    XCTAssertTrue(firstPage.waitForExistence(timeout: 5))
    XCTAssertTrue(secondPage.exists)
    firstPage.tap()

    for title in ["자동 자르기", "회전", "AI 보정", "AI OCR", "삭제", "원본 복원"] {
      let action = app.buttons["pageAction.\(title)"]
      XCTAssertTrue(action.waitForExistence(timeout: 3), "\(title) 버튼이 보여야 합니다.")
      XCTAssertTrue(action.isHittable, "\(title) 버튼을 누를 수 있어야 합니다.")
    }

    let signatureButton = app.buttons["pageAction.signature"]
    XCTAssertTrue(signatureButton.waitForExistence(timeout: 3))
    XCTAssertTrue(signatureButton.isHittable)
    signatureButton.tap()
    XCTAssertTrue(app.navigationBars["서명"].waitForExistence(timeout: 5))
    for identifier in ["signature.canvas", "signature.undo", "signature.eraser"] {
      XCTAssertTrue(app.descendants(matching: .any)[identifier].exists)
    }
    app.buttons["signature.cancel"].tap()
    XCTAssertTrue(app.buttons["pageAction.signature"].waitForExistence(timeout: 3))

    let selectionEraserButton = app.buttons["pageAction.selectionEraser"]
    XCTAssertTrue(selectionEraserButton.waitForExistence(timeout: 3))
    XCTAssertTrue(selectionEraserButton.isHittable)
    selectionEraserButton.tap()
    XCTAssertTrue(app.navigationBars["선택 지우개"].waitForExistence(timeout: 5))
    for identifier in [
      "selectionEraser.canvas", "selectionEraser.previewImage", "selectionEraser.brushSize",
    ] {
      XCTAssertTrue(app.descendants(matching: .any)[identifier].exists)
    }
    app.buttons["selectionEraser.cancel"].tap()
    XCTAssertTrue(app.buttons["pageAction.selectionEraser"].waitForExistence(timeout: 3))

    app.navigationBars.buttons["UI 테스트 문서"].tap()
    XCTAssertTrue(firstPage.waitForExistence(timeout: 5))

    let editButton = app.buttons["editPages"]
    XCTAssertTrue(editButton.waitForExistence(timeout: 3))
    editButton.tap()
    firstPage.tap()
    secondPage.tap()

    XCTAssertTrue(app.staticTexts["2페이지 선택"].waitForExistence(timeout: 3))
    let exportButton = app.buttons["exportSelectedPages"]
    XCTAssertTrue(exportButton.isEnabled)
    exportButton.tap()

    XCTAssertTrue(app.staticTexts["선택한 2페이지 내보내기"].waitForExistence(timeout: 3))
    for format in ["PDF", "JPEG", "ZIP"] {
      XCTAssertTrue(app.buttons[format].exists, "\(format) 내보내기 항목이 보여야 합니다.")
    }
  }

  func testCameraShutterRemainsVisibleAcrossIPadOrientations() throws {
    let cameraPermissionMonitor = addUIInterruptionMonitor(
      withDescription: "카메라 접근 권한"
    ) { alert in
      for title in ["허용", "Allow"] {
        let allowButton = alert.buttons[title]
        if allowButton.exists {
          allowButton.tap()
          return true
        }
      }
      return false
    }
    defer { removeUIInterruptionMonitor(cameraPermissionMonitor) }

    let cameraTab = app.buttons.matching(NSPredicate(format: "label == %@", "촬영")).firstMatch
    XCTAssertTrue(cameraTab.waitForExistence(timeout: 5))
    cameraTab.tap()
    // A top-left coordinate can hit iPadOS's "Back to previous app" breadcrumb
    // on a physical device. The preview center safely triggers an interruption
    // monitor without leaving ClearScan.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    let scannerUnavailableAlert = app.alerts.firstMatch
    if scannerUnavailableAlert.waitForExistence(timeout: 3) {
      let confirmButton = scannerUnavailableAlert.buttons["확인"]
      if confirmButton.exists {
        confirmButton.tap()
      }
    }
    let shutter = app.buttons["documentShutter"]

    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(shutter.waitForExistence(timeout: 5))
    XCTAssertTrue(shutter.isHittable, "iPad 세로 화면에서 촬영 버튼을 누를 수 있어야 합니다.")
    XCTAssertTrue(
      shutter.value as? String == "자동 촬영 0%"
        || (shutter.value as? String)?.hasPrefix("자동 촬영 ") == true,
      "촬영 버튼은 자동 촬영 원형 진행률을 접근성 값으로 제공해야 합니다."
    )
    let portraitScreenshot = XCTAttachment(screenshot: app.screenshot())
    portraitScreenshot.name = "iPad portrait camera shutter"
    portraitScreenshot.lifetime = .keepAlways
    add(portraitScreenshot)

    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(shutter.waitForExistence(timeout: 5))
    XCTAssertTrue(shutter.isHittable, "iPad 가로 화면에서도 촬영 버튼을 누를 수 있어야 합니다.")
    let landscapeScreenshot = XCTAttachment(screenshot: app.screenshot())
    landscapeScreenshot.name = "iPad landscape camera shutter"
    landscapeScreenshot.lifetime = .keepAlways
    add(landscapeScreenshot)
  }

  func testLiveCameraAutoCapturesAStableVisibleDocument() throws {
    let cameraPermissionMonitor = addUIInterruptionMonitor(
      withDescription: "카메라 접근 권한"
    ) { alert in
      for title in ["허용", "Allow"] {
        let allowButton = alert.buttons[title]
        if allowButton.exists {
          allowButton.tap()
          return true
        }
      }
      return false
    }
    defer { removeUIInterruptionMonitor(cameraPermissionMonitor) }

    let cameraTab = app.buttons.matching(NSPredicate(format: "label == %@", "촬영")).firstMatch
    XCTAssertTrue(cameraTab.waitForExistence(timeout: 5))
    cameraTab.tap()
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

    let scannerUnavailableAlert = app.alerts.firstMatch
    if scannerUnavailableAlert.waitForExistence(timeout: 2) {
      let message = scannerUnavailableAlert.staticTexts.allElementsBoundByIndex
        .map(\.label)
        .joined(separator: " ")
      let confirmButton = scannerUnavailableAlert.buttons["확인"]
      if confirmButton.exists {
        confirmButton.tap()
      }
      if message.contains("후면 카메라") {
        throw XCTSkip("시뮬레이터에는 실제 후면 카메라가 없습니다.")
      }
    }

    let shutter = app.buttons["documentShutter"]
    XCTAssertTrue(shutter.waitForExistence(timeout: 5))
    let capturedPageLabel = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "페이지 촬영됨")
    ).firstMatch

    XCTAssertTrue(
      capturedPageLabel.waitForExistence(timeout: 8),
      "고정된 실제 문서가 보이면 원형 진행률이 완료되고 자동 촬영 결과가 추가되어야 합니다. "
        + "마지막 셔터 값: \(shutter.value ?? "없음")"
    )

    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Physical camera auto capture completed"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  func testAIEnhancementPreviewLayoutAcrossOrientations() throws {
    XCUIDevice.shared.orientation = .portrait

    let sampleFolder = app.cells["folder.학습 자료"]
    XCTAssertTrue(sampleFolder.waitForExistence(timeout: 5))
    sampleFolder.tap()

    let sampleDocument = app.cells["document.UI 테스트 문서"]
    XCTAssertTrue(sampleDocument.waitForExistence(timeout: 5))
    sampleDocument.tap()

    let firstPage = app.cells["page.1"]
    XCTAssertTrue(firstPage.waitForExistence(timeout: 5))
    firstPage.tap()

    let enhancementButton = app.buttons["pageAction.AI 보정"]
    XCTAssertTrue(enhancementButton.waitForExistence(timeout: 3))
    enhancementButton.tap()

    XCTAssertTrue(app.navigationBars["AI 보정"].waitForExistence(timeout: 3))
    let preview = app.images["aiEnhancement.preview"]
    let applyButton = app.buttons["aiEnhancement.apply"]
    let restoreButton = app.buttons["aiEnhancement.restore"]
    let toolList = app.tables["aiEnhancement.tools"]
    let fingerRemoval = app.cells["aiEnhancement.removeEdgeFinger"]
    let smartAuto = app.cells["aiEnhancement.smartAuto"]
    XCTAssertTrue(preview.waitForExistence(timeout: 3))
    XCTAssertTrue(toolList.waitForExistence(timeout: 3))
    XCTAssertTrue(fingerRemoval.waitForExistence(timeout: 3))
    XCTAssertTrue(applyButton.exists)
    XCTAssertTrue(restoreButton.exists)
    XCTAssertTrue(restoreButton.isHittable)

    for unavailableTitle in ["검은 필기 지우기", "책 곡률 보정", "AI 지우개"] {
      XCTAssertFalse(
        app.staticTexts[unavailableTitle].exists,
        "\(unavailableTitle)은 실제 지원 범위를 벗어나므로 사용자 기능에 노출하면 안 됩니다."
      )
    }

    XCTAssertTrue(preview.waitForExistence(timeout: 3))
    XCTAssertTrue(fingerRemoval.isHittable)
    XCTAssertTrue(restoreButton.isHittable)
    let portraitScreenshot = XCTAttachment(screenshot: app.screenshot())
    portraitScreenshot.name = "AI enhancement portrait"
    portraitScreenshot.lifetime = .keepAlways
    add(portraitScreenshot)

    for _ in 0..<4 where !smartAuto.isHittable {
      toolList.swipeUp()
    }
    XCTAssertTrue(smartAuto.waitForExistence(timeout: 3))
    XCTAssertTrue(smartAuto.isHittable)
    smartAuto.tap()
    let previewReady = NSPredicate(format: "label CONTAINS %@", "미리보기 준비됨")
    expectation(for: previewReady, evaluatedWith: app.staticTexts["aiEnhancement.status"])
    waitForExpectations(timeout: 8)
    XCTAssertTrue(applyButton.isEnabled)
    XCTAssertTrue(applyButton.isHittable)

    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(preview.waitForExistence(timeout: 3))
    XCTAssertTrue(applyButton.isHittable)
    XCTAssertTrue(restoreButton.isHittable)
    let landscapeScreenshot = XCTAttachment(screenshot: app.screenshot())
    landscapeScreenshot.name = "AI enhancement landscape"
    landscapeScreenshot.lifetime = .keepAlways
    add(landscapeScreenshot)
  }

  func testGoogleWorkspaceUsesNativeSeededDocuments() throws {
    XCUIDevice.shared.orientation = .portrait
    // iPhone exposes this control under a TabBar, while current iPadOS
    // presents the same UITabBarController items as a top floating bar.
    let googleTab = app.buttons.matching(identifier: "Google").firstMatch
    XCTAssertTrue(googleTab.waitForExistence(timeout: 5))
    googleTab.tap()

    let connectButton = app.buttons["google.connect"]
    XCTAssertTrue(connectButton.waitForExistence(timeout: 5))

    let configuration = app.staticTexts["google.oauth.configuration"]
    XCTAssertTrue(configuration.waitForExistence(timeout: 3))
    if configuration.label.contains("iOS OAuth 설정이 준비되었습니다") {
      XCTAssertTrue(connectButton.isEnabled)
    } else {
      XCTAssertTrue(
        configuration.label.contains("차단됨")
          && configuration.label.contains("iOS용 Google OAuth Client ID"),
        "공개 설정은 필요한 iOS OAuth 자격정보를 정확히 안내해야 합니다."
      )
      XCTAssertFalse(
        connectButton.isEnabled,
        "iOS OAuth 자격정보가 없을 때 작동하지 않는 연결 버튼을 활성화하면 안 됩니다."
      )
    }

    let nativePage = app.cells.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "google.page.")
    ).firstMatch
    XCTAssertTrue(nativePage.waitForExistence(timeout: 3))

    let pdfButton = app.buttons["google.upload.pdf"]
    let docsButton = app.buttons["google.upload.docs"]
    XCTAssertTrue(pdfButton.exists)
    XCTAssertTrue(docsButton.exists)
    XCTAssertFalse(pdfButton.isEnabled, "계정 연결 전에는 Drive 업로드가 비활성화되어야 합니다.")
    XCTAssertFalse(docsButton.isEnabled, "계정 연결 전에는 Docs OCR 업로드가 비활성화되어야 합니다.")

    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Native Google workspace with SwiftData pages"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}
