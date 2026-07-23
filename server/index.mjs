import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PDFDocument } from "pdf-lib";
import JSZip from "jszip";
import sharp from "sharp";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const dataRoot = process.env.CLEARSCAN_DATA_DIR ? path.resolve(process.env.CLEARSCAN_DATA_DIR) : path.join(projectRoot, "data");
const scanRoot = path.join(dataRoot, "scans");
const databasePath = path.join(dataRoot, "clearscan.json");
const port = Number(process.env.CLEARSCAN_API_PORT || 4174);
const host = process.env.CLEARSCAN_API_HOST || "0.0.0.0";
const allowedOrigins = new Set(
  (process.env.CLEARSCAN_ALLOWED_ORIGINS || "http://localhost:4173,http://127.0.0.1:4173,http://localhost:4175,http://127.0.0.1:4175")
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean),
);
const localWebPorts = new Set(["4173", "4175"]);
const defaultFolders = [
  { id: "study", name: "학습 자료", count: 0, tone: "blue" },
  { id: "receipts", name: "영수증", count: 0, tone: "amber" },
  { id: "personal", name: "개인 문서", count: 0, tone: "violet" },
];

await mkdir(scanRoot, { recursive: true });

async function readDatabase() {
  try {
    const database = JSON.parse(await readFile(databasePath, "utf8"));
    database.folders = database.folders.map((folder) => ({
      ...folder,
      count: database.documents.filter((document) => document.folderId === folder.id).length,
    }));
    return database;
  } catch {
    const initial = { folders: defaultFolders, documents: [] };
    await writeDatabase(initial);
    return initial;
  }
}

async function writeDatabase(database) {
  const temporaryPath = `${databasePath}.tmp`;
  await writeFile(temporaryPath, JSON.stringify(database, null, 2));
  await rename(temporaryPath, databasePath);
}

function send(response, status, payload, contentType = "application/json; charset=utf-8") {
  response.writeHead(status, {
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Allow-Methods": "GET,POST,DELETE,OPTIONS",
    "Cache-Control": "no-store",
    "Content-Type": contentType,
  });
  response.end(contentType.startsWith("application/json") ? JSON.stringify(payload) : payload);
}

function sendFile(response, payload, contentType, fileName) {
  const asciiName = fileName.replace(/[^\x20-\x7E]+/g, "-");
  response.writeHead(200, {
    "Access-Control-Expose-Headers": "Content-Disposition,X-ClearScan-Container",
    "Cache-Control": "no-store",
    "Content-Disposition": `attachment; filename="${asciiName}"; filename*=UTF-8''${encodeURIComponent(fileName)}`,
    "Content-Length": payload.length,
    "Content-Type": contentType,
  });
  response.end(payload);
}

function safeFileName(value) {
  return String(value || "document").replace(/[^a-zA-Z0-9가-힣_-]+/g, "-").slice(0, 48) || "document";
}

async function selectedPages(database, items) {
  if (!Array.isArray(items) || !items.length || items.length > 200) throw new Error("INVALID_SELECTION");
  const pages = [];
  for (const item of items) {
    const document = database.documents.find((candidate) => candidate.id === item.documentId);
    if (!document) throw new Error("DOCUMENT_NOT_FOUND");
    const fileNames = document.fileNames?.length ? document.fileNames : [document.fileName];
    const indexes = Array.isArray(item.pageIndexes) && item.pageIndexes.length
      ? [...new Set(item.pageIndexes.map(Number))]
      : fileNames.map((_, index) => index);
    for (const index of indexes) {
      const fileName = fileNames[index];
      if (!fileName) throw new Error("PAGE_NOT_FOUND");
      pages.push({
        bytes: await readFile(path.join(scanRoot, fileName)),
        document,
        fileName,
        index,
      });
    }
  }
  if (!pages.length || pages.length > 500) throw new Error("INVALID_SELECTION");
  return pages;
}

async function exportPdf(pages) {
  const pdf = await PDFDocument.create();
  for (const page of pages) {
    const extension = path.extname(page.fileName).toLowerCase();
    const bytes = extension === ".jpg" || extension === ".jpeg"
      ? page.bytes
      : extension === ".png"
        ? page.bytes
        : await sharp(page.bytes).png().toBuffer();
    const image = extension === ".jpg" || extension === ".jpeg" ? await pdf.embedJpg(bytes) : await pdf.embedPng(bytes);
    const landscape = image.width > image.height;
    const pageSize = landscape ? [841.89, 595.28] : [595.28, 841.89];
    const pdfPage = pdf.addPage(pageSize);
    const scale = Math.min((pageSize[0] - 36) / image.width, (pageSize[1] - 36) / image.height);
    const width = image.width * scale;
    const height = image.height * scale;
    pdfPage.drawImage(image, { x: (pageSize[0] - width) / 2, y: (pageSize[1] - height) / 2, width, height });
  }
  return Buffer.from(await pdf.save());
}

