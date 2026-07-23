# Roadmap

## Alpha exit criteria

- Build a privacy-safe physical-camera corpus covering light/dark desks,
  low-contrast pages, shadows, skew, partial pages, and book spreads.
- Measure detection recall, false-positive rate, time to stable capture, and
  saved-crop corner error instead of tuning only by observation.
- Verify silent video-frame capture acoustically on representative iPhone and
  iPad models.
- Verify a full native Google consent, Drive upload, and editable Docs OCR
  conversion with a contributor-owned OAuth project.
- Add deterministic camera-frame replay tests so physical failures become
  repeatable CI fixtures.

## Candidate enhancements

- Optional Core ML document segmentation fallback with published model license,
  size, latency, and evaluation data.
- Better cylindrical book dewarping and gutter shadow removal.
- Searchable PDF text layers with per-line confidence review.
- Encrypted local export bundles.

No roadmap item should be presented as implemented before its code and stated
verification level exist.
