import Foundation

public enum ScanImageVariant: String, CaseIterable, Sendable {
  case original
  case enhanced
  case thumbnail
}

public enum ScanImageStoreError: Error, Equatable {
  case unsupportedFileExtension(String)
  case invalidRelativePath(String)
}

public protocol ScanImageReading: AnyObject {
  func data(for relativePath: String) throws -> Data
  func fileURL(for relativePath: String) throws -> URL
}

public protocol ScanImageStoring: ScanImageReading {
  @discardableResult
  func save(
    _ data: Data,
    documentID: UUID,
    pageID: UUID,
    variant: ScanImageVariant,
    fileExtension: String
  ) throws -> String

  func deleteFile(at relativePath: String) throws
  func deletePage(documentID: UUID, pageID: UUID) throws
  func deleteDocument(documentID: UUID) throws
}

/// The store has immutable configuration and uses FileManager's thread-safe
/// APIs. Page writes use unique document/page paths.
public final class ScanImageStore: ScanImageStoring, @unchecked Sendable {
  public let rootDirectory: URL

  private let fileManager: FileManager
  private let supportedExtensions = Set(["jpg", "jpeg", "png", "heic"])

  public init(
    fileManager: FileManager = .default,
    rootDirectory: URL? = nil
  ) throws {
    self.fileManager = fileManager

    if let rootDirectory {
      self.rootDirectory = rootDirectory.standardizedFileURL
    } else {
      let applicationSupport = try fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      self.rootDirectory =
        applicationSupport
        .appendingPathComponent("ClearScan", isDirectory: true)
        .appendingPathComponent("Images", isDirectory: true)
        .standardizedFileURL
    }

    try fileManager.createDirectory(
      at: self.rootDirectory,
      withIntermediateDirectories: true
    )
    try? (self.rootDirectory as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
  }

  @discardableResult
  public func save(
    _ data: Data,
    documentID: UUID,
    pageID: UUID,
    variant: ScanImageVariant,
    fileExtension: String
  ) throws -> String {
    let normalizedExtension =
      fileExtension
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
      .lowercased()
    guard supportedExtensions.contains(normalizedExtension) else {
      throw ScanImageStoreError.unsupportedFileExtension(fileExtension)
    }

    let pageDirectory = pageDirectoryURL(documentID: documentID, pageID: pageID)
    try fileManager.createDirectory(at: pageDirectory, withIntermediateDirectories: true)

    let fileURL =
      pageDirectory
      .appendingPathComponent(variant.rawValue, isDirectory: false)
      .appendingPathExtension(normalizedExtension)
    try data.write(to: fileURL, options: [.atomic])

    return relativePath(for: fileURL)
  }

  public func data(for relativePath: String) throws -> Data {
    try Data(contentsOf: fileURL(for: relativePath), options: [.mappedIfSafe])
  }

  public func fileURL(for relativePath: String) throws -> URL {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
      throw ScanImageStoreError.invalidRelativePath(relativePath)
    }

    let candidate =
      rootDirectory
      .appendingPathComponent(relativePath, isDirectory: false)
      .standardizedFileURL
    let rootPath =
      rootDirectory.path.hasSuffix("/")
      ? rootDirectory.path
      : rootDirectory.path + "/"
    guard candidate.path.hasPrefix(rootPath) else {
      throw ScanImageStoreError.invalidRelativePath(relativePath)
    }
    return candidate
  }

  public func deleteFile(at relativePath: String) throws {
    let url = try fileURL(for: relativePath)
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
  }

  public func deletePage(documentID: UUID, pageID: UUID) throws {
    let directory = pageDirectoryURL(documentID: documentID, pageID: pageID)
    guard fileManager.fileExists(atPath: directory.path) else { return }
    try fileManager.removeItem(at: directory)
    try removeDirectoryIfEmpty(documentDirectoryURL(documentID: documentID))
  }

  public func deleteDocument(documentID: UUID) throws {
    let directory = documentDirectoryURL(documentID: documentID)
    guard fileManager.fileExists(atPath: directory.path) else { return }
    try fileManager.removeItem(at: directory)
  }

  private func documentDirectoryURL(documentID: UUID) -> URL {
    rootDirectory.appendingPathComponent(documentID.uuidString, isDirectory: true)
  }

  private func pageDirectoryURL(documentID: UUID, pageID: UUID) -> URL {
    documentDirectoryURL(documentID: documentID)
      .appendingPathComponent(pageID.uuidString, isDirectory: true)
  }

  private func relativePath(for fileURL: URL) -> String {
    String(fileURL.path.dropFirst(rootDirectory.path.count + 1))
  }

  private func removeDirectoryIfEmpty(_ directory: URL) throws {
    guard fileManager.fileExists(atPath: directory.path) else { return }
    let contents = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    if contents.isEmpty {
      try fileManager.removeItem(at: directory)
    }
  }
}