async function exportJpegs(pages) {
  const converted = await Promise.all(pages.map(async (page) => ({
    ...page,
    bytes: await sharp(page.bytes).jpeg({ quality: 92, chromaSubsampling: "4:4:4" }).toBuffer(),
  })));
  if (converted.length === 1) return { bytes: converted[0].bytes, contentType: "image/jpeg", fileName: `${safeFileName(converted[0].document.title)}-p${converted[0].index + 1}.jpg` };
  const zip = new JSZip();
  archiveEntries(converted, () => ".jpg").forEach(({ page, fileName }) => zip.file(fileName, page.bytes));
  return { bytes: await zip.generateAsync({ type: "nodebuffer", compression: "DEFLATE" }), contentType: "application/zip", fileName: "clearscan-jpeg-pages.zip" };
}

async function exportZip(pages) {
  const zip = new JSZip();
  archiveEntries(pages, (page) => path.extname(page.fileName)).forEach(({ page, fileName }) => zip.file(fileName, page.bytes));
  return zip.generateAsync({ type: "nodebuffer", compression: "DEFLATE" });
}

function archiveEntries(pages, extensionFor) {
  const usedNames = new Set();
  return pages.map((page) => {
    const extension = extensionFor(page);
    const baseName = `${safeFileName(page.document.title)}-p${page.index + 1}`;
    let fileName = `${baseName}${extension}`;
    let suffix = 2;
    while (usedNames.has(fileName)) fileName = `${baseName}-${suffix++}${extension}`;
    usedNames.add(fileName);
    return { page, fileName };
  });
}

async function readJson(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 20 * 1024 * 1024) throw new Error("PAYLOAD_TOO_LARGE");
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
}

let mutationQueue = Promise.resolve();
const mutate = (operation) => {
  const result = mutationQueue.then(operation, operation);
  mutationQueue = result.catch(() => undefined);
  return result;
};

function allowBrowserOrigin(request, response) {
  const origin = request.headers.origin;
  if (!origin) return true;
  if (!allowedOrigins.has(origin) && !isLocalNetworkWebOrigin(origin)) {
    response.writeHead(403, { "Cache-Control": "no-store", "Content-Type": "application/json; charset=utf-8" });
    response.end(JSON.stringify({ error: "허용되지 않은 웹사이트입니다." }));
    return false;
  }
  response.setHeader("Access-Control-Allow-Origin", origin);
  response.setHeader("Vary", "Origin");
  return true;
}

function isLocalNetworkWebOrigin(origin) {
  try {
    const url = new URL(origin);
    if ((url.protocol !== "http:" && url.protocol !== "https:") || !localWebPorts.has(url.port)) return false;
    const hostname = url.hostname.replace(/^\[|\]$/g, "").toLowerCase();
    if (hostname === "localhost" || hostname === "::1") return true;
    if (hostname.endsWith(".local")) return true;
    if (/^(?:f[cd][0-9a-f]{2}|fe[89ab][0-9a-f]):/i.test(hostname)) return true;

    const octets = hostname.split(".").map(Number);
    if (octets.length !== 4 || octets.some((octet) => !Number.isInteger(octet) || octet < 0 || octet > 255)) return false;
    const [first, second] = octets;
    return first === 10
      || (first === 172 && second >= 16 && second <= 31)
      || (first === 192 && second === 168)
      || (first === 169 && second === 254)
      || first === 127;
  } catch {
    return false;
  }
}

