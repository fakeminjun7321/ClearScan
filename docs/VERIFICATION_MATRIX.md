# Verification matrix

ClearScan reports verification levels separately. A stronger label is never
inferred from a weaker one.

| Surface | Implemented | Unit verified | Simulator verified | Physical device verified | Live integration verified |
|---|---:|---:|---:|---:|---:|
| Folder/document/page persistence | Yes | Yes | Yes | Not current | N/A |
| PDF/JPEG/ZIP export | Yes | Yes | Yes | Not current | N/A |
| Hybrid rectangle candidates | Yes | Synthetic images | UI only | Current revision: no | N/A |
| Recent-frame auto-capture consensus | Yes | Yes | Ring UI only | Current revision: no | N/A |
| Silent video-frame capture | Yes | Settings/service tests | UI only | Audible check: no | N/A |
| Book split and gutter editing | Yes | Synthetic tests | UI flow | Real spread: no | N/A |
| Local OCR/enhancement | Yes | Yes | Yes | Camera inputs: no | N/A |
| Native Drive/Docs | Yes | Mock transport | UI mock | Not required | No |
| Companion Drive/Docs | Yes | Request tests | Browser mock | N/A | No |

Latest local evidence at the time of open-source publication:

- Native unit tests: 90 passed, 0 failed.
- Targeted iPad-simulator shutter visibility test: 1 passed, 0 failed.
- Backend tests: 5 passed, 0 failed.
- Companion Playwright tests: 3 passed, 0 failed.

The simulator has no usable rear camera. Real-paper detection, automatic
capture, audible silence, hardware lens switching, OAuth consent, and
destination-side Drive/Docs results remain explicitly unverified for the
current public revision.
