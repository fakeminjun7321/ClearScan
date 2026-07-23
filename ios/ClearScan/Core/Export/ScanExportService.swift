import Foundation
import UIKit

public enum ScanExportFormat: String, CaseIterable, Sendable {
  case pdf
  case jpeg
  case zip
}

public struct ScanExportResult: Equatable, Sendable {
  public let format: ScanExportFormat
  public let outputDirectory: URL
  public let fileURLs: [URL]

  public init(
    format: ScanExportFormat,
    outputDirectory: URL,
    fileURLs: [URL]
  ) {
    self.format = format
    self.outputDirectory = outputDirectory
    self.fileURLs = fileURLs
  }

  public var primaryFileURL: URL? { fileURLs.first }
}

public enum ScanExportError: Error, Equatable {
  case invalidImage(String)
  case couldNotEncodeJPEG(String)
  case couldNotCreatePDF
}

/// Instances are immutable after initialization. FileManager is thread-safe,
/// and each export call writes to its own UUID-named directory.
public final class ScanExportService: @unchecked Sendable {
  private let imageReader: ScanImageReading
  private let fileManager: FileManager
  private let exportRootDirectory: URL
  private let jpegCompressionQuality: CGFloat
  private let now: () -> Date
  private let makeUUID: () -> UUID

  public init(
    imageReader: ScanImageReading,
    fileManager: FileManager = .default,
    exportRootDirectory: URL? = nil,
    jpegCompressionQuality: CGFloat = 0.92,
    now: @escaping () -> Date = Date.init,
    makeUUID: @escaping () -> UUID = UUID.init
  ) throws {
    self.imageReader = imageReader
    self.fileManager = fileManager
    self.jpegCompressionQuality = min(max(jpegCompressionQuality, 0), 1)
    self.now = now
    self.makeUUID = makeUUID

    let root =
      exportRootDirectory
      ?? fileManager.temporaryDirectory.appendingPathComponent(
        "ClearScanExports",
        isDirectory: true
      )
    self.exportRootDirectory = root.standardizedFileURL
    try fileManager.createDirectory(
      at: self.exportRootDirectory,
      withIntermediateDirectories: true
    )
  }

  public func export(
    _ selection: ScanExportSelection,
    as format: ScanExportFormat
  ) throws -> ScanExportResult {
    let outputDirectory =
      exportRootDirectory
      .appendingPathComponent(makeUUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    do {
      let fileURLs: [URL]
      switch format {
      case .pdf:
        fileURLs = [try exportPDF(selection, to: outputDirectory)]
      case .jpeg:
        fileURLs = try exportJPEGs(selection, to: outputDirectory)
      case .zip:
        fileURLs = [try exportZIP(selection, to: outputDirectory)]
      }
      return ScanExportResult(
        format: format,
        outputDirectory: outputDirectory,
        fileURLs: fileURLs
      )
    } catch {
      try? fileManager.removeItem(at: outputDirectory)
      throw error
    }
  }

  public func deleteExport(_ result: ScanExportResult) throws {
    guard
      result.outputDirectory.standardizedFileURL.path.hasPrefix(
        exportRootDirectory.path + "/"
      )
    else { return }
    guard fileManager.fileExists(atPath: result.outputDirectory.path) else { return }
    try fileManager.removeItem(at: result.outputDirectory)
  }

  private func exportPDF(
    _ selection: ScanExportSelection,
    to directory: URL
  ) throws -> URL {
    let output = NSMutableData()
    let metadata: [String: Any] = [
      kCGPDFContextTitle as String: selection.documentTitle,
      kCGPDFContextCreator as String: "ClearScan",
    ]
    UIGraphicsBeginPDFContextToData(output, .zero, metadata)

    do {
      for page in selection.pages {
        let image = try image(for: page)
        let pageBounds = pdfPageBounds(for: image.size)
        UIGraphicsBeginPDFPageWithInfo(pageBounds, nil)
        UIColor.white.setFill()
        UIRectFill(pageBounds)
        image.draw(in: aspectFitRect(contentSize: image.size, in: pageBounds))
      }
    } catch {
      UIGraphicsEndPDFContext()
      throw error
    }

    UIGraphicsEndPDFContext()
    let pdfData = output as Data
    guard pdfData.starts(with: Data("%PDF".utf8)) else {
      throw ScanExportError.couldNotCreatePDF
    }

    let url =
      directory
      .appendingPathComponent(safeFileName(selection.documentTitle))
      .appendingPathExtension("pdf")
    try pdfData.write(to: url, options: [.atomic])
    return url
  }

  private func exportJPEGs(
    _ selection: ScanExportSelection,
    to directory: URL
  ) throws -> [URL] {
    try selection.pages.enumerated().map { offset, page in
      let data = try jpegData(for: page)
      let url =
        directory
        .appendingPathComponent(pageFileName(index: offset + 1))
        .appendingPathExtension("jpg")
      try data.write(to: url, options: [.atomic])
      return url
    }
  }

  private func exportZIP(
    _ selection: ScanExportSelection,
    to directory: URL
  ) throws -> URL {
    let modifiedAt = now()
    let entries = try selection.pages.enumerated().map { offset, page in
      ZIPArchiveEntry(
        path: pageFileName(index: offset + 1) + ".jpg",
        data: try jpegData(for: page),
        modificationDate: modifiedAt
      )
    }
    let zipData = try ZIPArchiveWriter().archive(entries: entries)
    let url =
      directory
      .appendingPathComponent(safeFileName(selection.documentTitle))
      .appendingPathExtension("zip")
    try zipData.write(to: url, options: [.atomic])
    return url
  }

  private func image(for page: ScanExportPage) throws -> UIImage {
    let data = try imageReader.data(for: page.imageRelativePath)
    guard let image = UIImage(data: data) else {
      throw ScanExportError.invalidImage(page.imageRelativePath)
    }
    return image
  }

  private func jpegData(for page: ScanExportPage) throws -> Data {
    let image = try image(for: page)
    guard let jpegData = image.jpegData(compressionQuality: jpegCompressionQuality) else {
      throw ScanExportError.couldNotEncodeJPEG(page.imageRelativePath)
    }
    return jpegData
  }

  private func pdfPageBounds(for imageSize: CGSize) -> CGRect {
    let a4Portrait = CGSize(width: 595.2, height: 841.8)
    let pageSize =
      imageSize.width > imageSize.height
      ? CGSize(width: a4Portrait.height, height: a4Portrait.width)
      : a4Portrait
    return CGRect(origin: .zero, size: pageSize)
  }

  private func aspectFitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
    guard contentSize.width > 0, contentSize.height > 0 else { return bounds }
    let scale = min(
      bounds.width / contentSize.width,
      bounds.height / contentSize.height
    )
    let size = CGSize(
      width: contentSize.width * scale,
      height: contentSize.height * scale
    )
    return CGRect(
      x: bounds.midX - size.width / 2,
      y: bounds.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
  }

  private func pageFileName(index: Int) -> String {
    String(format: "page-%03d", index)
  }

  private func safeFileName(_ candidate: String) -> String {
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\0")
    let components = trimmed.components(separatedBy: forbidden)
    let sanitized = components.joined(separator: "-")
    let compact =
      sanitized
      .replacingOccurrences(of: "--", with: "-")
      .trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
    let fallback = compact.isEmpty ? "scan" : compact
    return String(fallback.prefix(80))
  }
}
