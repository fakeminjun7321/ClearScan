import Foundation
import XCTest

@testable import ClearScan

final class ScanExportSelectionTests: XCTestCase {
  func testWholeDocumentSelectionUsesPageOrderAndEnhancedImages() throws {
    let first = ScanPage(
      sortIndex: 1,
      originalImagePath: "first-original.jpg",
      enhancedImagePath: "first-enhanced.jpg"
    )
    let second = ScanPage(
      sortIndex: 0,
      originalImagePath: "second-original.jpg"
    )
    let document = ScanDocument(title: "테스트", pages: [first, second])

    let selection = try ScanExportSelection(document: document)

    XCTAssertEqual(selection.pages.map(\.id), [second.id, first.id])
    XCTAssertEqual(
      selection.pages.map(\.imageRelativePath),
      ["second-original.jpg", "first-enhanced.jpg"]
    )
  }

  func testIndividualPageSelectionRejectsForeignPageIDs() throws {
    let page = ScanPage(sortIndex: 0, originalImagePath: "page.jpg")
    let document = ScanDocument(title: "테스트", pages: [page])
    let foreignID = UUID()

    XCTAssertThrowsError(
      try ScanExportSelection(
        document: document,
        selectedPageIDs: [foreignID]
      )
    ) { error in
      XCTAssertEqual(
        error as? ScanExportSelectionError,
        .pagesNotInDocument([foreignID])
      )
    }
  }
}
