# ClearScan local backend

The browser prototype uses a real local API at `127.0.0.1:4174`; folders and scans are not kept only in React state.

## Responsibilities

- Camera frame analysis, quadrilateral tracking, perspective rectification, and image enhancement run locally in the client.
- `server/index.mjs` persists scan files under `data/scans/`.
- `data/clearscan.json` stores document metadata, enhancement choices, folder relationships, and counts.
- Mutations are serialized and the JSON database is replaced atomically.

## API

- `GET /api/health`
- `GET /api/folders`
- `POST /api/folders`
- `GET /api/documents?folderId=...`
- `POST /api/documents`
- `GET /api/documents/:id/image` (legacy first-page route)
- `GET /api/documents/:id/pages/:index`
- `POST /api/exports` with `{ format: "pdf" | "jpeg" | "zip", items: [{ documentId, pageIndexes }] }`

Documents are stored as `Document -> Pages[]`. `POST /api/documents` accepts a `pages` array of image data URLs; the legacy single `imageData` field remains compatible. `npm run test:backend` verifies two-page persistence, page retrieval, folder-count updates, real PDF/JPEG/ZIP signatures, and invalid-payload rejection.

## AI boundary

`src/smartEnhancement.ts` currently provides a functioning deterministic on-device fallback for shadow normalization, deblurring, bleed-through reduction, edge illumination, denoising, and upscaling. It does not pretend to be a trained model. A later Core ML or TFLite implementation should replace this module behind the same input/output contract; the storage API does not need to change.
