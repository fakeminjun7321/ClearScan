import Foundation
import UIKit

#if canImport(GoogleSignIn)
  import GoogleSignIn
#endif

enum GoogleWorkspaceUploadFormat: String, CaseIterable, Sendable {
  case drivePDF
  case googleDocsOCR

  var title: String {
    switch self {
    case .drivePDF: "Drive에 PDF 업로드"
    case .googleDocsOCR: "Google Docs OCR로 변환"
    }
  }

  fileprivate var targetMIMEType: String {
    switch self {
    case .drivePDF: "application/pdf"
    case .googleDocsOCR: "application/vnd.google-apps.document"
    }
  }
}

struct GoogleDriveUploadedFile: Decodable, Equatable, Sendable {
  let id: String
  let name: String
  let mimeType: String
  let webViewLink: URL?
}

enum GoogleNativeOAuthAvailability: Equatable, Sendable {
  case ready
  case missingIOSClientID
  case placeholderIOSClientID
  case missingURLScheme(expected: String)
  case googleSignInSDKUnavailable

  var isReady: Bool { self == .ready }

  var userMessage: String {
    switch self {
    case .ready:
      "iOS OAuth 설정이 준비되었습니다. Google 계정 연결 후 직접 업로드할 수 있습니다."
    case .missingIOSClientID, .placeholderIOSClientID:
      "차단됨: 이 앱 번들에 iOS용 Google OAuth Client ID가 없습니다. 기존 Web Client ID는 native 인증에 사용할 수 없습니다. Google Cloud에서 현재 Bundle ID의 iOS Client를 만들고 GOOGLE_IOS_CLIENT_ID를 설정하세요."
    case .missingURLScheme(let expected):
      "차단됨: iOS OAuth callback URL scheme이 없습니다. GOOGLE_IOS_REVERSED_CLIENT_ID를 \(expected)로 설정해야 합니다."
    case .googleSignInSDKUnavailable:
      "차단됨: GoogleSignIn-iOS 패키지가 앱 타깃에 연결되지 않았습니다. SPM 9.0.0의 GoogleSignIn 제품이 필요합니다."
    }
  }
}

enum GoogleWorkspaceServiceError: Error, Equatable {
  case oauthUnavailable(GoogleNativeOAuthAvailability)
  case authorizationFailed(String)
  case notConnected
  case invalidResponse
  case driveAPI(status: Int, message: String)
  case missingExportedPDF
}

extension GoogleWorkspaceServiceError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .oauthUnavailable(let state): state.userMessage
    case .authorizationFailed(let message): "Google 계정 연결 실패: \(message)"
    case .notConnected: "먼저 Google 계정을 연결하세요."
    case .invalidResponse: "Google Drive 응답을 읽지 못했습니다."
    case .driveAPI(let status, let message): "Google Drive 오류 \(status): \(message)"
    case .missingExportedPDF: "선택한 페이지의 PDF를 만들지 못했습니다."
    }
  }
}

@MainActor
protocol GoogleOAuthAuthorizing: AnyObject {
  var availability: GoogleNativeOAuthAvailability { get }
  var signedInEmail: String? { get }
  func accessToken(presenting viewController: UIViewController) async throws -> String
  func signOut()
}

protocol GoogleDriveNetworking: AnyObject {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
  func upload(
    for request: URLRequest,
    body: Data,
    progress: @escaping (Double) -> Void
  ) async throws -> (Data, URLResponse)
}

protocol GoogleDriveUploading: AnyObject {
  func uploadPDF(
    _ data: Data,
    fileName: String,
    format: GoogleWorkspaceUploadFormat,
    accessToken: String,
    progress: @escaping (Double) -> Void
  ) async throws -> GoogleDriveUploadedFile
}

struct GoogleWorkspaceUploadProgress: Equatable, Sendable {
  enum Phase: Equatable, Sendable {
    case preparing
    case uploading
    case completed
  }

  let phase: Phase
  let documentTitle: String
  let completedDocuments: Int
  let totalDocuments: Int
  let fractionCompleted: Double
}

@MainActor
protocol GoogleWorkspaceServicing: AnyObject {
  var availability: GoogleNativeOAuthAvailability { get }
  var isConnected: Bool { get }
  var signedInEmail: String? { get }

  func connect(presenting viewController: UIViewController) async throws
  func signOut()
  func upload(
    selections: [ScanExportSelection],
    format: GoogleWorkspaceUploadFormat,
    imageReader: ScanImageReading,
    presenting viewController: UIViewController,
    progress: @escaping (GoogleWorkspaceUploadProgress) -> Void
  ) async throws -> [GoogleDriveUploadedFile]
}

