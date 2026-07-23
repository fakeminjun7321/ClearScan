# Changelog

All notable ClearScan changes are documented here. The project follows
[Semantic Versioning](https://semver.org/) while it remains pre-1.0.

## [0.1.0-alpha.1] - 2026-07-23

### Added

- UIKit-first iPhone and iPad scanner with single-page and two-page book modes.
- AVFoundation video-frame capture path, manual shutter, automatic capture
  stability ring, torch, timer, and lens controls.
- Vision-based document segmentation and rectangle detection with recent-frame
  consensus and a guarded book-spread recovery path.
- Automatic and manual gutter selection, perspective correction, left/right
  page splitting, and continuous page ordering.
- SwiftData and FileManager persistence with folder, document, and individual
  page selection.
- PDF, JPEG, and ZIP export from the native app and companion web app.
- Local OCR, quality analysis, blur and illumination enhancement, constrained
  finger and colored-mark removal, OCR text editing, selection erasing, and
  PencilKit signatures.
- Optional Google Drive upload and Google Docs OCR conversion integration.
- App icon, UI audit images, architecture, worktree collaboration guide,
  verification matrix, scanner research notes, contribution guide, security
  policy, and CI.

### Verification

- 90 native unit tests passed locally.
- 5 backend tests, 4 site-package tests, 3 companion browser tests, and 8
  mobile-runtime tests passed locally.
- Sanitized UIKit app built and launched in an iOS Simulator.
- The supplied ambiguous book PDF was replayed offline: detected document area
  increased from 27.7% to 98.5% and the inferred gutter was 65.9%.

### Fixed

- Aligned single-channel Core Image bitmap rows on every width, preventing
  empty blur-analysis and selection-mask buffers on some simulator runtimes.
- Made the cross-runtime OCR smoke test accept harmless whitespace and
  punctuation differences while still requiring the same English, Korean, and
  numeric content.

### Known limitations

- Physical-device camera detection, automatic capture timing, audible silence,
  and lens switching have not yet been verified on this public revision.
- Google OAuth consent and destination-side Drive/Docs results have not yet
  been live-verified.
- The ambiguous source PDF is intentionally not included; a synthetic
  regression test represents the same geometry.

[0.1.0-alpha.1]: https://github.com/fakeminjun7321/ClearScan/releases/tag/v0.1.0-alpha.1
