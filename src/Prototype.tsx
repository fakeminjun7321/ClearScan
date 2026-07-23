import { useCallback, useEffect, useRef, useState } from "react";
import {
  ArchiveIcon,
  ArrowLeftIcon,
  CameraIcon,
  CheckIcon,
  ChevronRightIcon,
  DotsHorizontalIcon,
  FileTextIcon,
  GearIcon,
  MagicWandIcon,
  MixerHorizontalIcon,
  PlusIcon,
  SpeakerOffIcon,
} from "@radix-ui/react-icons";
import { BottomSheet, KeyboardInput, MobileScroll, useKeyboard } from "./mobile";
import { detectBookGutter, detectDocument, drawDocumentDetection, rectifyBookSpread, rectifyDocument, type DocumentDetection } from "./documentDetection";
import { enhanceDocumentImage, type SmartFeature } from "./smartEnhancement";

type Screen = "library" | "camera" | "review" | "folders" | "folderDetail";
type Filter = "original" | "document" | "bw" | "ai";
type CaptureMode = "single" | "book";
type AiMode = "fast" | "quality";
type AiFeature = SmartFeature;
type Folder = { id: string; name: string; count: number; tone: string };
type FolderPickerPurpose = "select" | "save";
type ExportFormat = "pdf" | "jpeg" | "zip";
type ExportItem = { documentId: string; pageIndexes: number[] };
type DocumentRecord = {
  id: string;
  folderId: string;
  title: string;
  createdAt: string;
  correction: Filter;
  imageUrl: string;
  pageCount?: number;
  pages?: string[];
};

const sampleDocument = "/assets/scan-sample.png";
const localApi = "http://127.0.0.1:4174";
const defaultFolders: Folder[] = [
  { id: "study", name: "학습 자료", count: 0, tone: "blue" },
  { id: "receipts", name: "영수증", count: 0, tone: "amber" },
  { id: "personal", name: "개인 문서", count: 0, tone: "violet" },
];

function getInitialScreen(): Screen {
  const requested = new URLSearchParams(window.location.search).get("screen");
  return requested === "camera" || requested === "review" || requested === "folders" || requested === "folderDetail" ? requested : "library";
}

const filterLabels: Array<{ id: Filter; label: string }> = [
  { id: "original", label: "원본" },
  { id: "document", label: "문서" },
  { id: "bw", label: "흑백" },
  { id: "ai", label: "AI 최적화" },
];

const aiFeatureLabels: Array<{ id: AiFeature; label: string; detail: string; recommended?: boolean }> = [
  { id: "shadow", label: "그림자 제거", detail: "가장자리 그림자", recommended: true },
  { id: "deblur", label: "흐림 복원", detail: "흐린 글자 복원", recommended: true },
  { id: "bleed", label: "비침 제거", detail: "뒷면 글자 비침", recommended: true },
  { id: "flatten", label: "곡면 음영 완화", detail: "가장자리 밝기", recommended: true },
  { id: "denoise", label: "노이즈 제거", detail: "종이 얼룩·입자" },
  { id: "upscale", label: "2배 해상도", detail: "작은 글자 확대" },
];

