import SwiftData
import SwiftUI
import UIKit

struct LibraryContainerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \ScanFolder.createdAt) private var folders: [ScanFolder]

    @State private var selectedFolderID: UUID?
    @State private var scanFolder: ScanFolder?
    @State private var showingNewFolder = false
    @State private var newFolderName = ""

    private var selectedFolder: ScanFolder? {
        folders.first { $0.id == selectedFolderID }
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    folderSidebar
                        .navigationTitle("ClearScan")
                } detail: {
                    if let selectedFolder {
                        FolderDetailView(folder: selectedFolder) {
                            scanFolder = selectedFolder
                        }
                    } else {
                        ContentUnavailableView(
                            "폴더를 선택하세요",
                            systemImage: "folder",
                            description: Text("문서와 페이지를 확인하거나 새 스캔을 시작할 수 있습니다.")
                        )
                    }
                }
            } else {
                NavigationStack {
                    folderPhoneList
                        .navigationTitle("ClearScan")
                        .navigationDestination(for: UUID.self) { folderID in
                            if let folder = folders.first(where: { $0.id == folderID }) {
                                FolderDetailView(folder: folder) {
                                    scanFolder = folder
                                }
                            }
                        }
                }
            }
        }
        .task { seedFoldersIfNeeded() }
        .fullScreenCover(item: $scanFolder) { folder in
            CaptureView(folder: folder)
        }
        .alert("새 폴더", isPresented: $showingNewFolder) {
            TextField("폴더 이름", text: $newFolderName)
            Button("취소", role: .cancel) { newFolderName = "" }
            Button("만들기") { createFolder() }
        } message: {
            Text("스캔 문서를 정리할 폴더 이름을 입력하세요.")
        }
    }

    private var folderSidebar: some View {
        List(selection: $selectedFolderID) {
            Section("내 폴더") {
                ForEach(folders) { folder in
                    Button {
                        selectedFolderID = folder.id
                    } label: {
                        FolderRow(folder: folder)
                    }
                    .buttonStyle(.plain)
                    .tag(folder.id)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewFolder = true } label: {
                    Label("새 폴더", systemImage: "folder.badge.plus")
                }
            }
        }
    }

    private var folderPhoneList: some View {
        List {
            Section {
                Button {
                    scanFolder = folders.first
                } label: {
                    Label("새 문서 스캔", systemImage: "camera.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .disabled(folders.isEmpty)
            }

            Section("내 폴더") {
                ForEach(folders) { folder in
                    NavigationLink(value: folder.id) {
                        FolderRow(folder: folder)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewFolder = true } label: {
                    Label("새 폴더", systemImage: "folder.badge.plus")
                }
            }
        }
    }

    private func seedFoldersIfNeeded() {
        guard folders.isEmpty else {
            selectedFolderID = selectedFolderID ?? folders.first?.id
            return
        }
        ["학습 자료", "영수증", "개인 문서"].forEach {
            modelContext.insert(ScanFolder(name: $0))
        }
        try? modelContext.save()
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        modelContext.insert(ScanFolder(name: name.isEmpty ? "새 폴더" : name))
        try? modelContext.save()
        newFolderName = ""
    }
}

private struct FolderRow: View {
    let folder: ScanFolder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
                .frame(width: 30, height: 30)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name).font(.headline)
                Text("\(folder.documents.count)개 문서")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct FolderDetailView: View {
    @EnvironmentObject private var services: AppServices
    @Bindable var folder: ScanFolder
    let onScan: () -> Void

    @State private var selectedPageIDs = Set<UUID>()
    @State private var shareURLs: [URL] = []
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if folder.documents.isEmpty {
                ContentUnavailableView {
                    Label("문서가 없습니다", systemImage: "doc.viewfinder")
                } description: {
                    Text("카메라로 첫 문서를 스캔해 보세요.")
                } actions: {
                    Button("스캔 시작", action: onScan)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(folder.sortedDocuments) { document in
                            DocumentSelectionCard(
                                document: document,
                                selectedPageIDs: $selectedPageIDs
                            )
                        }
                    }
                    .padding()
                    .padding(.bottom, selectedPageIDs.isEmpty ? 20 : 78)
                }
            }
        }
        .navigationTitle(folder.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onScan) {
                    Label("스캔", systemImage: "camera.viewfinder")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selectedPageIDs.isEmpty {
                ExportBar(selectionCount: selectedPageIDs.count, export: export)
            }
        }
        .sheet(isPresented: Binding(
            get: { !shareURLs.isEmpty },
            set: { if !$0 { shareURLs = [] } }
        )) {
            ShareSheet(activityItems: shareURLs)
        }
        .alert("내보내기 실패", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "알 수 없는 오류")
        }
    }

    private func export(_ format: ScanExportFormat) {
        do {
            let exporter = try services.exportService()
            var outputs: [URL] = []
            for document in folder.sortedDocuments {
                let pageIDs = Set(document.pages.map(\.id)).intersection(selectedPageIDs)
                guard !pageIDs.isEmpty else { continue }
                let selection = try ScanExportSelection(
                    document: document,
                    selectedPageIDs: pageIDs
                )
                outputs.append(contentsOf: try exporter.export(selection, as: format).fileURLs)
            }
            shareURLs = outputs
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DocumentSelectionCard: View {
    @EnvironmentObject private var services: AppServices
    let document: ScanDocument
    @Binding var selectedPageIDs: Set<UUID>

    private var allSelected: Bool {
        !document.pages.isEmpty && document.pages.allSatisfy { selectedPageIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                StoredPageImage(path: document.sortedPages.first?.preferredImagePath)
                    .frame(width: 72, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    Text(document.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text("\(document.pageCount)페이지 · \(document.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    toggleDocument()
                } label: {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                }
                .accessibilityLabel(allSelected ? "문서 선택 해제" : "문서 전체 선택")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Array(document.sortedPages.enumerated()), id: \.element.id) { index, page in
                        Button {
                            togglePage(page.id)
                        } label: {
                            Text("\(index + 1)p")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    selectedPageIDs.contains(page.id) ? Color.blue : Color.secondary.opacity(0.12),
                                    in: Capsule()
                                )
                                .foregroundStyle(selectedPageIDs.contains(page.id) ? .white : .primary)
                        }
                        .accessibilityAddTraits(selectedPageIDs.contains(page.id) ? .isSelected : [])
                    }
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(allSelected ? Color.blue : Color.secondary.opacity(0.18), lineWidth: allSelected ? 2 : 1)
        }
    }

    private func toggleDocument() {
        if allSelected {
            document.pages.forEach { selectedPageIDs.remove($0.id) }
        } else {
            document.pages.forEach { selectedPageIDs.insert($0.id) }
        }
    }

    private func togglePage(_ id: UUID) {
        if selectedPageIDs.contains(id) {
            selectedPageIDs.remove(id)
        } else {
            selectedPageIDs.insert(id)
        }
    }
}

private struct StoredPageImage: View {
    @EnvironmentObject private var services: AppServices
    let path: String?

    var body: some View {
        Group {
            if let path,
               let data = try? services.imageStore.data(for: path),
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.1)
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ExportBar: View {
    let selectionCount: Int
    let export: (ScanExportFormat) -> Void

    var body: some View {
        HStack {
            Text("\(selectionCount)페이지 선택")
                .font(.subheadline.weight(.semibold))
            Spacer()
            ForEach(ScanExportFormat.allCases, id: \.self) { format in
                Button(format.rawValue.uppercased()) { export(format) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}