final class URLSessionGoogleDriveNetwork: GoogleDriveNetworking {
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request)
  }

  func upload(
    for request: URLRequest,
    body: Data,
    progress: @escaping (Double) -> Void
  ) async throws -> (Data, URLResponse) {
    let delegate = UploadProgressDelegate(progress: progress)
    return try await session.upload(for: request, from: body, delegate: delegate)
  }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
  private let progress: (Double) -> Void

  init(progress: @escaping (Double) -> Void) {
    self.progress = progress
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    guard totalBytesExpectedToSend > 0 else { return }
    progress(min(max(Double(totalBytesSent) / Double(totalBytesExpectedToSend), 0), 1))
  }
}

final class GoogleDriveAPIClient: GoogleDriveUploading {
  static let driveFileScope = "https://www.googleapis.com/auth/drive.file"

  private let network: GoogleDriveNetworking
  private let makeBoundary: () -> String
  private let maximumMultipartMediaBytes: Int

  init(
    network: GoogleDriveNetworking = URLSessionGoogleDriveNetwork(),
    makeBoundary: @escaping () -> String = { "ClearScan-\(UUID().uuidString)" },
    maximumMultipartMediaBytes: Int = 5 * 1_024 * 1_024
  ) {
    self.network = network
    self.makeBoundary = makeBoundary
    self.maximumMultipartMediaBytes = maximumMultipartMediaBytes
  }

  func uploadPDF(
    _ data: Data,
    fileName: String,
    format: GoogleWorkspaceUploadFormat,
    accessToken: String,
    progress: @escaping (Double) -> Void
  ) async throws -> GoogleDriveUploadedFile {
    let folderID = try await clearScanFolderID(accessToken: accessToken)
    if data.count > maximumMultipartMediaBytes {
      return try await uploadResumable(
        data,
        fileName: fileName,
        format: format,
        folderID: folderID,
        accessToken: accessToken,
        progress: progress
      )
    }
    return try await uploadMultipart(
      data,
      fileName: fileName,
      format: format,
      folderID: folderID,
      accessToken: accessToken,
      progress: progress
    )
  }

