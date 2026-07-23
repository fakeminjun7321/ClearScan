import { useEffect, useMemo, useRef, useState } from "react";
import { ArchiveIcon, CheckIcon, DownloadIcon, FileTextIcon, ReloadIcon, UploadIcon } from "@radix-ui/react-icons";

type Folder = { id: string; name: string; count: number; tone: string };
type DocumentRecord = { id: string; folderId: string; title: string; createdAt: string; correction: string; imageUrl: string; pages?: string[]; pageCount?: number };
type ExportFormat = "pdf" | "jpeg" | "zip";
type DriveFormat = ExportFormat | "gdoc";
type UploadState = { documentId: string; title: string; format: DriveFormat; pageIndexes: number[]; progress: number; status: "queued" | "uploading" | "done" | "error"; error?: string; webViewLink?: string };
type DriveFolder = { id: string; name: string };
type DriveUploadResult = { id: string; name: string; mimeType: string; webViewLink?: string };
type WorkspaceTarget = "drive" | "docs";

declare global {
  interface Window {
    google?: {
      accounts: { oauth2: { initTokenClient(options: { client_id: string; scope: string; callback: (response: { access_token?: string; error?: string }) => void; error_callback?: (error: { type?: string }) => void }): { requestAccessToken(): void } } };
    };
  }
}

const configuredApi = (import.meta.env.VITE_CLEARSCAN_API_URL as string | undefined)?.trim();
const currentHostname = window.location.hostname.includes(":") && !window.location.hostname.startsWith("[")
  ? `[${window.location.hostname}]`
  : window.location.hostname;
const apiProtocol = window.location.protocol === "https:" ? "https:" : "http:";
const api = configuredApi ? configuredApi.replace(/\/$/, "") : `${apiProtocol}//${currentHostname}:4174`;
const googleClientId = import.meta.env.VITE_GOOGLE_CLIENT_ID as string | undefined;

function pageCount(document: DocumentRecord) { return document.pageCount ?? document.pages?.length ?? 1; }
function selectedKey(documentId: string, pageIndex: number) { return `${documentId}:${pageIndex}`; }
function driveFormatLabel(format: DriveFormat) { return format === "gdoc" ? "Google Docs" : format.toUpperCase(); }
function workspaceTarget(search: string): WorkspaceTarget | null {
  const value = new URLSearchParams(search).get("workspace");
  return value === "drive" || value === "docs" ? value : null;
}

async function loadGoogleIdentity() {
  if (window.google?.accounts.oauth2) return;
  await new Promise<void>((resolve, reject) => {
    const existing = document.querySelector<HTMLScriptElement>('script[src="https://accounts.google.com/gsi/client"]');
    if (existing) { existing.addEventListener("load", () => resolve(), { once: true }); return; }
    const script = document.createElement("script");
    script.src = "https://accounts.google.com/gsi/client";
    script.async = true;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error("Google 로그인 모듈을 불러오지 못했습니다."));
    document.head.appendChild(script);
  });
}