const server = createServer(async (request, response) => {
  if (!allowBrowserOrigin(request, response)) return;
  if (request.method === "OPTIONS") return send(response, 204, "", "text/plain");
  const url = new URL(request.url || "/", `http://${request.headers.host}`);

  try {
    if (request.method === "GET" && url.pathname === "/api/health") {
      return send(response, 200, { ok: true, storage: "local-filesystem", ai: "on-device" });
    }

    if (request.method === "GET" && url.pathname === "/api/folders") {
      const database = await readDatabase();
      return send(response, 200, { folders: database.folders });
    }

    if (request.method === "POST" && url.pathname === "/api/folders") {
      const body = await readJson(request);
      const name = String(body.name || "").trim();
      if (!name) return send(response, 400, { error: "폴더 이름이 필요합니다." });
      const database = await mutate(async () => {
        const current = await readDatabase();
        const existingNames = new Set(current.folders.map((folder) => folder.name));
        let uniqueName = name;
        let suffix = 2;
        while (existingNames.has(uniqueName)) uniqueName = `${name} ${suffix++}`;
        current.folders.push({ id: randomUUID(), name: uniqueName, count: 0, tone: "mint" });
        await writeDatabase(current);
        return current;
      });
      return send(response, 201, { folders: database.folders });
    }

    if (request.method === "GET" && url.pathname === "/api/documents") {
      const database = await readDatabase();
      const documents = url.searchParams.get("folderId")
        ? database.documents.filter((document) => document.folderId === url.searchParams.get("folderId"))
        : database.documents;
      return send(response, 200, { documents });
    }

    if (request.method === "POST" && url.pathname === "/api/documents") {
      const body = await readJson(request);
      const database = await readDatabase();
      const folder = database.folders.find((candidate) => candidate.id === body.folderId);
      if (!folder) return send(response, 404, { error: "저장할 폴더를 찾지 못했습니다." });
      const incomingPages = Array.isArray(body.pages) && body.pages.length ? body.pages : [body.imageData];
      if (incomingPages.length > 100 || incomingPages.some((page) => typeof page !== "string" || !page.startsWith("data:image/"))) {
        return send(response, 400, { error: "스캔 이미지 데이터가 필요합니다." });
      }
      const id = randomUUID();
      const parsedPages = await Promise.all(incomingPages.map(async (page, index) => {
        const match = page.match(/^data:image\/(jpeg|png|webp);base64,(.+)$/);
        if (!match) return null;
        const extension = match[1] === "jpeg" ? "jpg" : match[1];
        const data = Buffer.from(match[2], "base64");
        try {
          const metadata = await sharp(data).metadata();
          const expectedFormat = extension === "jpg" ? "jpeg" : extension;
          if (!metadata.width || !metadata.height || metadata.format !== expectedFormat) return null;
        } catch {
          return null;
        }
        return { fileName: `${id}-${index + 1}.${extension}`, data };
      }));
      if (parsedPages.some((page) => !page)) return send(response, 400, { error: "지원하지 않는 이미지 형식입니다." });
      await Promise.all(parsedPages.map((page) => writeFile(path.join(scanRoot, page.fileName), page.data)));
      const fileNames = parsedPages.map((page) => page.fileName);
      const updated = await mutate(async () => {
        const current = await readDatabase();
        const target = current.folders.find((candidate) => candidate.id === body.folderId);
        if (!target) throw new Error("FOLDER_NOT_FOUND");
        const document = {
          id,
          folderId: target.id,
          title: String(body.title || "스캔 문서").trim(),
          createdAt: new Date().toISOString(),
          correction: body.correction || "document",
          aiMode: body.aiMode || null,
          features: Array.isArray(body.features) ? body.features : [],
          imageUrl: `/api/documents/${id}/image`,
          pages: fileNames.map((_, index) => `/api/documents/${id}/pages/${index}`),
          pageCount: fileNames.length,
          fileNames,
          fileName: fileNames[0],
        };
        current.documents.unshift(document);
        target.count += 1;
        await writeDatabase(current);
        return { current, document };
      });
      return send(response, 201, { document: updated.document, folders: updated.current.folders });
    }

    if (request.method === "POST" && url.pathname === "/api/exports") {
      const body = await readJson(request);
      const database = await readDatabase();
      const pages = await selectedPages(database, body.items);
      if (body.format === "pdf") {
        return sendFile(response, await exportPdf(pages), "application/pdf", "clearscan-export.pdf");
      }
      if (body.format === "jpeg") {
        const result = await exportJpegs(pages);
        return sendFile(response, result.bytes, result.contentType, result.fileName);
      }
      if (body.format === "zip") {
        return sendFile(response, await exportZip(pages), "application/zip", "clearscan-pages.zip");
      }
      return send(response, 400, { error: "내보내기 형식은 PDF, JPEG 또는 ZIP이어야 합니다." });
    }

    const imageMatch = url.pathname.match(/^\/api\/documents\/([^/]+)\/image$/);
    if (request.method === "GET" && imageMatch) {
      const database = await readDatabase();
      const document = database.documents.find((candidate) => candidate.id === imageMatch[1]);
      if (!document) return send(response, 404, { error: "문서를 찾지 못했습니다." });
      const image = await readFile(path.join(scanRoot, document.fileName));
      const contentType = document.fileName.endsWith(".png") ? "image/png" : document.fileName.endsWith(".webp") ? "image/webp" : "image/jpeg";
      return send(response, 200, image, contentType);
    }

    const pageMatch = url.pathname.match(/^\/api\/documents\/([^/]+)\/pages\/(\d+)$/);
    if (request.method === "GET" && pageMatch) {
      const database = await readDatabase();
      const document = database.documents.find((candidate) => candidate.id === pageMatch[1]);
      const fileName = document?.fileNames?.[Number(pageMatch[2])];
      if (!document || !fileName) return send(response, 404, { error: "페이지를 찾지 못했습니다." });
      const image = await readFile(path.join(scanRoot, fileName));
      const contentType = fileName.endsWith(".png") ? "image/png" : fileName.endsWith(".webp") ? "image/webp" : "image/jpeg";
      return send(response, 200, image, contentType);
    }

    return send(response, 404, { error: "API 경로를 찾지 못했습니다." });
  } catch (error) {
    console.error("ClearScan API error", error);
    const message = error instanceof Error ? error.message : "";
    const status = message === "PAYLOAD_TOO_LARGE" ? 413 : ["INVALID_SELECTION", "DOCUMENT_NOT_FOUND", "PAGE_NOT_FOUND"].includes(message) ? 400 : 500;
    return send(response, status, { error: status === 413 ? "이미지가 너무 큽니다." : status === 400 ? "선택한 문서나 페이지를 확인해주세요." : "로컬 저장 중 오류가 발생했습니다." });
  }
});

server.listen(port, host, () => {
  console.log(`ClearScan local API listening on http://${host}:${port}`);
});
