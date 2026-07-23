# Open-source scanner review

ClearScan's live document detector was reviewed against real open-source
scanner implementations instead of relying only on project-local heuristics.

## Implemented reference

- **WeScan** (WeTransfer, MIT): the `RectangleFeaturesFunnel` keeps a bounded
  queue of recent rectangles, scores how many agree, prefers the current
  display during ties, and requires repeated close matches before auto scan.
  ClearScan now uses an independent normalized-coordinate implementation of
  that temporal-consensus structure. It additionally uses a median
  quadrilateral, area-change checks, stale-page protection, and progress
  decay across brief Vision misses.

## Compared, not copied

- **Just Scan It** (MIT): compares the current rectangle only with the last
  rectangle and drives a timer. This is simple but a single miss resets the
  process, so it was not adopted.
- **OpenScanner** (MIT): its automatic capture path is based primarily on
  VisionKit/DataScanner recognized text and barcode items. It is not a
  reusable document-boundary consensus detector.
- **OpenCV-Document-Scanner**: combines grayscale blur, morphological closing,
  Canny edges, line/corner extraction, contour area, and quadrilateral-angle
  validation. ClearScan already applies equivalent area/border geometry
  rejection around Apple Vision candidates. No code was copied and OpenCV was
  not added as a large runtime dependency.

## Source links

- https://github.com/WeTransferArchive/WeScan
- https://github.com/kuvkir/justscanit
- https://github.com/pencilresearch/OpenScanner
- https://github.com/andrewdcampbell/OpenCV-Document-Scanner