export default function Prototype() {
  const keyboard = useKeyboard();
  const [screen, setScreen] = useState<Screen>(getInitialScreen);
  const [silent, setSilent] = useState(true);
  const [autoScan, setAutoScan] = useState(() => new URLSearchParams(window.location.search).get("auto") !== "off");
  const [filter, setFilter] = useState<Filter>("document");
  const [defaultFilter, setDefaultFilter] = useState<Filter>("document");
  const [captureMode, setCaptureMode] = useState<CaptureMode>("single");
  const [bookCenter, setBookCenter] = useState(0.5);
  const [appendBookCapture, setAppendBookCapture] = useState(false);
  const [capturing, setCapturing] = useState(false);
  const [capturedDocument, setCapturedDocument] = useState(sampleDocument);
  const [capturedPages, setCapturedPages] = useState<string[]>([sampleDocument]);
  const [reviewPageIndex, setReviewPageIndex] = useState(0);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [folderPickerOpen, setFolderPickerOpen] = useState(false);
  const [folderPickerPurpose, setFolderPickerPurpose] = useState<FolderPickerPurpose>("save");
  const [aiDetailsOpen, setAiDetailsOpen] = useState(false);
  const [aiMode, setAiMode] = useState<AiMode>("quality");
  const [aiApplying, setAiApplying] = useState(false);
  const [aiFeatures, setAiFeatures] = useState<Record<AiFeature, boolean>>({
    shadow: true,
    deblur: true,
    bleed: true,
    flatten: true,
    denoise: false,
    upscale: false,
  });
  const [newFolderOpen, setNewFolderOpen] = useState(false);
  const [newFolderName, setNewFolderName] = useState("");
  const [folders, setFolders] = useState<Folder[]>(() => {
    try {
      const saved = window.localStorage.getItem("clearscan-folders");
      if (!saved) return defaultFolders;
      return (JSON.parse(saved) as Array<Partial<Folder> & { name: string }>).map((folder) => ({
        id: folder.id ?? crypto.randomUUID(),
        name: folder.name,
        count: folder.count ?? 0,
        tone: folder.tone ?? "mint",
      }));
    } catch {
      return defaultFolders;
    }
  });
  const [activeFolderId, setActiveFolderId] = useState("study");
  const [savedFolder, setSavedFolder] = useState<string | null>(null);
  const [documents, setDocuments] = useState<DocumentRecord[]>([]);
  const [enhancedDocument, setEnhancedDocument] = useState<string | null>(null);
  const [enhancedPages, setEnhancedPages] = useState<string[] | null>(null);
  const [selectedFolderId, setSelectedFolderId] = useState("study");
  const [storageState, setStorageState] = useState<"checking" | "connected" | "offline">("checking");
  const [saveError, setSaveError] = useState<string | null>(null);
  const selectedAiFeatures = aiFeatureLabels.filter((feature) => aiFeatures[feature.id]).length;
  const captureLockRef = useRef(false);
  const captureTimerRef = useRef<number | null>(null);
  const activeFolder = folders.find((folder) => folder.id === activeFolderId) ?? folders[0];

  useEffect(() => {
    keyboard.hide();
  }, []);

  useEffect(() => {
    window.localStorage.setItem("clearscan-folders", JSON.stringify(folders));
  }, [folders]);

  useEffect(() => {
    Promise.all([
      fetch(`${localApi}/api/folders`).then((response) => response.ok ? response.json() : Promise.reject(new Error("API"))),
      fetch(`${localApi}/api/documents`).then((response) => response.ok ? response.json() : Promise.reject(new Error("API"))),
    ])
      .then(([folderPayload, documentPayload]) => {
        setFolders(folderPayload.folders);
        setDocuments(documentPayload.documents);
        setStorageState("connected");
      })
      .catch(() => setStorageState("offline"));
  }, []);

  const goTo = (next: Screen) => {
    if (next !== "review" && captureTimerRef.current) {
      window.clearTimeout(captureTimerRef.current);
      captureTimerRef.current = null;
      captureLockRef.current = false;
      setCapturing(false);
    }
    keyboard.hide();
    setScreen(next);
  };

  useEffect(() => () => {
    if (captureTimerRef.current) window.clearTimeout(captureTimerRef.current);
  }, []);

  const capture = useCallback((documentUrls?: string | readonly string[]) => {
    if (captureLockRef.current) return;
    captureLockRef.current = true;
    const pages = documentUrls ? (typeof documentUrls === "string" ? [documentUrls] : [...documentUrls]) : [sampleDocument];
    if (captureMode === "book" && appendBookCapture) {
      setCapturedPages((current) => {
        const combined = [...current, ...pages];
        setCapturedDocument(combined[0]);
        setReviewPageIndex(current.length);
        return combined;
      });
    } else {
      setCapturedPages(pages);
      setCapturedDocument(pages[0]);
      setReviewPageIndex(0);
    }
    setAppendBookCapture(false);
    setEnhancedDocument(null);
    setEnhancedPages(null);
    setCapturing(true);
    captureTimerRef.current = window.setTimeout(() => {
      setCapturing(false);
      setFilter(defaultFilter);
      setScreen("review");
      captureLockRef.current = false;
    }, 520);
  }, [appendBookCapture, captureMode, defaultFilter]);

  const chooseFolder = async (folder: Folder) => {
    if (folderPickerPurpose === "select") {
      setActiveFolderId(folder.id);
      setFolderPickerOpen(false);
      return;
    }
    setSaveError(null);
    try {
      const sourcePages = enhancedPages ?? capturedPages;
      const pages = await Promise.all(sourcePages.map(async (source) => {
        if (source.startsWith("data:image/")) return source;
        const blob = await fetch(source).then((response) => response.blob());
        return new Promise<string>((resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => resolve(String(reader.result));
          reader.onerror = () => reject(reader.error);
          reader.readAsDataURL(blob);
        });
      }));
      const response = await fetch(`${localApi}/api/documents`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          folderId: folder.id,
          title: "업무 협조 요청서",
          imageData: pages[0],
          pages,
          correction: filter,
          aiMode: filter === "ai" ? aiMode : null,
          features: filter === "ai" ? aiFeatureLabels.filter((feature) => aiFeatures[feature.id]).map((feature) => feature.id) : [],
        }),
      });
      if (!response.ok) throw new Error("SAVE_FAILED");
      const payload = await response.json();
      setFolders(payload.folders);
      setDocuments((current) => [payload.document, ...current]);
      setStorageState("connected");
      setSavedFolder(folder.name);
      setFolderPickerOpen(false);
      setScreen("library");
    } catch {
      setStorageState("offline");
      setSaveError("로컬 저장 서비스에 연결할 수 없어요.");
    }
  };

  const addFolder = async () => {
    const requestedName = newFolderName.trim() || "새 폴더";
    const existingNames = new Set(folders.map((folder) => folder.name));
    let name = requestedName;
    let suffix = 2;
    while (existingNames.has(name)) name = `${requestedName} ${suffix++}`;
    try {
      const response = await fetch(`${localApi}/api/folders`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name }),
      });
      if (!response.ok) throw new Error("FOLDER_FAILED");
      const payload = await response.json();
      setFolders(payload.folders);
      setStorageState("connected");
    } catch {
      setFolders((current) => [...current, { id: crypto.randomUUID(), name, count: 0, tone: "mint" }]);
      setStorageState("offline");
    }
    setNewFolderName("");
    keyboard.hide();
    setNewFolderOpen(false);
  };

  const toggleAiFeature = (feature: AiFeature) => {
    setAiFeatures((current) => ({ ...current, [feature]: !current[feature] }));
  };

  const applySmartEnhancement = async () => {
    setAiApplying(true);
    try {
      const selected = new Set(aiFeatureLabels.filter((feature) => aiFeatures[feature.id]).map((feature) => feature.id));
      const results = await Promise.all(capturedPages.map((page) => enhanceDocumentImage(page, selected, aiMode)));
      setEnhancedPages(results);
      setEnhancedDocument(results[0]);
      setAiApplying(false);
      setFilter("ai");
      setAiDetailsOpen(false);
    } catch {
      setAiApplying(false);
    }
  };

  const openFolder = (folder: Folder) => {
    setSelectedFolderId(folder.id);
    goTo("folderDetail");
  };

  const openDocument = (document: DocumentRecord | null) => {
    if (document) {
      const pages = (document.pages?.length ? document.pages : [document.imageUrl]).map((page) => page.startsWith("/api/") ? `${localApi}${page}` : page);
      setCapturedPages(pages);
      setCapturedDocument(pages[0]);
      setReviewPageIndex(0);
      setFilter(document.correction);
      setEnhancedDocument(null);
      setEnhancedPages(null);
    }
    goTo("review");
  };

  const startNewScan = (folderId?: string) => {
    if (folderId) setActiveFolderId(folderId);
    setAppendBookCapture(false);
    setCapturedPages([sampleDocument]);
    setCapturedDocument(sampleDocument);
    setEnhancedDocument(null);
    setEnhancedPages(null);
    setReviewPageIndex(0);
    goTo("camera");
  };

  const continueBookScan = () => {
    setAppendBookCapture(true);
    goTo("camera");
  };

  const exportPages = async (items: ExportItem[], format: ExportFormat) => {
    const response = await fetch(`${localApi}/api/exports`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ items, format }),
    });
    if (!response.ok) throw new Error("EXPORT_FAILED");
    const blob = await response.blob();
    const disposition = response.headers.get("content-disposition") ?? "";
    const encodedName = disposition.match(/filename\*=UTF-8''([^;]+)/)?.[1];
    const fallbackName = format === "pdf" ? "clearscan-export.pdf" : format === "jpeg" ? "clearscan-jpeg-pages.zip" : "clearscan-pages.zip";
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = encodedName ? decodeURIComponent(encodedName) : fallbackName;
    link.click();
    window.setTimeout(() => URL.revokeObjectURL(link.href), 1000);
  };

  return (
    <div className={`clearscan-app screen-${screen}`} data-testid="clearscan-app">
      {screen === "camera" ? (
        <CameraScreen
          silent={silent}
          autoScan={autoScan}
          capturing={capturing}
          onBack={() => goTo("library")}
          onToggleSilent={() => setSilent((value) => !value)}
          onToggleAuto={() => setAutoScan((value) => !value)}
          onCapture={capture}
          captureMode={captureMode}
          onCaptureMode={(mode) => {
            keyboard.hide();
            if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
            setCaptureMode(mode);
            window.requestAnimationFrame(() => window.requestAnimationFrame(() => {
              const deviceScreen = document.querySelector<HTMLElement>("[data-phone-screen]");
              if (deviceScreen) {
                deviceScreen.scrollTop = 0;
                deviceScreen.scrollLeft = 0;
              }
            }));
          }}
          bookCenter={bookCenter}
          onBookCenter={setBookCenter}
          bookNextPage={appendBookCapture ? capturedPages.length + 1 : 1}
          paused={settingsOpen || folderPickerOpen}
          folderName={activeFolder?.name ?? "폴더 선택"}
          onChooseFolder={() => { setFolderPickerPurpose("select"); setFolderPickerOpen(true); }}
          onSettings={() => setSettingsOpen(true)}
        />
      ) : null}

      {screen === "library" ? (
        <>
          <MobileScroll className="app-screen light-screen">
            <LibraryScreen
              folders={folders}
              savedFolder={savedFolder}
              storageState={storageState}
              recentDocument={documents[0] ?? null}
              onSettings={() => setSettingsOpen(true)}
              onScan={() => startNewScan()}
              onFolders={() => goTo("folders")}
              onFolder={openFolder}
              onDocument={openDocument}
            />
          </MobileScroll>
          <BottomNav active="library" onLibrary={() => goTo("library")} onScan={() => startNewScan()} onFolders={() => goTo("folders")} />
        </>
      ) : null}

      {screen === "folders" ? (
        <>
          <MobileScroll className="app-screen light-screen">
            <FoldersScreen folders={folders} onAdd={() => setNewFolderOpen(true)} onScan={() => startNewScan()} onFolder={openFolder} />
          </MobileScroll>
          <BottomNav active="folders" onLibrary={() => goTo("library")} onScan={() => startNewScan()} onFolders={() => goTo("folders")} />
        </>
      ) : null}

      {screen === "folderDetail" ? (
        <MobileScroll className="app-screen light-screen">
          <FolderDetailScreen
            folder={folders.find((folder) => folder.id === selectedFolderId) ?? folders[0]}
            documents={documents.filter((document) => document.folderId === selectedFolderId)}
            onBack={() => goTo("folders")}
            onDocument={openDocument}
            onScan={() => startNewScan(selectedFolderId)}
            onExport={exportPages}
          />
        </MobileScroll>
      ) : null}

      {screen === "review" ? (
        <>
          <MobileScroll className="app-screen review-screen">
            <ReviewScreen
              filter={filter}
              documentUrl={(filter === "ai" && enhancedPages ? enhancedPages : capturedPages)[reviewPageIndex] ?? capturedDocument}
              pageCount={capturedPages.length}
              pageIndex={reviewPageIndex}
              onPage={setReviewPageIndex}
              aiMode={aiMode}
              aiFeatureCount={selectedAiFeatures}
              onFilter={setFilter}
              onBack={() => startNewScan()}
              onAiDetails={() => setAiDetailsOpen(true)}
              onContinueBook={captureMode === "book" ? continueBookScan : undefined}
            />
          </MobileScroll>
          <div className="review-footer">
            <button className="secondary-action" type="button" onClick={() => startNewScan()}>
              다시 촬영
            </button>
            <button className="primary-action" data-testid="save-scan" type="button" onClick={() => { setFolderPickerPurpose("save"); setFolderPickerOpen(true); }}>
              폴더에 저장
            </button>
          </div>
        </>
      ) : null}

      <BottomSheet
        open={settingsOpen}
        onOpenChange={setSettingsOpen}
        title="스캔 설정"
        description="자주 쓰는 기능만 간단하게 정리했어요."
        snap={0.56}
      >
        <div className="settings-list">
          <SettingToggle
            icon={<SpeakerOffIcon />}
            label="무음 촬영"
            description="촬영 효과음을 재생하지 않아요."
            checked={silent}
            testId="silent-setting"
            onChange={() => setSilent((value) => !value)}
          />
          <SettingToggle
            icon={<CameraIcon />}
            label="자동 스캔"
            description="문서가 안정되면 자동으로 촬영해요."
            checked={autoScan}
            testId="auto-setting"
            onChange={() => setAutoScan((value) => !value)}
          />
          <div className="setting-block">
            <div className="setting-copy">
              <span className="setting-icon"><MixerHorizontalIcon /></span>
              <span><strong>기본 보정</strong><small>촬영 후 언제든 바꿀 수 있어요.</small></span>
            </div>
            <div className="compact-options" aria-label="기본 보정 선택">
              {filterLabels.slice(0, 3).map((item) => (
                <button
                  className={defaultFilter === item.id ? "is-selected" : ""}
                  key={item.id}
                  type="button"
                  aria-pressed={defaultFilter === item.id}
                  onClick={() => setDefaultFilter(item.id)}
                >
                  {item.label}
                </button>
              ))}
            </div>
          </div>
        </div>
      </BottomSheet>

      <BottomSheet
        open={folderPickerOpen}
        onOpenChange={setFolderPickerOpen}
        title={folderPickerPurpose === "select" ? "촬영 폴더" : "저장할 폴더"}
        description={folderPickerPurpose === "select" ? "스캔을 정리할 폴더를 먼저 골라요." : "나중에 옮길 수도 있어요."}
        snap={0.48}
      >
        <div className="folder-picker-list">
          {folders.map((folder) => (
            <button key={folder.id} type="button" onClick={() => chooseFolder(folder)}>
              <span className={`folder-dot tone-${folder.tone}`}><ArchiveIcon /></span>
              <span>{folder.name}</span>
              <ChevronRightIcon />
            </button>
          ))}
        </div>
        {saveError ? <p className="sheet-error" role="alert">{saveError}</p> : null}
      </BottomSheet>

      <BottomSheet
        open={aiDetailsOpen}
        onOpenChange={setAiDetailsOpen}
        title="AI 스마트 보정"
        description={`${selectedAiFeatures}개 로컬 보정 기능을 선택했어요. 사진은 기기 밖으로 전송되지 않아요.`}
        snap={0.78}
      >
        <div className="ai-mode-selector" aria-label="AI 처리 모드">
          <button
            className={aiMode === "fast" ? "is-selected" : ""}
            type="button"
            aria-pressed={aiMode === "fast"}
            data-testid="ai-mode-fast"
            onClick={() => setAiMode("fast")}
          >
            <strong>빠른 보정</strong><small>가벼운 문서</small>
          </button>
          <button
            className={aiMode === "quality" ? "is-selected" : ""}
            type="button"
            aria-pressed={aiMode === "quality"}
            data-testid="ai-mode-quality"
            onClick={() => setAiMode("quality")}
          >
            <strong>정밀 보정</strong><small>흐림·구김 포함</small>
          </button>
        </div>
        <div className="ai-recommendation-label"><MagicWandIcon /><span>스마트 추천</span><small>필요한 기능만 실행해 배터리와 시간을 아껴요.</small></div>
        <div className="ai-feature-grid">
          {aiFeatureLabels.map((feature) => (
            <button
              className={aiFeatures[feature.id] ? "is-selected" : ""}
              data-testid={`ai-feature-${feature.id}`}
              key={feature.id}
              type="button"
              aria-pressed={aiFeatures[feature.id]}
              onClick={() => toggleAiFeature(feature.id)}
            >
              <span>{aiFeatures[feature.id] ? <CheckIcon /> : <PlusIcon />}</span>
              <strong>{feature.label}</strong>
              <small>{feature.detail}{feature.recommended ? " · 추천" : ""}</small>
            </button>
          ))}
        </div>
        <button className="sheet-primary ai-sheet-primary" data-testid="apply-smart-ai" aria-busy={aiApplying} disabled={aiApplying || selectedAiFeatures === 0} type="button" onClick={applySmartEnhancement}>
          {aiApplying ? "기기에서 보정 중…" : `${selectedAiFeatures}개 스마트 보정 적용`}
        </button>
      </BottomSheet>

      <BottomSheet
        open={newFolderOpen}
        onOpenChange={(open) => { if (!open) keyboard.hide(); setNewFolderOpen(open); }}
        title="새 폴더"
        description="문서를 찾기 쉬운 이름을 붙여주세요."
        snap={0.42}
      >
        <label className="new-folder-field" htmlFor="folder-name">
          <span>폴더 이름</span>
          <KeyboardInput
            id="folder-name"
            data-testid="folder-name-input"
            value={newFolderName}
            onChange={(event) => setNewFolderName(event.currentTarget.value)}
            placeholder="예: 자격증"
          />
        </label>
        <button className="sheet-primary" type="button" onClick={addFolder}>폴더 만들기</button>
      </BottomSheet>
    </div>
  );
}

