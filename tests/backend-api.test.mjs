import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { networkInterfaces } from "node:os";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import JSZip from "jszip";
import { PDFDocument } from "pdf-lib";
import sharp from "sharp";

const port = 4188;
const dataDirectory = await mkdtemp(path.join(os.tmpdir(), "clearscan-api-"));
const backend = spawn(process.execPath, ["server/index.mjs"], {
  cwd: path.resolve("."),
  env: { ...process.env, CLEARSCAN_API_PORT: String(port), CLEARSCAN_DATA_DIR: dataDirectory },
  stdio: ["ignore", "pipe", "inherit"],
});

async function waitForBackend() {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/api/health`);
      if (response.ok) return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }
  throw new Error("Backend did not start");
}

await waitForBackend();

test.after(async () => {
  backend.kill("SIGTERM");
  await rm(dataDirectory, { recursive: true, force: true });
});

test("persists folders, scans, metadata, and folder counts", async () => {
  const folderResponse = await fetch(`http://127.0.0.1:${port}/api/folders`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: "계약서" }),
  });
  assert.equal(folderResponse.status, 201);
  const folderPayload = await folderResponse.json();
  const folder = folderPayload.folders.find((candidate) => candidate.name === "계약서");
  assert.ok(folder?.id);

  const sampleImage = await readFile(path.resolve("public/assets/scan-sample.png"));
  const imageData = `data:image/png;base64,${sampleImage.toString("base64")}`;
  const secondImage = await sharp(sampleImage).rotate(90).png().toBuffer();
  const secondImageData = `data:image/png;base64,${secondImage.toString("base64")}`;
  const documentResponse = await fetch(`http://127.0.0.1:${port}/api/documents`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      folderId: folder.id,
      title: "테스트 문서",
      imageData,
      pages: [imageData, secondImageData],
      correction: "ai",
      aiMode: "quality",
      features: ["shadow", "deblur"],
    }),
  });
  assert.equal(documentResponse.status, 201);
  const documentPayload = await documentResponse.json();
  assert.equal(documentPayload.document.title, "테스트 문서");
  assert.equal(documentPayload.document.pageCount, 2);
  assert.equal(documentPayload.document.pages.length, 2);
  assert.equal(documentPayload.folders.find((candidate) => candidate.id === folder.id).count, 1);

  const imageResponse = await fetch(`http://127.0.0.1:${port}${documentPayload.document.imageUrl}`);
  assert.equal(imageResponse.status, 200);
  assert.equal(imageResponse.headers.get("content-type"), "image/png");
  assert.ok((await imageResponse.arrayBuffer()).byteLength > 20);

  const secondPageResponse = await fetch(`http://127.0.0.1:${port}${documentPayload.document.pages[1]}`);
  assert.equal(secondPageResponse.status, 200);
  assert.equal(secondPageResponse.headers.get("content-type"), "image/png");
  assert.deepEqual(Buffer.from(await secondPageResponse.arrayBuffer()), secondImage);

  const database = JSON.parse(await readFile(path.join(dataDirectory, "clearscan.json"), "utf8"));
  assert.equal(database.documents.length, 1);
  assert.deepEqual(database.documents[0].features, ["shadow", "deblur"]);

  const exportItems = [{ documentId: documentPayload.document.id, pageIndexes: [0, 1] }];
  const pdfResponse = await fetch(`http://127.0.0.1:${port}/api/exports`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ format: "pdf", items: exportItems }),
  });
  assert.equal(pdfResponse.status, 200);
  assert.equal(pdfResponse.headers.get("content-type"), "application/pdf");
  const pdfBytes = Buffer.from(await pdfResponse.arrayBuffer());
  assert.equal(pdfBytes.subarray(0, 4).toString(), "%PDF");
  assert.equal((await PDFDocument.load(pdfBytes)).getPageCount(), 2);

  const jpegResponse = await fetch(`http://127.0.0.1:${port}/api/exports`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ format: "jpeg", items: [{ documentId: documentPayload.document.id, pageIndexes: [1] }] }),
  });
  assert.equal(jpegResponse.status, 200);
  assert.equal(jpegResponse.headers.get("content-type"), "image/jpeg");
  const jpegBytes = Buffer.from(await jpegResponse.arrayBuffer());
  assert.deepEqual([...jpegBytes.subarray(0, 2)], [0xff, 0xd8]);
  assert.equal((await sharp(jpegBytes).metadata()).format, "jpeg");

  const jpegArchiveResponse = await fetch(`http://127.0.0.1:${port}/api/exports`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ format: "jpeg", items: exportItems }),
  });
  assert.equal(jpegArchiveResponse.status, 200);
  assert.equal(jpegArchiveResponse.headers.get("content-type"), "application/zip");
  const jpegArchive = await JSZip.loadAsync(await jpegArchiveResponse.arrayBuffer());
  const jpegEntries = Object.values(jpegArchive.files).filter((entry) => !entry.dir);
  assert.equal(jpegEntries.length, 2);
  for (const entry of jpegEntries) assert.equal((await sharp(await entry.async("nodebuffer")).metadata()).format, "jpeg");

  const zipResponse = await fetch(`http://127.0.0.1:${port}/api/exports`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ format: "zip", items: exportItems }),
  });
  assert.equal(zipResponse.status, 200);
  assert.equal(zipResponse.headers.get("content-type"), "application/zip");
  const zipBytes = Buffer.from(await zipResponse.arrayBuffer());
  assert.equal(zipBytes.subarray(0, 2).toString(), "PK");
  const zip = await JSZip.loadAsync(zipBytes);
  const zipEntries = Object.values(zip.files).filter((entry) => !entry.dir);
  assert.equal(zipEntries.length, 2);
  const archivedPages = await Promise.all(zipEntries.map((entry) => entry.async("nodebuffer")));
  assert.ok(archivedPages.some((page) => page.equals(sampleImage)));
  assert.ok(archivedPages.some((page) => page.equals(secondImage)));

  const duplicateTitleResponse = await fetch(`http://127.0.0.1:${port}/api/documents`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ folderId: folder.id, title: "테스트 문서", imageData: secondImageData }),
  });
  assert.equal(duplicateTitleResponse.status, 201);
  const duplicateTitleDocument = (await duplicateTitleResponse.json()).document;
  const collisionResponse = await fetch(`http://127.0.0.1:${port}/api/exports`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      format: "zip",
      items: [
        { documentId: documentPayload.document.id, pageIndexes: [0] },
        { documentId: duplicateTitleDocument.id, pageIndexes: [0] },
      ],
    }),
  });
  const collisionZip = await JSZip.loadAsync(await collisionResponse.arrayBuffer());
  assert.equal(Object.values(collisionZip.files).filter((entry) => !entry.dir).length, 2);
});

