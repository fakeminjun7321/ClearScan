# Document-detection cases

Detection changes should be evaluated against named cases rather than one ideal
sheet on a dark table.

## Border-filling asymmetric book spread

Characteristics:

- an open book fills almost the entire frame;
- one or more outer corners are outside the image;
- the gutter is substantially off-center;
- page curvature and gutter shadow weaken the outer rectangle;
- both pages still contain independent text/texture.

Before the book-specific recovery path, the supplied offline example selected
only the right page:

```text
source: rectangle
selected area: 0.2772
```

After the change, offline analysis of the same extracted image produced:

```text
source: bookSpreadInference
selected visible spread area: 0.9853
estimated gutter ratio: 0.6588
confidence: 0.7827
```

The private source PDF is intentionally excluded from Git. A synthetic
border-filling spread in `VisionRectangleDetectorTests` preserves the failure
shape without publishing a user's study material.

## Safety conditions

Book-spread inference is enabled only in `책 2페이지` mode. It requires:

- visible gutter darkness or a strong cross-gutter luminance transition;
- non-uniform page texture on both sides;
- a minimum combined evidence score;
- recent-frame agreement before automatic capture.

Uniform images do not activate the fallback. Single-page mode continues to
reject unsafe border-filling candidates.

## Partially clipped single page

When a single page crosses a frame edge, the detector may keep the visible
quadrilateral so the user can understand what it found and can still use
manual capture/crop. It marks the candidate unsafe when two or more corners
touch or nearly touch the frame:

- the outline changes to orange;
- the automatic-capture progress ring resets to zero;
- the UI asks the user to move until the complete document is visible;
- every agreeing sample must be safe before automatic capture can resume.

This prevents one newly safe frame from reusing an older clipped-frame
consensus. A separate oldest-to-newest span check prevents slow continuous
drift from completing the ring.

The matrix in `DetectionConditionMatrixTests` uses deterministic synthetic
images. Set `CLEARSCAN_TEST_ARTIFACTS` to a directory to save the exact PNG
inputs during a local test run.

## Still required

Offline image replay proves candidate selection and gutter estimation only. It
does not prove live-camera focus behavior, frame-to-frame stability, automatic
capture timing, or final physical-device image quality.