function LibraryScreen({
  folders,
  savedFolder,
  storageState,
  recentDocument,
  onSettings,
  onScan,
  onFolders,
  onFolder,
  onDocument,
}: {
  folders: Folder[];
  savedFolder: string | null;
  storageState: "checking" | "connected" | "offline";
  recentDocument: DocumentRecord | null;
  onSettings: () => void;
  onScan: () => void;
  onFolders: () => void;
  onFolder: (folder: Folder) => void;
  onDocument: (document: DocumentRecord | null) => void;
}) {
  return (
    <main className="library-content" data-testid="library-screen">
      <header className="app-header">
        <div className="brand-lockup"><span><FileTextIcon /></span><strong>ClearScan</strong></div>
        <div className="header-actions"><span className={`storage-state is-${storageState}`}>{storageState === "connected" ? "로컬 저장 연결" : storageState === "offline" ? "오프라인 임시 저장" : "저장소 확인 중"}</span><button className="icon-button" aria-label="스캔 설정" type="button" onClick={onSettings}><GearIcon /></button></div>
      </header>

      {savedFolder ? (
        <div className="success-banner" role="status"><CheckIcon /> {savedFolder} 폴더에 저장했어요.</div>
      ) : null}

      <button className="scan-hero" data-testid="start-scan" type="button" onClick={onScan}>
        <span className="scan-hero-icon"><CameraIcon /></span>
        <span><strong>새 문서 스캔</strong><small>자동 인식부터 보정까지 한 번에</small></span>
        <ChevronRightIcon />
      </button>

      <section className="content-section">
        <div className="section-heading"><h2>폴더</h2><button type="button" onClick={onFolders}>전체 보기</button></div>
        <div className="folder-list">
          {folders.slice(0, 3).map((folder) => (
            <button key={folder.id} type="button" onClick={() => onFolder(folder)}>
              <span className={`folder-dot tone-${folder.tone}`}><ArchiveIcon /></span>
              <span className="folder-copy"><strong>{folder.name}</strong><small>{folder.count}개 문서</small></span>
              <ChevronRightIcon />
            </button>
          ))}
        </div>
      </section>

      <section className="content-section recent-section">
        <div className="section-heading"><h2>{recentDocument ? "최근 문서" : "스캔 예시"}</h2></div>
        <button className="recent-document" type="button" onClick={() => onDocument(recentDocument)}>
          <img src={recentDocument ? `${localApi}${recentDocument.imageUrl}` : sampleDocument} alt="최근 스캔 문서 미리보기" draggable={false} />
          <span><strong>{recentDocument?.title ?? "업무 협조 요청서"}</strong><small>{recentDocument ? "로컬 저장됨" : "예시 문서"} · {recentDocument?.pageCount ?? 1}페이지 · 문서 보정</small><em>{folders.find((folder) => folder.id === recentDocument?.folderId)?.name ?? "학습 자료"}</em></span>
          <ChevronRightIcon />
        </button>
      </section>
    </main>
  );
}

