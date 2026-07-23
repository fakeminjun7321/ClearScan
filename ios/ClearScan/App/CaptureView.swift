import Combine
import SwiftData
import SwiftUI
import UIKit

private struct PendingScanPage: Identifiable {
    let id = UUID()
    let image: CGImage
    let side: CapturedPageSide
}

struct CaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var services: AppServices

    let folder: ScanFolder

    @StateObject private var scanner = DocumentScannerModel()
    @AppStorage("capture.auto") private var automaticCapture = true
    @AppStorage("capture.silent") private var silentPreferred = true
    @AppStorage("capture.defaultCorrection") private var storedCorrection = ScanCorrectionPreset.document.rawValue

    @State private var pendingPages: [PendingScanPage] = []
    @State private var correction = ScanCorrectionPreset.document
    @State private var lastResultID: UUID?
    @State private var latestBookTimestamp: Date?
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                DocumentCameraPreview(scanner: scanner)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    statusPill
                        .padding(.top, 10)
                    Spacer()
                    captureControls
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationTitle(folder.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { saveDocument() }
                        .disabled(pendingPages.isEmpty || isSaving)
                        .foregroundStyle(.white)
                }
            }
        }
        .onAppear {
            correction = ScanCorrectionPreset(rawValue: storedCorrection) ?? .document
            scanner.autoCaptureEnabled = automaticCapture
            scanner.silentCapturePreferred = silentPreferred
            scanner.start()
        }
        .onDisappear { scanner.stop() }
        .onReceive(scanner.$lastResult.compactMap { $0 }) { result in
            integrate(result)
        }
        .onReceive(scanner.$lastError.compactMap { $0 }) { error in
            errorMessage = error.localizedDescription
        }
        .alert("스캔 오류", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "알 수 없는 오류")
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
            Text(statusText)
            if !pendingPages.isEmpty {
                Text("· \(pendingPages.count)페이지")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.62), in: Capsule())
    }

    private var captureControls: some View {
        VStack(spacing: 14) {
            Picker("촬영 모드", selection: $scanner.captureMode) {
                Text("한 페이지").tag(ScannerCaptureMode.singlePage)
                Text("책 2페이지").tag(ScannerCaptureMode.bookTwoPage)
            }
            .pickerStyle(.segmented)

            if scanner.captureMode == .bookTwoPage {
                VStack(spacing: 5) {
                    HStack {
                        Text("중앙 책등")
                        Spacer()
                        Button("자동") { scanner.manualGutterRatio = nil }
                            .font(.caption.weight(.semibold))
                    }
                    Slider(
                        value: Binding(
                            get: { scanner.manualGutterRatio ?? 0.5 },
                            set: { scanner.manualGutterRatio = $0 }
                        ),
                        in: 0.25...0.75,
                        onEditingChanged: { editing in
                            if !editing, latestBookTimestamp != nil,
                               let ratio = scanner.manualGutterRatio {
                                scanner.resplitLastBook(at: ratio)
                            }
                        }
                    )
                    Text(pendingPages.isEmpty
                         ? "펼친 책의 바깥쪽과 중앙선을 찾습니다."
                         : "다음 펼침면은 \(pendingPages.count + 1)–\(pendingPages.count + 2)페이지로 이어집니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Picker("보정", selection: $correction) {
                    ForEach(ScanCorrectionPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .labelsHidden()

                Spacer()

                if !pendingPages.isEmpty {
                    Button {
                        removeLastCapture()
                    } label: {
                        Label("마지막 제거", systemImage: "arrow.uturn.backward")
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            HStack(alignment: .center) {
                VStack(spacing: 3) {
                    Image(systemName: silentPreferred ? "speaker.slash.fill" : "speaker.wave.2")
                    Text(silentPreferred ? "무음 우선" : "시스템음")
                }
                .font(.caption2)
                .frame(maxWidth: .infinity)

                Button {
                    scanner.capture()
                } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 72, height: 72)
                        Circle().stroke(.black.opacity(0.7), lineWidth: 3).frame(width: 62, height: 62)
                    }
                }
                .disabled(isSaving)
                .accessibilityLabel(scanner.captureMode == .bookTwoPage ? "펼침면 촬영" : "문서 촬영")

                VStack(spacing: 3) {
                    Image(systemName: automaticCapture ? "viewfinder.circle.fill" : "viewfinder.circle")
                    Text(automaticCapture ? "자동 스캔" : "수동 스캔")
                }
                .font(.caption2)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
        .environment(\.colorScheme, .light)
    }

    private var statusText: String {
        switch scanner.phase {
        case .idle: "카메라 준비"
        case .configuring: "카메라 여는 중"
        case .searching: "문서를 찾는 중"
        case let .stabilizing(progress): "고정해 주세요 \(Int(progress * 100))%"
        case .ready: automaticCapture ? "자동 촬영" : "촬영 준비됨"
        case .capturing: "촬영 중"
        case .processing: "페이지 보정 중"
        case .completed: scanner.captureMode == .bookTwoPage ? "다음 펼침면을 촬영하세요" : "페이지 추가 완료"
        case .failed: "다시 시도해 주세요"
        }
    }

    private var statusSymbol: String {
        switch scanner.phase {
        case .ready, .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .capturing, .processing: "wand.and.stars"
        default: "viewfinder"
        }
    }

    private func integrate(_ result: ScannerCaptureResult) {
        guard result.id != lastResultID else { return }
        lastResultID = result.id
        let newPages = result.pages.map {
            PendingScanPage(image: $0.image, side: $0.side)
        }

        if result.mode == .bookTwoPage,
           latestBookTimestamp == result.capturedAt,
           pendingPages.count >= 2 {
            pendingPages.removeLast(2)
            pendingPages.append(contentsOf: newPages)
        } else {
            pendingPages.append(contentsOf: newPages)
        }
        latestBookTimestamp = result.mode == .bookTwoPage ? result.capturedAt : nil
    }

    private func removeLastCapture() {
        let count = scanner.captureMode == .bookTwoPage ? min(2, pendingPages.count) : 1
        pendingPages.removeLast(count)
        latestBookTimestamp = nil
    }

    private func saveDocument() {
        guard !pendingPages.isEmpty else { return }
        isSaving = true
        let repository = services.repository(for: modelContext)
        var createdDocument: ScanDocument?

        do {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "yyyy. M. d. HH:mm 스캔"
            let document = try repository.createDocument(
                title: formatter.string(from: .now),
                in: folder
            )
            createdDocument = document

            for page in pendingPages {
                let data = try services.enhancer.jpegData(
                    for: page.image,
                    preset: correction,
                    compressionQuality: 0.94
                )
                try repository.addPage(
                    to: document,
                    originalImageData: data,
                    originalFileExtension: "jpg"
                )
            }
            storedCorrection = correction.rawValue
            dismiss()
        } catch {
            if let createdDocument {
                try? repository.deleteDocument(createdDocument)
            }
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }
}
