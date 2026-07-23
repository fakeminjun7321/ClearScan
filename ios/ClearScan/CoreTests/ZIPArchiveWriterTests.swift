import Foundation
import XCTest

@testable import ClearScan

final class ZIPArchiveWriterTests: XCTestCase {
  func testWritesLocalHeaderCRCAndEndOfCentralDirectory() throws {
    let archive = try ZIPArchiveWriter().archive(entries: [
      ZIPArchiveEntry(
        path: "hello.txt",
        data: Data("123456789".utf8),
        modificationDate: Date(timeIntervalSince1970: 0)
      )
    ])

    XCTAssertEqual(archive.prefix(4), Data([0x50, 0x4b, 0x03, 0x04]))
    XCTAssertEqual(archive.subdata(in: 14..<18), Data([0x26, 0x39, 0xf4, 0xcb]))
    XCTAssertNotNil(archive.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
    XCTAssertNotNil(archive.range(of: Data([0x50, 0x4b, 0x05, 0x06])))
  }

  func testRejectsUnsafePaths() {
    XCTAssertThrowsError(
      try ZIPArchiveWriter().archive(entries: [
        ZIPArchiveEntry(
          path: "../secret.jpg",
          data: Data([1]),
          modificationDate: .now
        )
      ])
    ) { error in
      XCTAssertEqual(
        error as? ZIPArchiveWriterError,
        .invalidEntryPath("../secret.jpg")
      )
    }
  }
}