function FoldersScreen({
  folders,
  onAdd,
  onScan,
  onFolder,
}: {
  folders: Folder[];
  onAdd: () => void;
  onScan: () => void;
  onFolder: (folder: Folder) => void;
}) {
  return (
    <main className="folders-content" data-testid="folders-screen">
      <header className="page-header"><div><p>내 문서</p><h1>폴더</h1></div><button className="add-folder-button" type="button" onClick={onAdd}><PlusIcon /> 새 폴더</button></header>
      <div className="folder-summary"><strong>{folders.length}</strong><span>개 폴더에 문서가 정리되어 있어요.</span></div>
      <section className="folder-list folder-list-large">
        {folders.map((folder) => (
          <button key={folder.id} type="button" onClick={() => onFolder(folder)}>
            <span className={`folder-dot tone-${folder.tone}`}><ArchiveIcon /></span>
            <span className="folder-copy"><strong>{folder.name}</strong><small>{folder.count}개 문서</small></span>
            <DotsHorizontalIcon />
          </button>
        ))}
      </section>
      <button className="empty-scan-link" type="button" onClick={onScan}><CameraIcon /> 문서를 스캔해 새 폴더에 담기</button>
    </main>
  );
}

function FolderDetailScreen({
  folder,
  documents,
  onBack,
  onDocument,
  onScan,
  onExport,
}: {
  folder: Folder | undefined;
  documents: DocumentRecord[];
  onBack: () => void;
  onDocument: (document: DocumentRecord) => void;
  onScan: () => void;
  onExport: (items: ExportItem[], format: ExportFormat) => Promise<void>;
}) {
  const [selecting, setSelecting] = useState(false);
  const [selectedPages, setSelectedPages] = useState<Set<string>>(new Set());
  const [exportState, setExportState] = useState<"idle" | "working" | "done" | "error">("idle");
  if (!folder) return null;

  const pageCountFor = (document: DocumentRecord) => document.pageCount ?? document.pages?.length ?? 1;
  const togglePage = (documentId: string, pageIndex: number) => {
    const key = `${documentId}:${pageIndex}`;
    setSelectedPages((current) => {
      const next = new Set(current);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };
  const toggleDocument = (document: DocumentRecord) => {
    const keys = Array.from({ length: pageCountFor(document) }, (_, index) => `${document.id}:${index}`);
    const allSelected = keys.every((key) => selectedPages.has(key));
    setSelectedPages((current) => {
      const next = new Set(current);
      keys.forEach((key) => allSelected ? next.delete(key) : next.add(key));
      return next;
    });
  };
  const exportItems = documents.flatMap((document) => {
    const pageIndexes = Array.from({ length: pageCountFor(document) }, (_, index) => index).filter((index) => selectedPages.has(`${document.id}:${index}`));
    return pageIndexes.length ? [{ documentId: document.id, pageIndexes }] : [];
  });
  const runExport = async (format: ExportFormat) => {
    if (!exportItems.length) return;
    setExportState("working");
    try {
      await onExport(exportItems, format);
      setExportState("done");
    } catch {
      setExportState("error");
    }
  };

  return (
    <main className="folder-detail-content" data-testid="folder-detail-screen">
      <header className="folder-detail-header">
        <button type="button" aria-label="폴더 목록으로 돌아가기" onClick={onBack}><ArrowLeftIcon /></button>
        <div><p>내 폴더</p><h1>{folder.name}</h1></div>
        <div className="folder-detail-actions">
          {documents.length ? <button type="button" aria-pressed={selecting} onClick={() => { setSelecting((value) => !value); setExportState("idle"); }}>{selecting ? "완료" : "선택"}</button> : null}
          <button className="folder-detail-scan" type="button" onClick={onScan}><CameraIcon /> 스캔</button>
        </div>
      </header>
      <div className="folder-detail-summary"><strong>{documents.length}</strong><span>개 문서가 이 기기에 저장되어 있어요.</span></div>
      {documents.length ? (
        <section className="folder-document-list" aria-label={`${folder.name} 문서 목록`}>
          {documents.map((document) => {
            const preview = document.imageUrl.startsWith("/api/") ? `${localApi}${document.imageUrl}` : document.imageUrl;
            const pageCount = pageCountFor(document);
            const allSelected = Array.from({ length: pageCount }, (_, index) => selectedPages.has(`${document.id}:${index}`)).every(Boolean);
            return (
              <article key={document.id} className={allSelected ? "is-selected" : ""}>
                <button className="folder-document-main" type="button" aria-pressed={selecting ? allSelected : undefined} onClick={() => selecting ? toggleDocument(document) : onDocument(document)}>
                  <img src={preview} alt="" draggable={false} />
                  <span><strong>{document.title}</strong><small>{new Date(document.createdAt).toLocaleDateString("ko-KR")} · {pageCount}페이지</small><em>{document.correction === "ai" ? "AI 최적화" : "문서 보정"}</em></span>
                  {selecting ? <span className="selection-mark">{allSelected ? <CheckIcon /> : <PlusIcon />}</span> : <ChevronRightIcon />}
                </button>
                {selecting && pageCount > 1 ? (
                  <div className="page-selection-row" aria-label={`${document.title} 페이지 선택`}>
                    {Array.from({ length: pageCount }, (_, index) => (
                      <button key={index} type="button" aria-pressed={selectedPages.has(`${document.id}:${index}`)} onClick={() => togglePage(document.id, index)}>{index + 1}p</button>
                    ))}
                  </div>
                ) : null}
              </article>
            );
          })}
        </section>
      ) : (
        <div className="folder-empty-state">
          <span><FileTextIcon /></span>
          <strong>아직 저장된 문서가 없어요</strong>
          <small>이 폴더를 선택한 채 바로 스캔할 수 있어요.</small>
          <button type="button" onClick={onScan}><CameraIcon /> 첫 문서 스캔</button>
        </div>
      )}
      {selecting ? (
        <div className="folder-export-bar">
          <span>{selectedPages.size}개 페이지 선택</span>
          <div><button disabled={!selectedPages.size || exportState === "working"} type="button" onClick={() => runExport("pdf")}>PDF</button><button disabled={!selectedPages.size || exportState === "working"} type="button" onClick={() => runExport("jpeg")}>JPEG</button><button disabled={!selectedPages.size || exportState === "working"} type="button" onClick={() => runExport("zip")}>ZIP</button></div>
          {exportState === "working" ? <small role="status">파일 만드는 중…</small> : exportState === "done" ? <small role="status">내보내기를 시작했어요.</small> : exportState === "error" ? <small role="alert">내보내기에 실패했어요.</small> : null}
        </div>
      ) : null}
    </main>
  );
}

function CameraScreen({
  silent,
  autoScan,
  capturing,
  onBack,
  onToggleSilent,
  onToggleAuto,
  onCapture,
  onSettings,
  paused,
  folderName,
  onChooseFolder,
  captureMode,
  onCaptureMode,
  bookCenter,
  onBookCenter,
  bookNextPage,
}: {
  silent: boolean;
  autoScan: boolean;
  capturing: boolean;
  onBack: () => void;
  onToggleSilent: () => void;
  onToggleAuto: () => void;
  onCapture: (documentUrls?: string | readonly string[]) => void;
  onSettings: () => void;
  paused: boolean;
  folderName: string;
  onChooseFolder: () => void;
  captureMode: CaptureMode;
  onCaptureMode: (mode: CaptureMode) => void;
  bookCenter: number;
  onBookCenter: (center: number) => void;
  bookNextPage: number;
}) {
  const previewRef = useRef<HTMLDivElement>(null);
  const imageRef = useRef<HTMLImageElement>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  const overlayRef = useRef<HTMLCanvasElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const pausedRef = useRef(paused);
  const detectionRef = useRef<DocumentDetection | null>(null);
  const trackerRef = useRef<{ previous: DocumentDetection | null; stableSince: number | null }>({ previous: null, stableSince: null });
  const gutterAnalyzedRef = useRef(false);
  const [detection, setDetection] = useState<DocumentDetection | null>(null);
  const [stable, setStable] = useState(false);
  const [countdown, setCountdown] = useState<number | null>(null);
  const [cameraReady, setCameraReady] = useState(false);
  const [cameraUnavailable, setCameraUnavailable] = useState(false);
  const [pageVisible, setPageVisible] = useState(!document.hidden);
  const [sourceSize, setSourceSize] = useState({ width: 1, height: 1 });
  const query = new URLSearchParams(window.location.search);
  const forceDemoCamera = query.get("camera") === "demo";
  const demoMode = query.has("qa") || forceDemoCamera;

  useEffect(() => { pausedRef.current = paused; }, [paused]);

  const analyzeSource = useCallback((source: HTMLImageElement | HTMLVideoElement) => {
    const next = detectDocument(source);
    detectionRef.current = next;
    setDetection(next);
    const width = source instanceof HTMLVideoElement ? source.videoWidth : source.naturalWidth;
    const height = source instanceof HTMLVideoElement ? source.videoHeight : source.naturalHeight;
    if (width && height) setSourceSize((current) => current.width === width && current.height === height ? current : { width, height });

    const tracker = trackerRef.current;
    const now = performance.now();
    if (!next || next.confidence < 0.72) {
      tracker.previous = next;
      tracker.stableSince = null;
      setStable(false);
      gutterAnalyzedRef.current = false;
      return;
    }

    if (!tracker.previous) {
      tracker.previous = next;
      tracker.stableSince = now;
      setStable(false);
      return;
    }

    const movement = Math.max(...next.corners.map((point, index) => {
      const previous = tracker.previous!.corners[index];
      return Math.hypot(point.x - previous.x, point.y - previous.y);
    }));
    const areaChange = Math.abs(next.coverage - tracker.previous.coverage);
    if (movement > 0.018 || areaChange > 0.045) tracker.stableSince = now;
    else if (tracker.stableSince === null) tracker.stableSince = now;
    tracker.previous = next;
    setStable(now - (tracker.stableSince ?? now) >= 720);
  }, []);

  useEffect(() => {
    const handleVisibility = () => setPageVisible(!document.hidden);
    document.addEventListener("visibilitychange", handleVisibility);
    return () => document.removeEventListener("visibilitychange", handleVisibility);
  }, []);

  useEffect(() => {
    let stopped = false;
    let analysisTimer = 0;
    const startCamera = async () => {
      if (forceDemoCamera) {
        setCameraUnavailable(true);
        return;
      }
      if (!navigator.mediaDevices?.getUserMedia) {
        setCameraUnavailable(true);
        return;
      }
      try {
        const stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: { ideal: "environment" } } });
        if (stopped) {
          stream.getTracks().forEach((track) => track.stop());
          return;
        }
        streamRef.current = stream;
        if (!videoRef.current) return;
        videoRef.current.srcObject = stream;
        await videoRef.current.play();
        setCameraUnavailable(false);
        setCameraReady(true);
        const analyzeNextFrame = () => {
          if (stopped) return;
          if (!pausedRef.current && !document.hidden && videoRef.current?.readyState === HTMLMediaElement.HAVE_ENOUGH_DATA) analyzeSource(videoRef.current);
          analysisTimer = window.setTimeout(analyzeNextFrame, 140);
        };
        analyzeNextFrame();
      } catch {
        setCameraReady(false);
        setCameraUnavailable(true);
      }
    };
    startCamera();
    return () => {
      stopped = true;
      window.clearTimeout(analysisTimer);
      streamRef.current?.getTracks().forEach((track) => track.stop());
      streamRef.current = null;
    };
  }, [analyzeSource, forceDemoCamera]);

  useEffect(() => {
    if (cameraReady || !cameraUnavailable || !demoMode) return;
    const timer = window.setInterval(() => {
      if (!pausedRef.current && !document.hidden && imageRef.current?.complete) analyzeSource(imageRef.current);
    }, 160);
    return () => window.clearInterval(timer);
  }, [analyzeSource, cameraReady, cameraUnavailable, demoMode]);

  useEffect(() => {
    const preview = previewRef.current;
    const overlay = overlayRef.current;
    if (!preview || !overlay) return;

    if (!detection) {
      const context = overlay.getContext("2d");
      context?.clearRect(0, 0, overlay.width, overlay.height);
      return;
    }

    const draw = () => drawDocumentDetection(overlay, detection, preview.clientWidth, preview.clientHeight, sourceSize.width, sourceSize.height, captureMode === "book", bookCenter);
    draw();
    const observer = new ResizeObserver(draw);
    observer.observe(preview);
    return () => observer.disconnect();
  }, [bookCenter, captureMode, detection, sourceSize]);

  useEffect(() => {
    if (captureMode !== "book" || !stable || gutterAnalyzedRef.current) return;
    const source = cameraReady && videoRef.current?.videoWidth ? videoRef.current : imageRef.current;
    if (!source) return;
    gutterAnalyzedRef.current = true;
    detectBookGutter(source, detectionRef.current).then(onBookCenter).catch(() => { gutterAnalyzedRef.current = false; });
  }, [cameraReady, captureMode, onBookCenter, stable]);

  const performCapture = useCallback(async () => {
    const source = cameraReady && videoRef.current?.videoWidth ? videoRef.current : imageRef.current;
    if (!source) return onCapture();
    if (captureMode === "book") {
      const pages = await rectifyBookSpread(source, detectionRef.current, bookCenter);
      onCapture(pages ?? undefined);
      return;
    }
    onCapture(rectifyDocument(source, detectionRef.current) ?? undefined);
  }, [bookCenter, cameraReady, captureMode, onCapture]);

  const changeCaptureMode = (mode: CaptureMode) => {
    trackerRef.current.stableSince = null;
    setStable(false);
    setCountdown(null);
    gutterAnalyzedRef.current = false;
    onCaptureMode(mode);
  };

  useEffect(() => {
    if (!autoScan || !stable || capturing || paused || !pageVisible) {
      setCountdown(null);
      return;
    }

    const deadline = performance.now() + 2550;
    setCountdown(3);
    const timer = window.setInterval(() => {
      const remaining = deadline - performance.now();
      if (remaining <= 0) {
        window.clearInterval(timer);
        performCapture();
        return;
      }
      setCountdown(Math.max(1, Math.ceil(remaining / 850)));
    }, 100);
    return () => {
      window.clearInterval(timer);
    };
  }, [autoScan, capturing, pageVisible, paused, performCapture, stable]);

  const confidence = detection ? Math.round(detection.confidence * 100) : 0;
  const captureMessage = capturing
    ? "스캔 중…"
    : cameraUnavailable && !demoMode
      ? "카메라 권한을 허용해주세요"
    : countdown
      ? `자동 촬영 ${countdown}`
      : detection && !stable
        ? `프레임 안정화 중 · ${confidence}%`
        : detection
          ? `${captureMode === "book" ? "펼친 책을 찾았어요" : "문서를 찾았어요"} · ${confidence}%`
          : "사각형을 찾는 중…";

  return (
    <main className="camera-screen" data-testid="camera-screen">
      <header className="camera-header">
        <button aria-label="라이브러리로 돌아가기" type="button" onClick={onBack}><ArrowLeftIcon /></button>
        <button className="camera-folder" type="button" onClick={onChooseFolder}><ArchiveIcon /> {folderName} <ChevronRightIcon /></button>
        <button aria-label="촬영 설정" type="button" onClick={onSettings}><DotsHorizontalIcon /></button>
      </header>

      <div className="camera-preview" ref={previewRef}>
        <video ref={videoRef} className={cameraReady ? "is-visible" : ""} muted playsInline aria-label="실시간 후면 카메라 미리보기" />
        <img ref={imageRef} className={cameraReady ? "is-hidden" : ""} onLoad={(event) => analyzeSource(event.currentTarget)} src={sampleDocument} alt="카메라를 사용할 수 없을 때 표시되는 문서 예시" draggable={false} />
        <canvas ref={overlayRef} className="document-detection-overlay" data-testid="document-detection-overlay" aria-label="자동으로 감지된 문서 경계" />
        <div className={`capture-state ${capturing ? "is-capturing" : ""}`} data-testid="capture-state" role="status">
          {captureMessage}
        </div>
      </div>

      <div className="camera-dock">
        <div className="camera-mode-row" role="group" aria-label="촬영 모드">
          <button className={captureMode === "single" ? "is-active" : ""} data-testid="mode-single" type="button" aria-pressed={captureMode === "single"} onClick={() => changeCaptureMode("single")}>한 페이지</button>
          <button className={captureMode === "book" ? "is-active" : ""} data-testid="mode-book" type="button" aria-pressed={captureMode === "book"} onClick={() => changeCaptureMode("book")}>책 2페이지</button>
        </div>
        {captureMode === "book" ? (
          <div className="book-mode-tools">
            <p>다음 저장 순서: {bookNextPage}–{bookNextPage + 1}페이지</p>
            <label>중앙선 <input aria-label="책 중앙선 위치" type="range" min="0.36" max="0.64" step="0.01" value={bookCenter} onChange={(event) => onBookCenter(Number(event.currentTarget.value))} /></label>
          </div>
        ) : null}
        <div className="quick-controls">
          <button className={autoScan ? "is-active" : ""} data-testid="auto-scan-toggle" type="button" aria-pressed={autoScan} onClick={onToggleAuto}><CameraIcon /><span>자동</span></button>
          <button className={silent ? "is-active" : ""} data-testid="silent-toggle" type="button" aria-pressed={silent} onClick={onToggleSilent}><SpeakerOffIcon /><span>무음</span></button>
        </div>
        <div className="shutter-row">
          <span aria-hidden="true" />
          <button className={`shutter-button ${capturing ? "is-capturing" : ""}`} data-testid="capture-button" type="button" aria-label="문서 촬영" onClick={performCapture}><span /></button>
          <span className="offline-cue"><MagicWandIcon /> 기기에서 보정</span>
        </div>
      </div>
    </main>
  );
}

