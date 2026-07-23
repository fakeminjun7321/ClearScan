import Foundation
import UIKit
import XCTest

@testable import ClearScan

final class GoogleDriveAPIClientTests: XCTestCase {
  func testReusesClearScanFolderAndUploadsPDFAsMultipart() async throws {
    let network = GoogleDriveNetworkStub(
      dataResponses: [
        response(
          url: URL(string: "https://www.googleapis.com/drive/v3/files")!,
          body: #"{"files":[{"id":"folder-existing"}]}"#
        )
      ],
      uploadResponses: [
        response(
          url: URL(string: "https://www.googleapis.com/upload/drive/v3/files")!,
          body: #"{"id":"pdf-1","name":"시험.pdf","mimeType":"application/pdf","webViewLink":"https://drive.google.com/file/d/pdf-1/view"}"#
        )
      ]
    )
    let client = GoogleDriveAPIClient(
      network: network,
      makeBoundary: { "fixed-boundary" }
    )
    let pdf = Data("%PDF-1.7\nClearScan".utf8)

    let file = try await client.uploadPDF(
      pdf,
      fileName: "시험",
      format: .drivePDF,
      accessToken: "test-token",
      progress: { _ in }
    )

    XCTAssertEqual(file.id, "pdf-1")
    XCTAssertEqual(network.dataRequests.count, 1)
    XCTAssertEqual(network.uploadRequests.count, 1)
    let request = try XCTUnwrap(network.uploadRequests.first)
    XCTAssertEqual(request.request.url?.queryValue("uploadType"), "multipart")
    XCTAssertNil(request.request.url?.queryValue("ocrLanguage"))
    XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    XCTAssertEqual(request.request.value(forHTTPHeaderField: "Content-Type"), "multipart/related; boundary=fixed-boundary")
    XCTAssertNotNil(request.body.range(of: pdf))
    let body = String(decoding: request.body, as: UTF8.self)
    XCTAssertTrue(body.contains(#""name":"시험.pdf""#))
    XCTAssertTrue(body.contains(#""parents":["folder-existing"]"#))
  }

  func testCreatesClearScanFolderAndImportsGoogleDocsOCR() async throws {
    let network = GoogleDriveNetworkStub(
      dataResponses: [
        response(
          url: URL(string: "https://www.googleapis.com/drive/v3/files")!,
          body: #"{"files":[]}"#
        ),
        response(
          url: URL(string: "https://www.googleapis.com/drive/v3/files")!,
          body: #"{"id":"folder-created"}"#
        ),
      ],
      uploadResponses: [
        response(
          url: URL(string: "https://www.googleapis.com/upload/drive/v3/files")!,
          body: #"{"id":"doc-1","name":"한글 문서","mimeType":"application/vnd.google-apps.document","webViewLink":"https://docs.google.com/document/d/doc-1/edit"}"#
        )
      ]
    )
    let client = GoogleDriveAPIClient(network: network, makeBoundary: { "docs-boundary" })

    let file = try await client.uploadPDF(
      Data("%PDF-1.7\nOCR".utf8),
      fileName: "한글 문서",
      format: .googleDocsOCR,
      accessToken: "docs-token",
      progress: { _ in }
    )

    XCTAssertEqual(file.mimeType, "application/vnd.google-apps.document")
    XCTAssertEqual(network.dataRequests.count, 2)
    XCTAssertEqual(network.dataRequests[1].httpMethod, "POST")
    XCTAssertTrue(String(decoding: network.dataRequests[1].httpBody ?? Data(), as: UTF8.self).contains("ClearScan"))
    let upload = try XCTUnwrap(network.uploadRequests.first)
    XCTAssertEqual(upload.request.url?.queryValue("uploadType"), "multipart")
    XCTAssertEqual(upload.request.url?.queryValue("ocrLanguage"), "ko")
    let body = String(decoding: upload.body, as: UTF8.self)
      .replacingOccurrences(of: #"\/"#, with: "/")
    XCTAssertTrue(body.contains("application/vnd.google-apps.document"))
    XCTAssertTrue(body.contains(#""parents":["folder-created"]"#))
  }

  func testUsesResumableUploadForLargeGoogleDocsPDF() async throws {
    let sessionURL = URL(string: "https://upload.example.test/session-1")!
    let network = GoogleDriveNetworkStub(
      dataResponses: [
        response(
          url: URL(string: "https://www.googleapis.com/drive/v3/files")!,
          body: #"{"files":[{"id":"folder-existing"}]}"#
        ),
        response(
          url: URL(string: "https://www.googleapis.com/upload/drive/v3/files")!,
          body: "{}",
          headers: ["Location": sessionURL.absoluteString]
        ),
      ],
      uploadResponses: [
        response(
          url: sessionURL,
          body: #"{"id":"doc-large","name":"대용량 문서","mimeType":"application/vnd.google-apps.document","webViewLink":"https://docs.google.com/document/d/doc-large/edit"}"#
        )
      ]
    )
    let client = GoogleDriveAPIClient(network: network, maximumMultipartMediaBytes: 4)
    let pdf = Data("%PDF-large".utf8)
    var progress: [Double] = []

    let file = try await client.uploadPDF(
      pdf,
      fileName: "대용량 문서",
      format: .googleDocsOCR,
      accessToken: "large-token",
      progress: { progress.append($0) }
    )

    XCTAssertEqual(file.id, "doc-large")
    XCTAssertEqual(network.dataRequests.count, 2)
    let sessionRequest = network.dataRequests[1]
    XCTAssertEqual(sessionRequest.url?.queryValue("uploadType"), "resumable")
    XCTAssertEqual(sessionRequest.url?.queryValue("ocrLanguage"), "ko")
    XCTAssertEqual(sessionRequest.value(forHTTPHeaderField: "X-Upload-Content-Type"), "application/pdf")
    XCTAssertEqual(sessionRequest.value(forHTTPHeaderField: "X-Upload-Content-Length"), String(pdf.count))
    let metadata = String(decoding: sessionRequest.httpBody ?? Data(), as: UTF8.self)
      .replacingOccurrences(of: #"\/"#, with: "/")
    XCTAssertTrue(metadata.contains("application/vnd.google-apps.document"))
    XCTAssertTrue(metadata.contains(#""parents":["folder-existing"]"#))

    let upload = try XCTUnwrap(network.uploadRequests.first)
    XCTAssertEqual(upload.request.url, sessionURL)
    XCTAssertEqual(upload.request.httpMethod, "PUT")
    XCTAssertEqual(upload.body, pdf)
    XCTAssertEqual(progress, [0.25, 1])
  }

  private func response(
    url: URL,
    body: String,
    status: Int = 200,
    headers: [String: String] = [:]
  ) -> GoogleDriveNetworkStub.Response {
    GoogleDriveNetworkStub.Response(
      data: Data(body.utf8),
      response: HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
      )!
    )
  }
}

@MainActor
final class GoogleWorkspaceCoordinatorTests: XCTestCase {
  func testCanRetryTheSameSelectionAfterATransportFailure() async throws {
    let authorizer = GoogleAuthorizerStub()
    let drive = RetryDriveUploaderStub()
    let service = GoogleWorkspaceService(authorizer: authorizer, drive: drive)
    let viewController = UIViewController()
    try await service.connect(presenting: viewController)

    let pageID = UUID()
    let selection = try ScanExportSelection(
      documentID: UUID(),
      documentTitle: "재시도 문서",
      pages: [ScanExportPage(id: pageID, sortIndex: 0, imageRelativePath: "page.png")]
    )
    let reader = SingleImageReader()

    do {
      _ = try await service.upload(
        selections: [selection],
        format: .drivePDF,
        imageReader: reader,
        presenting: viewController,
        progress: { _ in }
      )
      XCTFail("The first upload should fail")
    } catch {
      XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
    }

    let files = try await service.upload(
      selections: [selection],
      format: .drivePDF,
      imageReader: reader,
      presenting: viewController,
      progress: { _ in }
    )

    XCTAssertEqual(files.map(\.id), ["retry-success"])
    XCTAssertEqual(drive.attempts, 2)
    XCTAssertEqual(drive.tokens, ["native-token", "native-token"])
    XCTAssertTrue(drive.uploadedPDFs.allSatisfy { $0.starts(with: Data("%PDF".utf8)) })
  }
}

private final class GoogleDriveNetworkStub: GoogleDriveNetworking {
  struct Response {
    let data: Data
    let response: URLResponse
  }

  struct UploadRequest {
    let request: URLRequest
    let body: Data
  }

  private var dataResponses: [Response]
  private var uploadResponses: [Response]
  private(set) var dataRequests: [URLRequest] = []
  private(set) var uploadRequests: [UploadRequest] = []

  init(dataResponses: [Response], uploadResponses: [Response]) {
    self.dataResponses = dataResponses
    self.uploadResponses = uploadResponses
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    dataRequests.append(request)
    let response = dataResponses.removeFirst()
    return (response.data, response.response)
  }

  func upload(
    for request: URLRequest,
    body: Data,
    progress: @escaping (Double) -> Void
  ) async throws -> (Data, URLResponse) {
    uploadRequests.append(UploadRequest(request: request, body: body))
    progress(0.25)
    progress(1)
    let response = uploadResponses.removeFirst()
    return (response.data, response.response)
  }
}

@MainActor
private final class GoogleAuthorizerStub: GoogleOAuthAuthorizing {
  let availability = GoogleNativeOAuthAvailability.ready
  let signedInEmail: String? = "mock@example.com"

  func accessToken(presenting viewController: UIViewController) async throws -> String {
    "native-token"
  }

  func signOut() {}
}

private final class RetryDriveUploaderStub: GoogleDriveUploading {
  private(set) var attempts = 0
  private(set) var tokens: [String] = []
  private(set) var uploadedPDFs: [Data] = []

  func uploadPDF(
    _ data: Data,
    fileName: String,
    format: GoogleWorkspaceUploadFormat,
    accessToken: String,
    progress: @escaping (Double) -> Void
  ) async throws -> GoogleDriveUploadedFile {
    attempts += 1
    tokens.append(accessToken)
    uploadedPDFs.append(data)
    progress(0.5)
    if attempts == 1 {
      throw URLError(.networkConnectionLost)
    }
    progress(1)
    return GoogleDriveUploadedFile(
      id: "retry-success",
      name: fileName + ".pdf",
      mimeType: "application/pdf",
      webViewLink: URL(string: "https://drive.google.com/file/d/retry-success/view")
    )
  }
}

private final class SingleImageReader: ScanImageReading {
  private let imageData: Data = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 96)).pngData {
    context in
    UIColor.white.setFill()
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
    UIColor.black.setFill()
    context.fill(CGRect(x: 8, y: 12, width: 48, height: 4))
  }

  func data(for relativePath: String) throws -> Data { imageData }
  func fileURL(for relativePath: String) throws -> URL { URL(fileURLWithPath: "/dev/null") }
}

private extension URL {
  func queryValue(_ name: String) -> String? {
    URLComponents(url: self, resolvingAgainstBaseURL: false)?
      .queryItems?
      .first { $0.name == name }?
      .value
  }
}
