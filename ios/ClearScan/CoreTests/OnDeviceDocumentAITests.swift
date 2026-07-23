import XCTest
@testable import ClearScan

final class OnDeviceDocumentAITests: XCTestCase {
  func testSuggestedTitleUsesFirstNonEmptyLineAndLimitsLength() {
    let longTitle = String(repeating: "가", count: 60)

    let title = OnDeviceDocumentAI.suggestedTitle(from: ["  ", longTitle, "둘째 줄"])

    XCTAssertEqual(title, String(repeating: "가", count: 48))
  }

  func testSuggestedTitleReturnsNilWithoutText() {
    XCTAssertNil(OnDeviceDocumentAI.suggestedTitle(from: ["", "   ", "\n"]))
  }

  func testReadingOrderGroupsRowsAndSortsEachRowLeftToRight() {
    let lines = [
      DocumentOCRLine(
        text: "둘째 줄",
        confidence: 0.7,
        boundingBox: CGRect(x: 0.1, y: 0.45, width: 0.5, height: 0.08)
      ),
      DocumentOCRLine(
        text: "오른쪽",
        confidence: 0.8,
        boundingBox: CGRect(x: 0.58, y: 0.78, width: 0.3, height: 0.1)
      ),
      DocumentOCRLine(
        text: "첫 줄",
        confidence: 0.9,
        boundingBox: CGRect(x: 0.08, y: 0.8, width: 0.35, height: 0.1)
      )
    ]

    let ordered = OnDeviceDocumentAI.linesInReadingOrder(lines)

    XCTAssertEqual(ordered.map(\.text), ["첫 줄", "오른쪽", "둘째 줄"])
  }
}
