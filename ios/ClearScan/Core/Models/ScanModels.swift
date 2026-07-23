import Foundation
import SwiftData

@Model
public final class ScanFolder {
  @Attribute(.unique) public var id: UUID
  public var name: String
  public var createdAt: Date
  public var updatedAt: Date

  @Relationship(deleteRule: .cascade, inverse: \ScanDocument.folder)
  public var documents: [ScanDocument]

  public init(
    id: UUID = UUID(),
    name: String,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    documents: [ScanDocument] = []
  ) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.documents = documents
  }

  public var sortedDocuments: [ScanDocument] {
    documents.sorted { lhs, rhs in
      if lhs.updatedAt == rhs.updatedAt {
        return lhs.createdAt > rhs.createdAt
      }
      return lhs.updatedAt > rhs.updatedAt
    }
  }
}

@Model
public final class ScanDocument {
  @Attribute(.unique) public var id: UUID
  public var title: String
  public var createdAt: Date
  public var updatedAt: Date
  public var folder: ScanFolder?

  @Relationship(deleteRule: .cascade, inverse: \ScanPage.document)
  public var pages: [ScanPage]

  public init(
    id: UUID = UUID(),
    title: String,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    folder: ScanFolder? = nil,
    pages: [ScanPage] = []
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.folder = folder
    self.pages = pages
  }

  public var sortedPages: [ScanPage] {
    pages.sorted { lhs, rhs in
      if lhs.sortIndex == rhs.sortIndex {
        return lhs.createdAt < rhs.createdAt
      }
      return lhs.sortIndex < rhs.sortIndex
    }
  }

  public var pageCount: Int { pages.count }
}

@Model
public final class ScanPage {
  @Attribute(.unique) public var id: UUID
  public var sortIndex: Int
  public var createdAt: Date
  public var updatedAt: Date
  public var originalImagePath: String
  public var enhancedImagePath: String?
  public var thumbnailImagePath: String?
  public var recognizedText: String?
  public var document: ScanDocument?

  public init(
    id: UUID = UUID(),
    sortIndex: Int,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    originalImagePath: String,
    enhancedImagePath: String? = nil,
    thumbnailImagePath: String? = nil,
    recognizedText: String? = nil,
    document: ScanDocument? = nil
  ) {
    self.id = id
    self.sortIndex = sortIndex
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.originalImagePath = originalImagePath
    self.enhancedImagePath = enhancedImagePath
    self.thumbnailImagePath = thumbnailImagePath
    self.recognizedText = recognizedText
    self.document = document
  }

  public var preferredImagePath: String {
    enhancedImagePath ?? originalImagePath
  }
}
