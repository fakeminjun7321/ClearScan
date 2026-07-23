# ClearScan implementation plan

## Product boundary

ClearScan is a personal iPhone/iPad scanner with a local companion website. It has no account system, billing, analytics, shared workspaces, or App Store release work. Native document data is stored with SwiftData and page image files with FileManager. The companion website uses the local ClearScan API and can upload only the user's selected exports to Google Drive.

## Delivery sequence

1. **Unified storage — complete**
   - Use `Folder -> Document -> Pages[]` across native, web, and API.
   - Persist folders, document metadata, individual page files, and derived folder counts.
2. **Native capture — implemented and unit/simulator-tested; current physical check pending**
   - `한 페이지`: rectangle detection, stability tracking, automatic capture, perspective correction.
   - `책 2페이지`: outer bounds and gutter estimation, manual center correction, left/right page split, continuous spread order.
   - Complete-silent video-frame capture, optional high-quality photo capture, timer, and supported 0.5x/1x lens selection.
   - The detector has orientation, small-document, handheld-jitter, recent-frame
     consensus, outlier, and brief-miss tests. The current consensus revision still
     requires a real-paper device check.
3. **Library — complete**
   - Tapping a folder opens a real detail view with its documents and pages.
   - Documents and individual pages can be selected independently.
4. **Export — complete**
   - PDF, single or zipped JPEG, and source ZIP are generated from the actual selected page files.
   - Export is available in the mobile experience, companion website, and native service layer.
5. **Google Drive and Google Docs — code, cloud configuration, and mock tests complete; live consent pending**
   - OAuth Client ID comes from ignored `web/.env.local`; no secret is embedded.
   - The website creates or reuses a Drive folder named `ClearScan`, shows per-document progress, and supports retry.
   - Google Docs export converts only the selected pages with Korean OCR and returns a direct edit link.
6. **Local AI and editing — implemented and simulator-tested**
   - Four-pass on-device Vision OCR inspired by Quilo's comparison concept; no Quilo service or document upload.
   - Blur restoration, illumination normalization, quality analysis, conservative edge-finger removal, and red/blue ink removal.
   - Smart/document/black-and-white presets, preview/original comparison, editable OCR, selection eraser, and PencilKit signature.
   - Conservative cylindrical book-page dewarp is Beta and has synthetic-grid tests only; general 3D wrinkles are not claimed.
7. **Native installation — simulator verified; physical feature checks pending**
   - Xcode 26.6 and the iOS 26.5 Simulator runtime are installed. The app builds, installs, and launches without signing in Simulator.
   - Public source contains no Apple Team, personal Bundle ID, provisioning
     profile, or OAuth project value.

## External setup remaining

- On a configured physical iPhone/iPad, point the current build at real sheets
  and book spreads, then record rectangle quality, automatic capture, silent
  capture sound, and saved crops.
- In the native Google tab, sign in with the registered test account and approve the one-time `drive.file` consent; then verify one PDF and one editable Google Docs conversion in Drive. Password/account consent cannot be completed unattended.
- A physical iPhone is not connected, so its camera and layout remain simulator-only checks.
