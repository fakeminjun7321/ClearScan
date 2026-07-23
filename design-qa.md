# ClearScan Design QA

## Comparison Target

- Private source references are intentionally excluded from the public repository.
- Final implementation screenshot: `implementation-camera-final.png`
- Full-view comparison: `design-comparison-camera-final.png`
- Focused controls comparison: `design-comparison-camera-controls.png`
- Supporting review-state screenshot: `implementation-review.png`
- Pixel-detected boundary screenshot: `implementation-auto-detect.png`
- Combined automatic-boundary comparison: `design-comparison-auto-detect.png`
- State: iPhone camera screen, one-page mode, automatic scan on, silent capture on, document detected.
- Browser: Codex in-app browser at `http://localhost:4173/?screen=camera&qa=final2`.

## Viewport And Density

- App viewport: 393 × 852 CSS px.
- Browser viewport: 1400 × 1200 CSS px.
- Device scale factor: 1.
- Source pixels: 852 × 1846, normalized to 393 × 852 for comparison.
- Implementation pixels: 393 × 852.
- Runtime screen measurement: 393 × 852 CSS px at scale 1.
- Runtime-owned device bezel, status bar, camera cutout, and home indicator are excluded from 1:1 app-content fidelity judgments.

## Findings

- No actionable P0, P1, or P2 findings remain.
- [P3] The compact folder header adds slightly more density than the minimal generated source. This is intentional because the selected folder is part of the save flow. The camera controls were reduced to the two required actions: automatic scanning and silent capture.

## Required Fidelity Surfaces

- Fonts and typography: Korean UI uses the native system stack with clear 10–21 px hierarchy, strong headings, and no clipped or broken labels. Camera quick-control labels were increased to 10 px during QA.
- Spacing and layout rhythm: the camera preview, detected document, guide corners, capture status, mode selector, quick controls, and shutter are vertically separated and remain inside the 393 × 852 viewport. No persistent control is hidden by the home indicator.
- Colors and visual tokens: near-black capture surface, warm paper, white controls, and cobalt-blue detection/selected states follow the source direction. Inactive navigation and tool text was darkened for readability.
- Image quality and asset fidelity: the camera and review states use the generated project asset at `public/assets/scan-sample.png`; it is sharp, correctly cropped, and integrated without placeholders, CSS drawings, or custom SVG illustration substitutes. Radix UI icons provide one consistent icon family.
- Copy and content: the visible Korean labels are concise and match the requested mental model: silent capture, automatic scan, selectable correction, on-device AI, and folders.
- Accessibility and interaction: core controls are semantic buttons or switches with labels, pressed/checked states, alt text, and reduced-motion handling. Primary tap targets are at least 40 px; the inactive control contrast was improved during QA.

## Primary Interactions Tested

- Silent capture toggles off and back on; `aria-pressed` changes correctly.
- Automatic scan toggles off and back on; `aria-pressed` changes correctly.
- Capture transitions from the camera state to the scan review state.
- Original, document, and black-and-white filters are selectable; AI optimization opens its detail sheet and applies a real local pixel-processing result rather than a CSS-only state.
- Folder picker targets the local API. Automated backend tests verify image-file persistence, metadata creation, recent-document retrieval, and atomic folder-count updates.
- Bottom navigation switches between the document library, camera, and folder views.
- New-folder flow accepts `계약서`, creates the folder, and dismisses the simulated keyboard.
- Scan settings opens and exposes silent capture, automatic scan, and the basic-correction selector.
- Browser console: no warnings or errors in the final camera state.

## Comparison History

1. Pass 1 — `/design-comparison-camera.png`
   - Finding: [P2] the document detection guide began below the real top paper corners and extended below the bottom corners, making automatic detection look inaccurate.
   - Fix: aligned `.scan-outline` to the visible paper bounds by moving its top edge from 132 px to 80 px and its bottom inset from 36 px to 60 px.
2. Pass 2 — `/design-comparison-camera-v2.png`
   - Post-fix evidence: the guide now follows all four visible document edges.
   - Finding: [P2] inactive bottom-navigation/review-tool text and the 9 px camera labels were too faint or small for a simple scanning workflow.
   - Fix: darkened inactive labels and increased the camera quick-control and offline-processing labels to 10 px.
3. Pass 3 — `/design-comparison-camera-final.png` and `/design-comparison-camera-controls.png`
   - Post-fix evidence: the document guide remains aligned, the capture hierarchy matches the source, and the required extra controls remain legible without overlap.
   - No actionable P0/P1/P2 differences remain.
4. Pass 4 — `/design-comparison-auto-detect.png`
   - The user's new automatic-boundary reference was normalized and compared beside the implementation.
   - The implementation derives its four displayed corners from image pixels and carries those corners into the captured, rectified output. Coordinate mapping now accounts for `object-fit: cover`.
   - Live camera frames are sampled at about 7 fps, corner movement and area change are tracked for 720 ms, and automatic capture uses a cancellation-safe deadline.

## Open Questions

- Physical-camera quality, platform-specific audible silence, and live Google
  consent/upload remain separate verification work. The browser prototype has
  real `getUserMedia` capture, corner-based rectification, deterministic local
  pixel enhancement, and a filesystem-backed local API; it does not describe
  that deterministic fallback as a trained model.

## Implementation Checklist

- [x] Camera-first visual direction reproduced.
- [x] Silent capture and automatic scan controls implemented.
- [x] Selectable basic correction and a functioning local enhancement pipeline implemented.
- [x] Folder browsing, choosing, creation, scan-file persistence, metadata retrieval, and count updates implemented through a local backend API.
- [x] Runtime integrity and production build passed.
- [x] Primary interaction path tested in the in-app browser.
- [x] P0/P1/P2 visual differences resolved.

final result: passed
