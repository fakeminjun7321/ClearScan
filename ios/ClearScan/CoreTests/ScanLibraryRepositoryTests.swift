import Foundation
import SwiftData
import XCTest

@testable import ClearScan

@MainActor
final class ScanLibraryRepositoryTests: XCTestCase {
  func testCreatePageAndDeleteDocumentCoordinatesDatabaseAndFiles() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: ScanFolder.self,
      ScanDocument.self,
      ScanPage.self,
      configurations: configuration
    )
    let imageStore = ImageStoreSpy()
    let repository = ScanLibraryRepository(
      context: container.mainContext,
      imageStore: imageStore,
      now: { Date(timeIntervalSince1970: 123) }
    )

    let folder = try repository.createFolder(name: " 학습 자료 ")
    let document = try repository.createDocument(title: "문서", in: folder)
    let page = try repository.addPage(
      to: document,
      originalImageData: Data([1, 2, 3])
    )

    XCTAssertEqual(folder.name, "학습 자료")
    XCTAssertEqual(document.pages.map(\.id), [page.id])
    XCTAssertEqual(imageStore.savedVariants, [.original])

    try repository.deleteDocument(document)

    XCTAssertEqual(imageStore.deletedDocumentIDs, [document.id])
    XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<ScanDocument>()).isEmpty)
    XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<ScanPage>()).isEmpty)
  }

  func testEditingMetadataAndResettingEnhancedImagePersist() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: ScanFolder.self,
      ScanDocument.self,
      ScanPage.self,
      configurations: configuration
    )
    let imageStore = ImageStoreSpy()
    let repository = ScanLibraryRepository(
      context: container.mainContext,
      imageStore: imageStore,
      now: { Date(timeIntervalSince1970: 456) }
    )
    let folder = try repository.createFolder(name: "폴더")
    let document = try repository.createDocument(title: "임시 제목", in: folder)
    folder.updatedAt = Date(timeIntervalSince1970: 0)
    let page = try repository.addPage(
      to: document,
      originalImageData: Data([1, 2, 3])
    )
    folder.updatedAt = Date(timeIntervalSince1970: 0)
    try repository.updateEnhancedImage(for: page, data: Data([4, 5, 6]))
    let enhancedPath = try XCTUnwrap(page.enhancedImagePath)

    XCTAssertEqual(folder.updatedAt, Date(timeIntervalSince1970: 456))

    try repository.updateRecognizedText("  첫 줄\n둘째 줄  ", for: page)
    try repository.renameDocument(document, title: "  새 제목  ")
    try repository.resetEnhancedImage(for: page)

    XCTAssertEqual(page.recognizedText, "첫 줄\n둘째 줄")
    XCTAssertEqual(document.title, "새 제목")
    XCTAssertNil(page.enhancedImagePath)
    XCTAssertEqual(imageStore.deletedFilePaths, [enhancedPath])
  }
}

private final class ImageStoreSpy: ScanImageStoring {
  var savedVariants: [ScanImageVariant] = []
  var deletedDocumentIDs: [UUID] = []
  var deletedFilePaths: [String] = []

  func save(
    _ data: Data,
    documentID: UUID,
    pageID: UUID,
    variant: ScanImageVariant,
    fileExtension: String
  ) throws -> String {
    savedVariants.append(variant)
    return "\(documentID)/\(pageID)/\(variant.rawValue).\(fileExtension)"
  }

  func data(for relativePath: String) throws -> Data { Data() }
  func fileURL(for relativePath: String) throws -> URL { URL(fileURLWithPath: relativePath) }
  func deleteFile(at relativePath: String) throws {
    deletedFilePaths.append(relativePath)
  }
  func deletePage(documentID: UUID, pageID: UUID) throws {}
  func deleteDocument(documentID: UUID) throws {
    deletedDocumentIDs.append(documentID)
  }
}