function ReviewScreen({
  filter,
  documentUrl,
  pageCount,
  pageIndex,
  onPage,
  aiMode,
  aiFeatureCount,
  onFilter,
  onBack,
  onAiDetails,
  onContinueBook,
}: {
  filter: Filter;
  documentUrl: string;
  pageCount: number;
  pageIndex: number;
  onPage: (index: number) => void;
  aiMode: AiMode;
  aiFeatureCount: number;
  onFilter: (filter: Filter) => void;
  onBack: () => void;
  onAiDetails: () => void;
  onContinueBook?: () => void;
}) {
  return (
    <main className="review-content" data-testid="review-screen">
      <header className="review-header"><button aria-label="카메라로 돌아가기" type="button" onClick={onBack}><ArrowLeftIcon /></button><h1>스캔 미리보기</h1><span>{pageIndex + 1} / {pageCount}</span></header>
      <section className="document-stage">
        <img className={`review-document filter-${filter}`} data-testid="review-document" src={documentUrl} alt="보정 결과 미리보기" draggable={false} />
        {filter === "ai" ? <span className="ai-badge"><MagicWandIcon /> 오프라인 AI</span> : null}
      </section>

      {pageCount > 1 ? (
        <div className="page-switcher" role="group" aria-label="책 페이지 선택">
          {Array.from({ length: pageCount }, (_, index) => (
            <button key={index} type="button" aria-pressed={pageIndex === index} className={pageIndex === index ? "is-active" : ""} onClick={() => onPage(index)}>
              {index === 0 ? "왼쪽 페이지" : index === 1 ? "오른쪽 페이지" : `${index + 1}페이지`}
            </button>
          ))}
        </div>
      ) : null}

      {onContinueBook ? <button className="continue-book-button" type="button" onClick={onContinueBook}><CameraIcon /> 다음 펼침면 촬영 · {pageCount + 1}–{pageCount + 2}페이지</button> : null}

      <div className="filter-strip" aria-label="보정 방식">
        {filterLabels.map((item) => (
          <button
            className={filter === item.id ? "is-active" : ""}
            data-testid={`filter-${item.id}`}
            key={item.id}
            type="button"
            aria-pressed={filter === item.id}
            onClick={() => item.id === "ai" ? onAiDetails() : onFilter(item.id)}
          >
            {item.label}
          </button>
        ))}
      </div>

      <div className="ai-explanation">
        <span><MagicWandIcon /></span>
        <p>
          <strong>{filter === "ai" ? "로컬 보정이 적용됐어요" : "AI 최적화 프리셋"}</strong>
          <small>{filter === "ai" ? `${aiMode === "quality" ? "정밀" : "빠른"} 모드 · ${aiFeatureCount}개 기능 · 기기에서 처리` : "그림자·흐림·비침·곡면 음영을 선택해 개선합니다."}</small>
        </p>
        <button type="button" onClick={onAiDetails}>{filter === "ai" ? "세부 조정" : "설정"}</button>
      </div>
    </main>
  );
}

