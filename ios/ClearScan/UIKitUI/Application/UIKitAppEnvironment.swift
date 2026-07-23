import Foundation
import SwiftData

@MainActor
final class UIKitAppEnvironment {
  let modelContainer: ModelContainer
  let modelContext: ModelContext
  let imageStore: ScanImageStore
  let repository: ScanLibraryRepository
  let enhancer: DocumentEnhancing
  let pageEditor: DocumentPageEditingService
  let documentAI: OnDeviceDocumentAI

  init(
    modelContainer: ModelContainer? = nil,
    imageStore: ScanImageStore? = nil,
    enhancer: DocumentEnhancing = LocalDocumentEnhancer(),
    pageEditor: DocumentPageEditingService? = nil,
    documentAI: OnDeviceDocumentAI = OnDeviceDocumentAI()
  ) throws {
    let container =
      try modelContainer
      ?? ModelContainer(
        for: ScanFolder.self,
        ScanDocument.self,
        ScanPage.self
      )
    let store = try imageStore ?? ScanImageStore()
    self.modelContainer = container
    modelContext = container.mainContext
    self.imageStore = store
    repository = ScanLibraryRepository(context: container.mainContext, imageStore: store)
    self.enhancer = enhancer
    self.pageEditor = pageEditor ?? DocumentPageEditingService(enhancer: enhancer)
    self.documentAI = documentAI
    try seedFoldersIfNeeded()
    #if DEBUG
      if ProcessInfo.processInfo.environment["CLEARSCAN_SEED_SAMPLE"] == "1" {
        try DebugSampleDataSeeder.seedIfNeeded(in: self)
      }
    #endif
  }

  func fetchFolders() throws -> [ScanFolder] {
    let descriptor = FetchDescriptor<ScanFolder>(
      sortBy: [SortDescriptor(\.createdAt, order: .forward)]
    )
    return try modelContext.fetch(descriptor)
  }

  private func seedFoldersIfNeeded() throws {
    guard try modelContext.fetchCount(FetchDescriptor<ScanFolder>()) == 0 else { return }
    for name in ["학습 자료", "영수증", "개인 문서"] {
      _ = try repository.createFolder(name: name)
    }
  }
}
