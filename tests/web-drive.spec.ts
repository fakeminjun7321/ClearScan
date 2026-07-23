import { expect, test, type Route } from "@playwright/test";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "content-type": "application/json",
};

const documentRecord = {
  id: "doc-1",
  folderId: "study",
  title: "한국어 OCR 문서",
  createdAt: "2026-07-23T00:00:00.000Z",
  correction: "document",
  imageUrl: "/api/documents/doc-1/image",
  pages: ["/api/documents/doc-1/pages/0", "/api/documents/doc-1/pages/1"],
  pageCount: 2,
};

async function fulfillJson(route: Route, payload: unknown) {
  await route.fulfill({ status: 200, headers: corsHeaders, body: JSON.stringify(payload) });
}

test("uses the companion hostname for the local API when no environment override exists", async ({ page }) => {
  const apiRequests: string[] = [];
  await page.route("http://localhost:4174/api/folders", (route) => {
    apiRequests.push(route.request().url());
    return fulfillJson(route, { folders: [] });
  });
  await page.route("http://localhost:4174/api/documents", (route) => {
    apiRequests.push(route.request().url());
    return fulfillJson(route, { documents: [] });
  });

  await page.goto("http://localhost:4197/");
  await expect(page.getByRole("heading", { name: "모든 문서" })).toBeVisible();
  await expect.poll(() => [...new Set(apiRequests)].sort()).toEqual([
    "http://localhost:4174/api/documents",
    "http://localhost:4174/api/folders",
  ]);
});

test("routes native Drive and Docs companion links to the Google workspace panel", async ({ page }) => {
  await page.route("http://clearscan.test/api/folders", (route) => fulfillJson(route, { folders: [] }));
  await page.route("http://clearscan.test/api/documents", (route) => fulfillJson(route, { documents: [] }));

  for (const target of ["drive", "docs"] as const) {
    await page.goto(`/?workspace=${target}`);
    const panel = page.getByRole("region", { name: "Google Workspace 연결" });
    await expect(panel).toBeVisible();
    await expect(panel).toBeFocused();
    await expect(panel).toHaveClass(/workspace-target/);
    await expect(panel).toHaveAttribute("data-workspace-target", target);
    await expect(panel).toContainText(target === "docs"
      ? "Google Docs · 편집 가능 OCR을 선택하세요."
      : "선택한 문서를 ClearScan 폴더로 보낼 수 있습니다.");
  }
});

