# Third-party notices and references

ClearScan is MIT-licensed. Package dependencies are fetched through Swift
Package Manager or npm and retain their own licenses; they are not relicensed
by this repository. Consult `Package.resolved`, `package-lock.json`, and the
upstream packages for exact versions and notices.

## Scanner research references

- [WeScan](https://github.com/WeTransferArchive/WeScan), MIT License. ClearScan's
  recent-frame rectangle consensus is an independent normalized-coordinate
  implementation inspired by WeScan's `RectangleFeaturesFunnel`.
- [Just Scan It](https://github.com/kuvkir/justscanit), MIT License. Reviewed for
  Vision request and timer-based capture behavior; no code copied.
- [OpenScanner](https://github.com/pencilresearch/OpenScanner), MIT License.
  Reviewed for VisionKit/DataScanner integration; no code copied.
- [OpenCV-Document-Scanner](https://github.com/andrewdcampbell/OpenCV-Document-Scanner).
  Reviewed for contour, area, and angle-filtering concepts; no code copied or
  vendored.

See `docs/OPEN_SOURCE_SCANNER_REVIEW.md` for the engineering comparison.

## Preview assets and trademarks

The device-frame, status-bar, and keyboard images under `public/assets` are
used only to preview the companion interface during development. Product names,
device silhouettes, and trademarks remain the property of their respective
owners; their inclusion does not imply endorsement. These preview assets are
not part of the native app bundle.
