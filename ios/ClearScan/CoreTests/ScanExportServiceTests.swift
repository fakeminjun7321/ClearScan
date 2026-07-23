import Foundation
import UIKit
import XCTest

@testable import ClearScan

final class ScanExportServiceTests: XCTestCase {
  private var temporaryDirectory: URL!
  private var imageStore: ScanImageStore!
  private var selection: ScanExportSelection!
  private let fixedExportID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let imageRoot = temporaryDirectory.appendingPathComponent("images", isDirectory: true)
    imageStore = try ScanImageStore(rootDirectory: imageRoot)

    let documentID = UUID()
    let firstPageID = UUID()
    let secondPageID = UUID()
    let firstPath = try imageStore.save(
      testImageData(color: .red),
      documentID: documentID,
      pageID: firstPageID,
      variant: .original,
      fileExtension: "jpg"
    )
    let secondPath = try imageStore.save(
      testImageData(color: .blue),
      documentID: documentID,
      pageID: secondPageID,
      variant: .original,
      fileExtension: "jpg"
    )
    selection = try ScanExportSelection(
      documentID: documentID,
      documentTitle: "업무/문서",
      pages: [
        ScanExportPage(id: firstPageID, sortIndex: 0, imageRelativePath: firstPath),
        ScanExportPage(id: secondPageID, sortIndex: 1, imageRelativePath: secondPath),
      ]
    )
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory,
      FileManager.default.fileExists(atPath: temporaryDirectory.path)
    {
      try FileManager.default.removeItem(at: temporaryDirectory)
    }
    selection = nil
    imageStore = nil
    temporaryDirectory = nil
  }

  func testExportsSelectedPagesAsJPEGFiles() throws {
    let service = try makeService()

    let result = try service.export(selection, as: .jpeg)

    XCTAssertEqual(result.fileURLs.map(\.lastPathComponent), ["page-001.jpg", "page-002.jpg"])
    for url in result.fileURLs {
      let data = try Data(contentsOf: url)
      XCTAssertEqual(data.prefix(2), Data([0xff, 0xd8]))
    }
  }

  func testExportsARealMultiPagePDF() throws {
    let service = try makeService()

    let result = try service.export(selection, as: .pdf)
    let url = try XCTUnwrap(result.primaryFileURL)
    let data = try Data(contentsOf: url)

    XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
    XCTAssertEqual(result.primaryFileURL?.lastPathComponent, "업무-문서.pdf")
  }

  func testExportsARealZIPWithOneEntryPerPage() throws {
    let service = try makeService()

    let result = try service.export(selection, as: .zip)
    let url = try XCTUnwrap(result.primaryFileURL)
    let data = try Data(contentsOf: url)

    XCTAssertEqual(data.prefix(2), Data([0x50, 0x4b]))
    XCTAssertEqual(countOccurrences(of: Data([0x50, 0x4b, 0x03, 0x04]), in: data), 2)
    XCTAssertNotNil(data.range(of: Data("page-001.jpg".utf8)))
    XCTAssertNotNil(data.range(of: Data("page-002.jpg".utf8)))
  }

  private func makeService() throws -> ScanExportService {
    try ScanExportService(
      imageReader: imageStore,
      exportRootDirectory: temporaryDirectory.appendingPathComponent("exports", isDirectory: true),
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      makeUUID: { self.fixedExportID }
    )
  }

  private func testImageData(color: UIColor) throws -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 180))
    let image = renderer.image { context in
      color.setFill()
      context.cgContext.fill(CGRect(x: 0, y: 0, width: 120, height: 180))
    }
    return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
  }

  private func countOccurrences(of needle: Data, in haystack: Data) -> Int {
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let range = haystack.range(of: needle, in: searchRange) {
      count += 1
      searchRange = range.upperBound..<haystack.endIndex
    }
    return count
  }
}
