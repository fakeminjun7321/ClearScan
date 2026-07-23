import Combine
import Foundation
import SwiftData

@MainActor
final class AppServices: ObservableObject {
    let imageStore: ScanImageStore
    let enhancer: DocumentEnhancing
    let pageEditor: DocumentPageEditingService
    let documentAI: OnDeviceDocumentAI

    init(
        imageStore: ScanImageStore,
        enhancer: DocumentEnhancing = LocalDocumentEnhancer()
    ) {
        self.imageStore = imageStore
        self.enhancer = enhancer
        pageEditor = DocumentPageEditingService(enhancer: enhancer)
        documentAI = OnDeviceDocumentAI()
    }

    func repository(for context: ModelContext) -> ScanLibraryRepository {
        ScanLibraryRepository(context: context, imageStore: imageStore)
    }

    func exportService() throws -> ScanExportService {
        try ScanExportService(imageReader: imageStore)
    }
}