  private func uploadMultipart(
    _ data: Data,
    fileName: String,
    format: GoogleWorkspaceUploadFormat,
    folderID: String,
    accessToken: String,
    progress: @escaping (Double) -> Void
  ) async throws -> GoogleDriveUploadedFile {
    var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")!
    var queryItems = [
      URLQueryItem(name: "uploadType", value: "multipart"),
      URLQueryItem(name: "fields", value: "id,name,mimeType,webViewLink"),
    ]
    if format == .googleDocsOCR {
      queryItems.append(URLQueryItem(name: "ocrLanguage", value: "ko"))
    }
    components.queryItems = queryItems

    let boundary = makeBoundary()
    let metadata: [String: Any] = [
      "name": uploadName(fileName, format: format),
      "mimeType": format.targetMIMEType,
      "parents": [folderID],
    ]
    let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    let body = multipartBody(
      boundary: boundary,
      metadata: metadataData,
      media: data,
      mediaMIMEType: "application/pdf"
    )

    var request = URLRequest(url: components.url!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    let (responseData, response) = try await network.upload(
      for: request,
      body: body,
      progress: progress
    )
    try validate(response: response, data: responseData)
    guard let file = try? JSONDecoder().decode(GoogleDriveUploadedFile.self, from: responseData) else {
      throw GoogleWorkspaceServiceError.invalidResponse
    }
    return file
  }

  private func uploadResumable(
    _ data: Data,
    fileName: String,
    format: GoogleWorkspaceUploadFormat,
    folderID: String,
    accessToken: String,
    progress: @escaping (Double) -> Void
  ) async throws -> GoogleDriveUploadedFile {
    var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")!
    var queryItems = [
      URLQueryItem(name: "uploadType", value: "resumable"),
      URLQueryItem(name: "fields", value: "id,name,mimeType,webViewLink"),
    ]
    if format == .googleDocsOCR {
      queryItems.append(URLQueryItem(name: "ocrLanguage", value: "ko"))
    }
    components.queryItems = queryItems

    var sessionRequest = authorizedRequest(url: components.url!, accessToken: accessToken)
    sessionRequest.httpMethod = "POST"
    sessionRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
    sessionRequest.setValue("application/pdf", forHTTPHeaderField: "X-Upload-Content-Type")
    sessionRequest.setValue(String(data.count), forHTTPHeaderField: "X-Upload-Content-Length")
    sessionRequest.httpBody = try JSONSerialization.data(withJSONObject: [
      "name": uploadName(fileName, format: format),
      "mimeType": format.targetMIMEType,
      "parents": [folderID],
    ], options: [.sortedKeys])

    let (sessionData, sessionResponse) = try await network.data(for: sessionRequest)
    try validate(response: sessionResponse, data: sessionData)
    guard
      let http = sessionResponse as? HTTPURLResponse,
      let location = http.value(forHTTPHeaderField: "Location"),
      let sessionURL = URL(string: location)
    else {
      throw GoogleWorkspaceServiceError.invalidResponse
    }

    var uploadRequest = URLRequest(url: sessionURL)
    uploadRequest.httpMethod = "PUT"
    uploadRequest.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
    uploadRequest.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
    let (responseData, response) = try await network.upload(
      for: uploadRequest,
      body: data,
      progress: progress
    )
    try validate(response: response, data: responseData)
    guard let file = try? JSONDecoder().decode(GoogleDriveUploadedFile.self, from: responseData) else {
      throw GoogleWorkspaceServiceError.invalidResponse
    }
    return file
  }

  private func clearScanFolderID(accessToken: String) async throws -> String {
    var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
    components.queryItems = [
      URLQueryItem(
        name: "q",
        value: "name = 'ClearScan' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
      ),
      URLQueryItem(name: "spaces", value: "drive"),
      URLQueryItem(name: "pageSize", value: "10"),
      URLQueryItem(name: "fields", value: "files(id,name)"),
    ]
    let (listData, listResponse) = try await network.data(
      for: authorizedRequest(url: components.url!, accessToken: accessToken)
    )
    try validate(response: listResponse, data: listData)
    if let existing = try? JSONDecoder().decode(DriveFileList.self, from: listData).files.first {
      return existing.id
    }

    var createRequest = authorizedRequest(
      url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id,name")!,
      accessToken: accessToken
    )
    createRequest.httpMethod = "POST"
    createRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
    createRequest.httpBody = try JSONSerialization.data(withJSONObject: [
      "name": "ClearScan",
      "mimeType": "application/vnd.google-apps.folder",
    ])
    let (createData, createResponse) = try await network.data(for: createRequest)
    try validate(response: createResponse, data: createData)
    guard let folder = try? JSONDecoder().decode(DriveFileReference.self, from: createData) else {
      throw GoogleWorkspaceServiceError.invalidResponse
    }
    return folder.id
  }

  private func authorizedRequest(url: URL, accessToken: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  private func validate(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      throw GoogleWorkspaceServiceError.invalidResponse
    }
    guard 200 ... 299 ~= http.statusCode else {
      let envelope = try? JSONDecoder().decode(DriveErrorEnvelope.self, from: data)
      throw GoogleWorkspaceServiceError.driveAPI(
        status: http.statusCode,
        message: envelope?.error.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
      )
    }
  }

  private func uploadName(_ candidate: String, format: GoogleWorkspaceUploadFormat) -> String {
    let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\0")
    let compact = candidate
      .components(separatedBy: forbidden)
      .joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let base = compact.isEmpty ? "ClearScan 문서" : String(compact.prefix(100))
    return format == .drivePDF && !base.lowercased().hasSuffix(".pdf") ? base + ".pdf" : base
  }

  private func multipartBody(
    boundary: String,
    metadata: Data,
    media: Data,
    mediaMIMEType: String
  ) -> Data {
    var body = Data()
    body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
    body.append(metadata)
    body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(mediaMIMEType)\r\n\r\n".utf8))
    body.append(media)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return body
  }
}

private struct DriveFileList: Decodable {
  let files: [DriveFileReference]
}

private struct DriveFileReference: Decodable {
  let id: String
}

private struct DriveErrorEnvelope: Decodable {
  struct DriveError: Decodable { let message: String }
  let error: DriveError
}

@MainActor
final class GoogleWorkspaceService: GoogleWorkspaceServicing {
  private let authorizer: GoogleOAuthAuthorizing
  private let drive: GoogleDriveUploading
  private var cachedAccessToken: String?

  init(
    authorizer: GoogleOAuthAuthorizing,
    drive: GoogleDriveUploading = GoogleDriveAPIClient()
  ) {
    self.authorizer = authorizer
    self.drive = drive
  }

  convenience init() {
    self.init(authorizer: GoogleSignInAuthorizer())
  }

  var availability: GoogleNativeOAuthAvailability { authorizer.availability }
  var isConnected: Bool { cachedAccessToken != nil }
  var signedInEmail: String? { authorizer.signedInEmail }

  func connect(presenting viewController: UIViewController) async throws {
    guard availability.isReady else {
      throw GoogleWorkspaceServiceError.oauthUnavailable(availability)
    }
    cachedAccessToken = try await authorizer.accessToken(presenting: viewController)
  }

  func signOut() {
    cachedAccessToken = nil
    authorizer.signOut()
  }

