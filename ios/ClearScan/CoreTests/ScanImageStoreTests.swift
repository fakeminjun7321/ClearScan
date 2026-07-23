import Foundation
import XCTest

@testable import ClearScan

final class ScanImageStoreTests: XCTestCase {
  private var temporaryDirectory: URL!
  private var store: ScanImageStore!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    store = try ScanImageStore(rootDirectory: temporaryDirectory)
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory,
      FileManager.default.fileExists(atPath: temporaryDirectory.path)
    {
      try FileManager.default.removeItem(at: temporaryDirectory)
    }
    store = nil
    temporaryDirectory = nil
  }

  func testSaveReadAndDeletePage() throws {
    let documentID = UUID()
    let pageID = UUID()
    let source = Data([0x01, 0x02, 0x03])

    let path = try store.save(
      source,
      documentID: documentID,
      pageID: pageID,
      variant: .original,
      fileExtension: ".jpg"
    )

    XCTAssertEqual(try store.data(for: path), source)
    XCTAssertTrue(FileManager.default.fileExists(atPath: try store.fileURL(for: path).path))

    try store.deletePage(documentID: documentID, pageID: pageID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: try store.fileURL(for: path).path))
  }

  func testDeleteDocumentRemovesAllPageFiles() throws {
    let documentID = UUID()
    let firstPageID = UUID()
    let secondPageID = UUID()
    let firstPath = try store.save(
      Data([1]),
      documentID: documentID,
      pageID: firstPageID,
      variant: .original,
      fileExtension: "png"
    )
    let secondPath = try store.save(
      Data([2]),
      documentID: documentID,
      pageID: secondPageID,
      variant: .enhanced,
      fileExtension: "jpg"
    )

    try store.deleteDocument(documentID: documentID)

    XCTAssertFalse(FileManager.default.fileExists(atPath: try store.fileURL(for: firstPath).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: try store.fileURL(for: secondPath).path))
  }

  func testRejectsTraversalAndUnsupportedExtensions() throws {
    XCTAssertThrowsError(try store.fileURL(for: "../outside.jpg")) { error in
      XCTAssertEqual(
        error as? ScanImageStoreError,
        .invalidRelativePath("../outside.jpg")
      )
    }

    XCTAssertThrowsError(
      try store.save(
        Data(),
        documentID: UUID(),
        pageID: UUID(),
        variant: .original,
        fileExtension: "pdf"
      )
    ) { error in
      XCTAssertEqual(
        error as? ScanImageStoreError,
        .unsupportedFileExtension("pdf")
      )
    }
  }
}
