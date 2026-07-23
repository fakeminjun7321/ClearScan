#if DEBUG
  import SwiftData
  import UIKit

  @MainActor
  enum DebugSampleDataSeeder {
    private static let documentTitle = "UI 테스트 문서"
    private static let pageCount = 2

    static func seedIfNeeded(in environment: UIKitAppEnvironment) throws {
      let folders = try environment.fetchFolders()
      guard let folder = folders.first(where: { $0.name == "학습 자료" }) ?? folders.first else {
        return
      }
      let document: ScanDocument
      if let existingDocument = folder.documents.first(where: { $0.title == documentTitle }) {
        document = existingDocument
      } else {
        document = try environment.repository.createDocument(title: documentTitle, in: folder)
      }

      guard document.pages.count < pageCount else { return }
      for pageNumber in (document.pages.count + 1)...pageCount {
        let imageData = makePageImage(pageNumber: pageNumber)
        _ = try environment.repository.addPage(
          to: document,
          originalImageData: imageData,
          originalFileExtension: "jpg",
          thumbnailData: imageData,
          thumbnailFileExtension: "jpg"
        )
      }
    }

    private static func makePageImage(pageNumber: Int) -> Data {
      let size = CGSize(width: 1_240, height: 1_754)
      let renderer = UIGraphicsImageRenderer(size: size)
      return renderer.jpegData(withCompressionQuality: 0.9) { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: size))

        let border = CGRect(x: 70, y: 70, width: size.width - 140, height: size.height - 140)
        UIColor.systemBlue.setStroke()
        context.cgContext.setLineWidth(8)
        context.stroke(border)

        draw(
          "ClearScan UI Test",
          in: CGRect(x: 130, y: 160, width: size.width - 260, height: 100),
          font: .boldSystemFont(ofSize: 58),
          color: .label
        )
        draw(
          "Sample page \(pageNumber)",
          in: CGRect(x: 130, y: 280, width: size.width - 260, height: 80),
          font: .systemFont(ofSize: 42, weight: .medium),
          color: .systemBlue
        )

        for line in 0..<10 {
          let y = 440 + CGFloat(line * 92)
          let width = line.isMultiple(of: 3) ? size.width - 420 : size.width - 260
          UIColor(white: 0.82, alpha: 1).setFill()
          context.fill(CGRect(x: 130, y: y, width: width, height: 18))
        }

        draw(
          "Generated only when CLEARSCAN_SEED_SAMPLE=1 in DEBUG.",
          in: CGRect(x: 130, y: 1_500, width: size.width - 260, height: 80),
          font: .systemFont(ofSize: 30),
          color: .secondaryLabel
        )
      }
    }

    private static func draw(
      _ text: String,
      in rect: CGRect,
      font: UIFont,
      color: UIColor
    ) {
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
      ]
      text.draw(in: rect, withAttributes: attributes)
    }
  }
#endif