  func upload(
    selections: [ScanExportSelection],
    format: GoogleWorkspaceUploadFormat,
    imageReader: ScanImageReading,
    presenting viewController: UIViewController,
    progress: @escaping (GoogleWorkspaceUploadProgress) -> Void
  ) async throws -> [GoogleDriveUploadedFile] {
    guard !selections.isEmpty else { return [] }
    guard availability.isReady else {
      throw GoogleWorkspaceServiceError.oauthUnavailable(availability)
    }
    guard let token = cachedAccessToken else {
      throw GoogleWorkspaceServiceError.notConnected
    }

    let exporter = try ScanExportService(imageReader: imageReader)
    var uploadedFiles: [GoogleDriveUploadedFile] = []
    let total = selections.count

    for (index, selection) in selections.enumerated() {
      progress(GoogleWorkspaceUploadProgress(
        phase: .preparing,
        documentTitle: selection.documentTitle,
        completedDocuments: index,
        totalDocuments: total,
        fractionCompleted: Double(index) / Double(total)
      ))
      let export = try await exportPDF(selection, exporter: exporter)

      do {
        guard let fileURL = export.primaryFileURL else {
          throw GoogleWorkspaceServiceError.missingExportedPDF
        }
        let pdfData = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let uploaded = try await drive.uploadPDF(
          pdfData,
          fileName: selection.documentTitle,
          format: format,
          accessToken: token
        ) { fraction in
          Task { @MainActor in
            progress(GoogleWorkspaceUploadProgress(
              phase: .uploading,
              documentTitle: selection.documentTitle,
              completedDocuments: index,
              totalDocuments: total,
              fractionCompleted: (Double(index) + fraction) / Double(total)
            ))
          }
        }
        uploadedFiles.append(uploaded)
        try? exporter.deleteExport(export)
        progress(GoogleWorkspaceUploadProgress(
          phase: .completed,
          documentTitle: selection.documentTitle,
          completedDocuments: index + 1,
          totalDocuments: total,
          fractionCompleted: Double(index + 1) / Double(total)
        ))
      } catch {
        try? exporter.deleteExport(export)
        throw error
      }
    }
    return uploadedFiles
  }

  private func exportPDF(
    _ selection: ScanExportSelection,
    exporter: ScanExportService
  ) async throws -> ScanExportResult {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result {
          try exporter.export(selection, as: .pdf)
        })
      }
    }
  }
}

@MainActor
final class GoogleSignInAuthorizer: GoogleOAuthAuthorizing {
  private let bundle: Bundle

  init(bundle: Bundle = .main) {
    self.bundle = bundle
  }

  var availability: GoogleNativeOAuthAvailability {
    guard let clientID, !clientID.isEmpty else { return .missingIOSClientID }
    guard !clientID.contains("REQUIRED") && !clientID.contains("PLACEHOLDER") else {
      return .placeholderIOSClientID
    }
    let expectedScheme = reversedClientID(clientID)
    guard registeredURLSchemes.contains(expectedScheme) else {
      return .missingURLScheme(expected: expectedScheme)
    }
    #if canImport(GoogleSignIn)
      return .ready
    #else
      return .googleSignInSDKUnavailable
    #endif
  }

  var signedInEmail: String? {
    #if canImport(GoogleSignIn)
      return GIDSignIn.sharedInstance.currentUser?.profile?.email
    #else
      return nil
    #endif
  }

  func accessToken(presenting viewController: UIViewController) async throws -> String {
    guard availability.isReady else {
      throw GoogleWorkspaceServiceError.oauthUnavailable(availability)
    }
    #if canImport(GoogleSignIn)
      guard let clientID else {
        throw GoogleWorkspaceServiceError.oauthUnavailable(.missingIOSClientID)
      }
      GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
      var user: GIDGoogleUser
      if let currentUser = GIDSignIn.sharedInstance.currentUser {
        user = try await currentUser.refreshTokensIfNeeded()
      } else {
        let result = try await GIDSignIn.sharedInstance.signIn(
          withPresenting: viewController,
          hint: nil,
          additionalScopes: [GoogleDriveAPIClient.driveFileScope]
        )
        user = result.user
      }
      if !(user.grantedScopes ?? []).contains(GoogleDriveAPIClient.driveFileScope) {
        user = try await user.addScopes(
          [GoogleDriveAPIClient.driveFileScope],
          presenting: viewController
        ).user
      }
      user = try await user.refreshTokensIfNeeded()
      return user.accessToken.tokenString
    #else
      throw GoogleWorkspaceServiceError.oauthUnavailable(.googleSignInSDKUnavailable)
    #endif
  }

  func signOut() {
    #if canImport(GoogleSignIn)
      GIDSignIn.sharedInstance.signOut()
    #endif
  }

  private var clientID: String? {
    (bundle.object(forInfoDictionaryKey: "GIDClientID") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var registeredURLSchemes: Set<String> {
    let urlTypes = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
    return Set(urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] })
  }

  private func reversedClientID(_ clientID: String) -> String {
    clientID.split(separator: ".").reversed().joined(separator: ".")
  }
}