test("uploads selected pages as an editable Korean Google Doc and supports retry", async ({ page }) => {
  const exportBodies: Array<{ format: string; items: Array<{ documentId: string; pageIndexes: number[] }> }> = [];
  const uploads: Array<{ url: URL; headers: Record<string, string>; body: string }> = [];
  let releaseFailedUpload = () => {};

  await page.addInitScript(() => {
    window.google = {
      accounts: {
        oauth2: {
          initTokenClient: (options) => ({
            requestAccessToken: () => queueMicrotask(() => options.callback({ access_token: "qa-token" })),
          }),
        },
      },
    };
  });

  await page.route("http://clearscan.test/api/folders", (route) => fulfillJson(route, {
    folders: [{ id: "study", name: "학습 자료", count: 1, tone: "blue" }],
  }));
  await page.route("http://clearscan.test/api/documents", (route) => fulfillJson(route, { documents: [documentRecord] }));
  await page.route("http://clearscan.test/api/documents/doc-1/image", (route) => route.fulfill({
    status: 200,
    headers: { "access-control-allow-origin": "*", "content-type": "image/png" },
    body: Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=", "base64"),
  }));
  await page.route("http://clearscan.test/api/exports", async (route) => {
    exportBodies.push(route.request().postDataJSON());
    await route.fulfill({
      status: 200,
      headers: { "access-control-allow-origin": "*", "content-type": "application/pdf" },
      body: Buffer.from("%PDF-1.7\nselected-page-payload"),
    });
  });
  await page.route("https://www.googleapis.com/drive/v3/files?*", (route) => fulfillJson(route, {
    files: [{ id: "drive-folder", name: "ClearScan" }],
  }));
  await page.route("https://www.googleapis.com/upload/drive/v3/files?*", async (route) => {
    const request = route.request();
    uploads.push({
      url: new URL(request.url()),
      headers: request.headers(),
      body: request.postDataBuffer()?.toString("utf8") ?? "",
    });
    if (uploads.length === 1) {
      await new Promise<void>((resolve) => { releaseFailedUpload = resolve; });
      await route.abort("failed");
      return;
    }
    await route.fulfill({
      status: 200,
      headers: corsHeaders,
      body: JSON.stringify({
        id: "google-doc-1",
        name: documentRecord.title,
        mimeType: "application/vnd.google-apps.document",
        webViewLink: "https://docs.google.com/document/d/google-doc-1/edit",
      }),
    });
  });

  await page.goto("/");
  await expect(page).toHaveTitle("ClearScan Web");
  await expect(page.getByRole("heading", { name: "모든 문서" })).toBeVisible();

  const documentArticle = page.getByRole("article").filter({ hasText: documentRecord.title });
  await documentArticle.getByRole("button", { name: "2p" }).click();
  await expect(page.getByText("1개 페이지 선택")).toBeVisible();
  await expect(page.getByRole("button", { name: "Drive 업로드" })).toBeDisabled();

  await page.getByRole("button", { name: "Google 연결" }).click();
  await expect(page.getByRole("button", { name: "연결됨" })).toBeVisible();
  await page.getByLabel("Drive 업로드 형식").selectOption("gdoc");
  await page.getByRole("button", { name: "Drive 업로드" }).click();

  await expect.poll(() => uploads.length).toBe(1);
  await expect(page.getByText("0%", { exact: true })).toBeVisible();
  await expect(page.locator("progress")).toHaveAttribute("value", "0");
  expect(exportBodies).toEqual([{ format: "pdf", items: [{ documentId: "doc-1", pageIndexes: [1] }] }]);
  expect(uploads[0].url.searchParams.get("uploadType")).toBe("multipart");
  expect(uploads[0].url.searchParams.get("ocrLanguage")).toBe("ko");
  expect(uploads[0].headers.authorization).toBe("Bearer qa-token");
  expect(uploads[0].headers["content-type"]).toContain("multipart/related; boundary=");
  expect(uploads[0].body).toContain('"mimeType":"application/vnd.google-apps.document"');
  expect(uploads[0].body).toContain('"parents":["drive-folder"]');
  expect(uploads[0].body).toContain("%PDF-1.7\nselected-page-payload");

  releaseFailedUpload();
  await expect(page.getByRole("button", { name: "재시도" })).toBeVisible();
  await expect(page.getByText("네트워크 오류", { exact: true })).toBeVisible();
  await documentArticle.getByRole("button", { name: "2p" }).click();
  await documentArticle.getByRole("button", { name: "1p" }).click();
  await expect(documentArticle.getByRole("button", { name: "1p" })).toHaveAttribute("aria-pressed", "true");
  await expect(documentArticle.getByRole("button", { name: "2p" })).toHaveAttribute("aria-pressed", "false");
  await page.getByRole("button", { name: "재시도" }).click();

  await expect(page.getByText("Google Docs 업로드 완료", { exact: true })).toBeVisible();
  await expect(page.locator("progress")).toHaveAttribute("value", "100");
  await expect(page.getByRole("link", { name: "열기" })).toHaveAttribute("href", "https://docs.google.com/document/d/google-doc-1/edit");
  expect(uploads).toHaveLength(2);
  expect(exportBodies).toEqual([
    { format: "pdf", items: [{ documentId: "doc-1", pageIndexes: [1] }] },
    { format: "pdf", items: [{ documentId: "doc-1", pageIndexes: [1] }] },
  ]);
});
