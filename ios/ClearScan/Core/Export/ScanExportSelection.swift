import Foundation

public enum ScanPageImagePreference: Sendable {
  case enhancedIfAvailable
  case original
}

public struct ScanExportPage: Equatable, Sendable {
  public let id: UUID
  public let sortIndex: Int
  public let imageRelativePath: String

  public init(id: UUID, sortIndex: Int, imageRelativePath: String) {
    self.id = id
    self.sortIndex = sortIndex
    self.imageRelativePath = imageRelativePath
  }
}

public struct ScanExportSelection: Equatable, Sendable {
  public let documentID: UUID
  public let documentTitle: String
  public let pages: [ScanExportPage]

  public init(
    documentID: UUID,
    documentTitle: String,
    pages: [ScanExportPage]
  ) throws {
    guard !pages.isEmpty else {
      throw ScanExportSelectionError.noPagesSelected
    }
    self.documentID = documentID
    self.documentTitle = documentTitle
    self.pages = pages.sorted { lhs, rhs in
      if lhs.sortIndex == rhs.sortIndex {
        return lhs.id.uuidString < rhs.id.uuidString
      }
      return lhs.sortIndex < rhs.sortIndex
    }
  }

  /// Passing `nil` exports the whole document. Passing a set exports only
  /// those pages, while retaining the document's page order.
  public init(
    document: ScanDocument,
    selectedPageIDs: Set<UUID>? = nil,
    imagePreference: ScanPageImagePreference = .enhancedIfAvailable
  ) throws {
    let allPages = document.sortedPages
    let selectedPages: [ScanPage]

    if let selectedPageIDs {
      guard !selectedPageIDs.isEmpty else {
        throw ScanExportSelectionError.noPagesSelected
      }
      let availableIDs = Set(allPages.map(\.id))
      let missingIDs = selectedPageIDs.subtracting(availableIDs)
      guard missingIDs.isEmpty else {
        throw ScanExportSelectionError.pagesNotInDocument(
          missingIDs.sorted { $0.uuidString < $1.uuidString }
        )
      }
      selectedPages = allPages.filter { selectedPageIDs.contains($0.id) }
    } else {
      selectedPages = allPages
    }

    let exportPages = selectedPages.map { page in
      let path: String
      switch imagePreference {
      case .enhancedIfAvailable:
        path = page.preferredImagePath
      case .original:
        path = page.originalImagePath
      }
      return ScanExportPage(
        id: page.id,
        sortIndex: page.sortIndex,
        imageRelativePath: path
      )
    }

    try self.init(
      documentID: document.id,
      documentTitle: document.title,
      pages: exportPages
    )
  }
}

public enum ScanExportSelectionError: Error, Equatable {
  case noPagesSelected
  case pagesNotInDocument([UUID])
}
