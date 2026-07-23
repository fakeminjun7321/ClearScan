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

## Still required

Offline image replay proves candidate selection and gutter estimation only. It
does not prove live-camera focus behavior, frame-to-frame stability, automatic
capture timing, or final physical-device image quality.
