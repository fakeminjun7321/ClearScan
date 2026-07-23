# Verification matrix

ClearScan reports verification levels separately. A stronger label is never
inferred from a weaker one.

| Surface | Implemented | Unit verified | Simulator verified | Physical device verified | Live integration verified |
|---|---:|---:|---:|---:|---:|
| Folder/document/page persistence | Yes | Yes | Yes | Not current | N/A |
| PDF/JPEG/ZIP export | Yes | Yes | Yes | Not current | N/A |
| Hybrid rectangle candidates | Yes | 7 deterministic scene fixtures | UI only | Current revision: no | N/A |
| Recent-frame auto-capture consensus | Yes | Safe/unsafe history, drift, jitter, outage | Ring UI only | Current revision: no | N/A |
| Silent video-frame capture | Yes | Settings/service tests | UI only | Audible check: no | N/A |
| Book split and gutter editing | Yes | Synthetic tests | UI flow | Real spread: no | N/A |
| Local OCR/enhancement | Yes | Yes | Yes | Camera inputs: no | N/A |
| Native Drive/Docs | Yes | Mock transport | UI mock | Not required | No |
| Companion Drive/Docs | Yes | Request tests | Browser mock | N/A | No |

Latest local evidence:

- Native unit tests: 105 passed, 0 failed on an iPhone simulator.
- Native unit tests: 105 passed, 0 failed on an iPad simulator.
- Detection condition/behavior regressions: 15 passed, 0 failed.
- Native UIKit UI tests on iPhone: 4 passed, 1 camera-dependent test
  skipped, 0 failed.
- Native UIKit UI tests on iPad: 4 passed, 1 camera-dependent test
  skipped, 0 failed.
- Final Google workspace regression on a fresh iPhone simulator: 1 passed,
  0 failed.
- Backend tests: 5 passed, 0 failed.
- Companion Playwright tests: 3 passed, 0 failed.
- Hosted-site contract tests: 4 passed, 0 failed.
- Mobile/runtime API tests: 8 passed, 0 failed.

The simulator has no usable rear camera. Real-paper detection, automatic
capture, audible silence, hardware lens switching, OAuth consent, and
destination-side Drive/Docs results remain explicitly unverified for the
current public revision.
