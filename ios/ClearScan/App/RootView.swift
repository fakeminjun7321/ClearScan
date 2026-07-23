import SwiftData
import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            LibraryContainerView()
                .tabItem { Label("보관함", systemImage: "folder") }

            ScanSettingsView()
                .tabItem { Label("설정", systemImage: "slider.horizontal.3") }
        }
        .tint(.blue)
    }
}

private struct ScanSettingsView: View {
    @AppStorage("capture.auto") private var automaticCapture = true
    @AppStorage("capture.silent") private var silentPreferred = true
    @AppStorage("capture.defaultCorrection") private var defaultCorrection = ScanCorrectionPreset.document.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section("촬영") {
                    Toggle("자동 스캔", isOn: $automaticCapture)
                    Toggle("무음 우선", isOn: $silentPreferred)
                    Text("지역·기기 정책에 따라 iOS 시스템 셔터음은 앱에서 강제로 끌 수 없습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("기본 보정") {
                    Picker("촬영 후 적용", selection: $defaultCorrection) {
                        ForEach(ScanCorrectionPreset.allCases) { preset in
                            Text(preset.title).tag(preset.rawValue)
                        }
                    }
                }

                Section("스마트 보정") {
                    LabeledContent("처리 위치", value: "기기 안")
                    Text("현재는 그림자·대비·노이즈·선명도를 조정하는 로컬 엔진입니다. 전용 Core ML 모델은 같은 처리 인터페이스에 교체할 수 있습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("설정")
        }
    }
}