test("rejects a document without image data", async () => {
  const response = await fetch(`http://127.0.0.1:${port}/api/documents`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ folderId: "study", title: "잘못된 요청" }),
  });
  assert.equal(response.status, 400);
});

test("rejects a data URL whose bytes are not a decodable image", async () => {
  const response = await fetch(`http://127.0.0.1:${port}/api/documents`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      folderId: "study",
      title: "손상된 이미지",
      imageData: `data:image/png;base64,${Buffer.from("not an image").toString("base64")}`,
    }),
  });
  assert.equal(response.status, 400);
});

test("allows the ClearScan web origin and rejects unrelated websites", async () => {
  const allowed = await fetch(`http://127.0.0.1:${port}/api/health`, {
    headers: { Origin: "http://localhost:4173" },
  });
  assert.equal(allowed.status, 200);
  assert.equal(allowed.headers.get("access-control-allow-origin"), "http://localhost:4173");

  const lanOrigin = "http://192.168.11.42:4173";
  const allowedLan = await fetch(`http://127.0.0.1:${port}/api/health`, {
    headers: { Origin: lanOrigin },
  });
  assert.equal(allowedLan.status, 200);
  assert.equal(allowedLan.headers.get("access-control-allow-origin"), lanOrigin);

  const lanPreflight = await fetch(`http://127.0.0.1:${port}/api/exports`, {
    method: "OPTIONS",
    headers: {
      Origin: lanOrigin,
      "Access-Control-Request-Method": "POST",
      "Access-Control-Request-Headers": "content-type",
    },
  });
  assert.equal(lanPreflight.status, 204);
  assert.equal(lanPreflight.headers.get("access-control-allow-origin"), lanOrigin);
  assert.match(lanPreflight.headers.get("access-control-allow-methods") ?? "", /POST/);
  assert.match(lanPreflight.headers.get("access-control-allow-headers") ?? "", /Content-Type/i);

  const wrongLanPort = await fetch(`http://127.0.0.1:${port}/api/health`, {
    headers: { Origin: "http://192.168.11.42:9000" },
  });
  assert.equal(wrongLanPort.status, 403);

  const rejected = await fetch(`http://127.0.0.1:${port}/api/documents`, {
    headers: { Origin: "https://example.com" },
  });
  assert.equal(rejected.status, 403);
  assert.equal(rejected.headers.get("access-control-allow-origin"), null);
});

test("accepts API requests through a LAN interface when one is available", async (context) => {
  const lanAddress = Object.values(networkInterfaces())
    .flat()
    .find((address) => address?.family === "IPv4" && !address.internal)?.address;
  if (!lanAddress) return context.skip("No non-loopback IPv4 interface is available");

  const origin = `http://${lanAddress}:4173`;
  const response = await fetch(`http://${lanAddress}:${port}/api/health`, {
    headers: { Origin: origin },
  });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("access-control-allow-origin"), origin);
  assert.equal((await response.json()).ok, true);
});
