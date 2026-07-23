import SwiftData
import SwiftUI

@main
struct ClearScanApp: App {
    private let modelContainer: ModelContainer
    @StateObject private var services: AppServices

    init() {
        do {
            let imageStore = try ScanImageStore()
            _services = StateObject(
                wrappedValue: AppServices(imageStore: imageStore)
            )
            modelContainer = try ModelContainer(
                for: ScanFolder.self,
                ScanDocument.self,
                ScanPage.self
            )
        } catch {
            fatalError("ClearScan 저장소 초기화 실패: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services)
        }
        .modelContainer(modelContainer)
    }
}