export default function App() {
  const requestedWorkspace = useMemo(() => workspaceTarget(window.location.search), []);
  const drivePanelRef = useRef<HTMLDivElement>(null);
  const [folders, setFolders] = useState<Folder[]>([]);
  const [documents, setDocuments] = useState<DocumentRecord[]>([]);
  const [folderId, setFolderId] = useState<string>("all");
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [driveToken, setDriveToken] = useState<string | null>(null);
  const [driveFolders, setDriveFolders] = useState<DriveFolder[]>([]);
  const [driveFolderId, setDriveFolderId] = useState("");
  const [driveState, setDriveState] = useState<"idle" | "connecting" | "connected" | "error">("idle");
  const [driveFormat, setDriveFormat] = useState<DriveFormat>("pdf");
  const [uploads, setUploads] = useState<UploadState[]>([]);
  const [highlightWorkspace, setHighlightWorkspace] = useState(Boolean(requestedWorkspace));

  const refresh = async () => {
    setLoading(true);
    setError(null);
    try {
      const [folderResponse, documentResponse] = await Promise.all([fetch(`${api}/api/folders`), fetch(`${api}/api/documents`)]);
      if (!folderResponse.ok || !documentResponse.ok) throw new Error();
      setFolders((await folderResponse.json()).folders);
      setDocuments((await documentResponse.json()).documents);
    } catch {
      setError("ClearScan 로컬 저장 서비스에 연결할 수 없습니다.");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { refresh(); }, []);

  useEffect(() => {
    if (!requestedWorkspace) return;
    const animationFrame = window.requestAnimationFrame(() => {
      drivePanelRef.current?.scrollIntoView({ behavior: "smooth", block: "center" });
      drivePanelRef.current?.focus({ preventScroll: true });
    });
    const timeout = window.setTimeout(() => setHighlightWorkspace(false), 4_000);
    return () => {
      window.cancelAnimationFrame(animationFrame);
      window.clearTimeout(timeout);
    };
  }, [requestedWorkspace]);

  const visibleDocuments = useMemo(() => folderId === "all" ? documents : documents.filter((document) => document.folderId === folderId), [documents, folderId]);
  const selectedItems = useMemo(() => documents.flatMap((document) => {
    const pageIndexes = Array.from({ length: pageCount(document) }, (_, index) => index).filter((index) => selected.has(selectedKey(document.id, index)));
    return pageIndexes.length ? [{ documentId: document.id, pageIndexes }] : [];
  }), [documents, selected]);

  const togglePage = (documentId: string, pageIndex: number) => setSelected((current) => {
    const next = new Set(current);
    const key = selectedKey(documentId, pageIndex);
    if (next.has(key)) next.delete(key); else next.add(key);
    return next;
  });

  const toggleDocument = (document: DocumentRecord) => setSelected((current) => {
    const next = new Set(current);
    const keys = Array.from({ length: pageCount(document) }, (_, index) => selectedKey(document.id, index));
    const every = keys.every((key) => next.has(key));
    keys.forEach((key) => every ? next.delete(key) : next.add(key));
    return next;
  });

  const exportSelection = async (format: ExportFormat, items = selectedItems, download = true) => {
    const response = await fetch(`${api}/api/exports`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ format, items }) });
    if (!response.ok) throw new Error("내보내기에 실패했습니다.");
    const blob = await response.blob();
    if (!download) return blob;
    const disposition = response.headers.get("content-disposition") ?? "";
    const encoded = disposition.match(/filename\*=UTF-8''([^;]+)/)?.[1];
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = encoded ? decodeURIComponent(encoded) : `clearscan-export.${format === "jpeg" && items.reduce((sum, item) => sum + item.pageIndexes.length, 0) === 1 ? "jpg" : format}`;
    link.click();
    window.setTimeout(() => URL.revokeObjectURL(link.href), 1000);
    return blob;
  };

  const connectDrive = async () => {
    if (!googleClientId) return setDriveState("error");
    setDriveState("connecting");
    try {
      await loadGoogleIdentity();
      const token = await new Promise<string>((resolve, reject) => {
        const timeout = window.setTimeout(() => reject(new Error("Google 로그인 창의 응답 시간이 초과되었습니다.")), 30_000);
        const client = window.google!.accounts.oauth2.initTokenClient({
          client_id: googleClientId,
          scope: "https://www.googleapis.com/auth/drive.file",
          callback: (response) => {
            window.clearTimeout(timeout);
            response.access_token ? resolve(response.access_token) : reject(new Error(response.error));
          },
          error_callback: (oauthError) => {
            window.clearTimeout(timeout);
            reject(new Error(oauthError.type ?? "Google 로그인 창을 열지 못했습니다."));
          },
        });
        client.requestAccessToken();
      });
      const response = await fetch("https://www.googleapis.com/drive/v3/files?q=mimeType%3D%27application%2Fvnd.google-apps.folder%27%20and%20trashed%3Dfalse&fields=files(id%2Cname)&orderBy=name", { headers: { Authorization: `Bearer ${token}` } });
      if (!response.ok) throw new Error("Drive 폴더를 읽지 못했습니다.");
      const payload = await response.json();
      setDriveToken(token);
      setDriveFolders(payload.files ?? []);
      const clearScan = (payload.files ?? []).find((folder: DriveFolder) => folder.name === "ClearScan");
      if (clearScan) setDriveFolderId(clearScan.id);
      setDriveState("connected");
    } catch {
      setDriveToken(null);
      setDriveState("error");
    }
  };

  const ensureDriveFolder = async (token: string) => {
    if (driveFolderId) return driveFolderId;
    const response = await fetch("https://www.googleapis.com/drive/v3/files?fields=id,name", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ name: "ClearScan", mimeType: "application/vnd.google-apps.folder" }),
    });
    if (!response.ok) throw new Error("ClearScan Drive 폴더를 만들지 못했습니다.");
    const folder = await response.json();
    setDriveFolders((current) => [...current, folder]);
    setDriveFolderId(folder.id);
    return folder.id as string;
  };

  const uploadBlob = (token: string, folder: string, name: string, blob: Blob, onProgress: (progress: number) => void, convertToGoogleDoc = false) => new Promise<DriveUploadResult>((resolve, reject) => {
    const boundary = `clearscan_${crypto.randomUUID()}`;
    const metadata = JSON.stringify({
      name,
      parents: [folder],
      mimeType: convertToGoogleDoc ? "application/vnd.google-apps.document" : blob.type,
    });
    const body = new Blob([`--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${metadata}\r\n--${boundary}\r\nContent-Type: ${blob.type}\r\n\r\n`, blob, `\r\n--${boundary}--`], { type: `multipart/related; boundary=${boundary}` });
    const request = new XMLHttpRequest();
    const query = new URLSearchParams({ uploadType: "multipart", fields: "id,name,mimeType,webViewLink" });
    if (convertToGoogleDoc) query.set("ocrLanguage", "ko");
    request.open("POST", `https://www.googleapis.com/upload/drive/v3/files?${query}`);
    request.setRequestHeader("Authorization", `Bearer ${token}`);
    request.setRequestHeader("Content-Type", `multipart/related; boundary=${boundary}`);
    request.upload.onprogress = (event) => event.lengthComputable && onProgress(Math.round(event.loaded / event.total * 100));
    request.onload = () => {
      if (request.status < 200 || request.status >= 300) return reject(new Error(`Drive ${request.status}`));
      try { resolve(JSON.parse(request.responseText) as DriveUploadResult); }
      catch { reject(new Error("Drive 응답을 읽지 못했습니다.")); }
    };
    request.onerror = () => reject(new Error("네트워크 오류"));
    request.send(body);
  });

  const uploadDocument = async (document: DocumentRecord, format: DriveFormat = driveFormat, requestedPageIndexes?: number[]) => {
    if (!driveToken) throw new Error("Google Drive 연결이 필요합니다.");
    const pageIndexes = Array.from({ length: pageCount(document) }, (_, index) => index).filter((index) => selected.has(selectedKey(document.id, index)));
    const selectedIndexes = requestedPageIndexes ?? (pageIndexes.length ? pageIndexes : Array.from({ length: pageCount(document) }, (_, index) => index));
    setUploads((current) => current.some((item) => item.documentId === document.id)
      ? current.map((item) => item.documentId === document.id ? { ...item, format, pageIndexes: selectedIndexes, status: "uploading", progress: 0, error: undefined } : item)
      : [...current, { documentId: document.id, title: document.title, format, pageIndexes: selectedIndexes, status: "uploading", progress: 0 }]);
    try {
      const folder = await ensureDriveFolder(driveToken);
      const exportFormat: ExportFormat = format === "gdoc" ? "pdf" : format;
      const exported = await exportSelection(exportFormat, [{ documentId: document.id, pageIndexes: selectedIndexes }], false);
      const extension = format === "pdf" ? "pdf" : format === "jpeg" && selectedIndexes.length === 1 ? "jpg" : "zip";
      const uploadName = format === "gdoc" ? document.title : `${document.title}.${extension}`;
      const result = await uploadBlob(
        driveToken,
        folder,
        uploadName,
        exported,
        (progress) => setUploads((current) => current.map((item) => item.documentId === document.id ? { ...item, progress } : item)),
        format === "gdoc",
      );
      setUploads((current) => current.map((item) => item.documentId === document.id ? { ...item, progress: 100, status: "done", webViewLink: result.webViewLink } : item));
    } catch (uploadError) {
      setUploads((current) => current.map((item) => item.documentId === document.id ? { ...item, status: "error", error: uploadError instanceof Error ? uploadError.message : "업로드 실패" } : item));
    }
  };

  const uploadSelected = async () => {
    const targets = documents.filter((document) => selectedItems.some((item) => item.documentId === document.id));
    const pageIndexesByDocument = new Map(selectedItems.map((item) => [item.documentId, item.pageIndexes]));
    setUploads(targets.map((document) => ({ documentId: document.id, title: document.title, format: driveFormat, pageIndexes: pageIndexesByDocument.get(document.id) ?? [], progress: 0, status: "queued" })));
    for (const document of targets) await uploadDocument(document, driveFormat, pageIndexesByDocument.get(document.id));
  };

  return (
    <div className="web-app">
      <aside>
        <div className="brand"><span><FileTextIcon /></span><div><strong>ClearScan</strong><small>개인 문서 보관함</small></div></div>
        <nav aria-label="폴더">
          <button className={folderId === "all" ? "active" : ""} onClick={() => setFolderId("all")}><ArchiveIcon /><span>모든 문서</span><em>{documents.length}</em></button>
          {folders.map((folder) => <button key={folder.id} className={folderId === folder.id ? "active" : ""} onClick={() => setFolderId(folder.id)}><ArchiveIcon /><span>{folder.name}</span><em>{folder.count}</em></button>)}
        </nav>
        <div
          ref={drivePanelRef}
          className={`drive-panel${highlightWorkspace ? " workspace-target" : ""}`}
          role="region"
          aria-label="Google Workspace 연결"
          data-workspace-target={requestedWorkspace ?? undefined}
          tabIndex={-1}
        >
          <strong>Google Drive</strong>
          <small>{!googleClientId
            ? "OAuth Client ID 환경변수가 필요합니다."
            : requestedWorkspace === "docs"
              ? "Google 연결 후 업로드 형식에서 Google Docs · 편집 가능 OCR을 선택하세요."
              : requestedWorkspace === "drive"
                ? "Google 연결 후 선택한 문서를 ClearScan 폴더로 보낼 수 있습니다."
                : "선택한 문서를 ClearScan 폴더로 보냅니다."}</small>
          <button disabled={driveState === "connecting" || !googleClientId} onClick={connectDrive}>{driveState === "connected" ? <><CheckIcon /> 연결됨</> : driveState === "connecting" ? "연결 중…" : "Google 연결"}</button>
          {driveState === "error" ? <small role="alert">로그인 창을 닫았거나 열지 못했습니다. 다시 시도할 수 있습니다.</small> : null}
          {driveState === "connected" ? <><select aria-label="Google Drive 대상 폴더" value={driveFolderId} onChange={(event) => setDriveFolderId(event.target.value)}><option value="">ClearScan 폴더 자동 생성</option>{driveFolders.map((folder) => <option key={folder.id} value={folder.id}>{folder.name}</option>)}</select><select aria-label="Drive 업로드 형식" value={driveFormat} onChange={(event) => setDriveFormat(event.target.value as DriveFormat)}><option value="pdf">PDF</option><option value="gdoc">Google Docs · 편집 가능 OCR</option><option value="jpeg">JPEG</option><option value="zip">ZIP</option></select></> : null}
        </div>
      </aside>

      <main>
        <header><div><p>보조 웹사이트</p><h1>{folderId === "all" ? "모든 문서" : folders.find((folder) => folder.id === folderId)?.name}</h1></div><button className="refresh" onClick={refresh}><ReloadIcon /> 새로고침</button></header>
        <section className="action-bar">
          <span><strong>{selected.size}</strong>개 페이지 선택</span>
          <div><button disabled={!selected.size} onClick={() => exportSelection("pdf")}><DownloadIcon /> PDF</button><button disabled={!selected.size} onClick={() => exportSelection("jpeg")}>JPEG</button><button disabled={!selected.size} onClick={() => exportSelection("zip")}>ZIP</button><button className="drive-upload" disabled={!selected.size || !driveToken || driveState !== "connected"} onClick={uploadSelected}><UploadIcon /> Drive 업로드</button></div>
        </section>

        {loading ? <div className="state">문서를 불러오는 중…</div> : error ? <div className="state error">{error}</div> : visibleDocuments.length ? (
          <section className="document-grid">
            {visibleDocuments.map((document) => {
              const count = pageCount(document);
              const allSelected = Array.from({ length: count }, (_, index) => selected.has(selectedKey(document.id, index))).every(Boolean);
              return <article key={document.id} className={allSelected ? "selected" : ""}>
                <button className="document-preview" onClick={() => toggleDocument(document)} aria-pressed={allSelected}><img src={`${api}${document.imageUrl}`} alt="" /><span>{allSelected ? <CheckIcon /> : null}</span></button>
                <div className="document-copy"><strong>{document.title}</strong><small>{new Date(document.createdAt).toLocaleString("ko-KR")} · {count}페이지</small></div>
                <div className="page-chips">{Array.from({ length: count }, (_, index) => <button key={index} aria-pressed={selected.has(selectedKey(document.id, index))} onClick={() => togglePage(document.id, index)}>{index + 1}p</button>)}</div>
              </article>;
            })}
          </section>
        ) : <div className="state"><FileTextIcon /><strong>저장된 문서가 없습니다</strong><small>iPhone 또는 iPad 앱에서 스캔한 문서가 여기에 표시됩니다.</small></div>}

        {uploads.length ? <section className="upload-queue"><header><strong>Drive 업로드</strong><small>{uploads.filter((item) => item.status === "done").length}/{uploads.length} 완료</small></header>{uploads.map((item) => <div key={item.documentId}><span><strong>{item.title}</strong><small>{item.status === "error" ? item.error : item.status === "done" ? `${driveFormatLabel(item.format)} 업로드 완료` : `${item.progress}%`}</small></span><progress max="100" value={item.progress} />{item.status === "error" ? <button onClick={() => { const document = documents.find((candidate) => candidate.id === item.documentId); if (document) uploadDocument(document, item.format, item.pageIndexes); }}>재시도</button> : item.webViewLink ? <a href={item.webViewLink} target="_blank" rel="noreferrer">열기</a> : null}</div>)}</section> : null}
      </main>
    </div>
  );
}
