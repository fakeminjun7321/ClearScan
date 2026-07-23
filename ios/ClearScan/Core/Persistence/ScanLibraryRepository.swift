import Foundation
import SwiftData

@MainActor
public final class ScanLibraryRepository {
  private let context: ModelContext
  private let imageStore: ScanImageStoring
  private let now: () -> Date

  public init(
    context: ModelContext,
    imageStore: ScanImageStoring,
    now: @escaping () -> Date = Date.init
  ) {
    self.context = context
    self.imageStore = imageStore
    self.now = now
  }

  @discardableResult
  public func createFolder(name: String) throws -> ScanFolder {
    let timestamp = now()
    let folder = ScanFolder(
      name: normalizedName(name, fallback: "새 폴더"),
      createdAt: timestamp,
      updatedAt: timestamp
    )
    context.insert(folder)
    try context.save()
    return folder
  }

  @discardableResult
  public func createDocument(
    title: String,
    in folder: ScanFolder? = nil
  ) throws -> ScanDocument {
    let timestamp = now()
    let document = ScanDocument(
      title: normalizedName(title, fallback: "새 스캔"),
      createdAt: timestamp,
      updatedAt: timestamp,
      folder: folder
    )
    context.insert(document)
    folder?.updatedAt = timestamp
    try context.save()
    return document
  }

  @discardableResult
  public func addPage(
    to document: ScanDocument,
    originalImageData: Data,
    originalFileExtension: String = "jpg",
    thumbnailData: Data? = nil,
    thumbnailFileExtension: String = "jpg"
  ) throws -> ScanPage {
    let pageID = UUID()
    let timestamp = now()
    let originalPath = try imageStore.save(
      originalImageData,
      documentID: document.id,
      pageID: pageID,
      variant: .original,
      fileExtension: originalFileExtension
    )

    do {
      let thumbnailPath = try thumbnailData.map {
        try imageStore.save(
          $0,
          documentID: document.id,
          pageID: pageID,
          variant: .thumbnail,
          fileExtension: thumbnailFileExtension
        )
      }
      let nextIndex = (document.pages.map(\.sortIndex).max() ?? -1) + 1
      let page = ScanPage(
        id: pageID,
        sortIndex: nextIndex,
        createdAt: timestamp,
        updatedAt: timestamp,
        originalImagePath: originalPath,
        thumbnailImagePath: thumbnailPath,
        document: document
      )
      context.insert(page)
      document.updatedAt = timestamp
      document.folder?.updatedAt = timestamp
      try context.save()
      return page
    } catch {
      try? imageStore.deletePage(documentID: document.id, pageID: pageID)
      throw error
    }
  }

  public func updateEnhancedImage(
    for page: ScanPage,
    data: Data,
    fileExtension: String = "jpg"
  ) throws {
    guard let documentID = page.document?.id else { return }
    let enhancedPath = try imageStore.save(
      data,
      documentID: documentID,
      pageID: page.id,
      variant: .enhanced,
      fileExtension: fileExtension
    )
    let timestamp = now()
    page.enhancedImagePath = enhancedPath
    page.updatedAt = timestamp
    page.document?.updatedAt = timestamp
    page.document?.folder?.updatedAt = timestamp
    try context.save()
  }

  public func resetEnhancedImage(for page: ScanPage) throws {
    if let enhancedPath = page.enhancedImagePath {
      try imageStore.deleteFile(at: enhancedPath)
    }
    let timestamp = now()
    page.enhancedImagePath = nil
    page.updatedAt = timestamp
    page.document?.updatedAt = timestamp
    page.document?.folder?.updatedAt = timestamp
    try context.save()
  }

  public func updateRecognizedText(_ text: String?, for page: ScanPage) throws {
    let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines)
    let timestamp = now()
    page.recognizedText = normalized?.isEmpty == false ? normalized : nil
    page.updatedAt = timestamp
    page.document?.updatedAt = timestamp
    page.document?.folder?.updatedAt = timestamp
    try context.save()
  }

  public func renameDocument(_ document: ScanDocument, title: String) throws {
    let timestamp = now()
    document.title = normalizedName(title, fallback: "새 스캔")
    document.updatedAt = timestamp
    document.folder?.updatedAt = timestamp
    try context.save()
  }

  public func deletePage(_ page: ScanPage) throws {
    guard let document = page.document else {
      context.delete(page)
      try context.save()
      return
    }

    let documentID = document.id
    let pageID = page.id
    let remainingPages = document.sortedPages.filter { $0.id != pageID }
    context.delete(page)
    for (index, remainingPage) in remainingPages.enumerated() {
      remainingPage.sortIndex = index
    }
    document.updatedAt = now()
    try context.save()
    try imageStore.deletePage(documentID: documentID, pageID: pageID)
  }

  public func deleteDocument(_ document: ScanDocument) throws {
    let documentID = document.id
    context.delete(document)
    try context.save()
    try imageStore.deleteDocument(documentID: documentID)
  }

  public func deleteFolder(_ folder: ScanFolder) throws {
    let documentIDs = folder.documents.map(\.id)
    context.delete(folder)
    try context.save()
    for documentID in documentIDs {
      try imageStore.deleteDocument(documentID: documentID)
    }
  }

  private func normalizedName(_ value: String, fallback: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }
}