function BottomNav({
  active,
  onLibrary,
  onScan,
  onFolders,
}: {
  active: "library" | "folders";
  onLibrary: () => void;
  onScan: () => void;
  onFolders: () => void;
}) {
  return (
    <nav className="bottom-nav" aria-label="주요 메뉴">
      <button className={active === "library" ? "is-active" : ""} data-testid="nav-library" type="button" onClick={onLibrary}><FileTextIcon /><span>문서</span></button>
      <button className="nav-scan" data-testid="nav-scan" type="button" onClick={onScan}><CameraIcon /><span>스캔</span></button>
      <button className={active === "folders" ? "is-active" : ""} data-testid="nav-folders" type="button" onClick={onFolders}><ArchiveIcon /><span>폴더</span></button>
    </nav>
  );
}

function SettingToggle({
  icon,
  label,
  description,
  checked,
  testId,
  onChange,
}: {
  icon: React.ReactNode;
  label: string;
  description: string;
  checked: boolean;
  testId: string;
  onChange: () => void;
}) {
  return (
    <div className="setting-row">
      <div className="setting-copy"><span className="setting-icon">{icon}</span><span><strong>{label}</strong><small>{description}</small></span></div>
      <button className={`switch ${checked ? "is-on" : ""}`} data-testid={testId} type="button" role="switch" aria-checked={checked} onClick={onChange}><span /></button>
    </div>
  );
}
