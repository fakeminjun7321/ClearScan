export type NormalizedPoint = { x: number; y: number };

export type DocumentDetection = {
  corners: [NormalizedPoint, NormalizedPoint, NormalizedPoint, NormalizedPoint];
  confidence: number;
  coverage: number;
};

type DetectableImage = HTMLImageElement | HTMLVideoElement;

const clamp = (value: number, min = 0, max = 1) => Math.min(max, Math.max(min, value));

function median(values: number[]) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle];
}

function percentile(values: Uint8Array, ratio: number) {
  const histogram = new Uint32Array(256);
  for (const value of values) histogram[value] += 1;
  const target = values.length * ratio;
  let seen = 0;
  for (let value = 0; value < histogram.length; value += 1) {
    seen += histogram[value];
    if (seen >= target) return value;
  }
  return 255;
}

/**
 * Finds a bright, low-saturation paper region in a camera frame. This is a
 * deterministic document detector: AI enhancement is intentionally kept out
 * of the capture loop so scanning stays fast and offline.
 */
export function detectDocument(source: DetectableImage): DocumentDetection | null {
  const sourceWidth = source instanceof HTMLVideoElement ? source.videoWidth : source.naturalWidth;
  const sourceHeight = source instanceof HTMLVideoElement ? source.videoHeight : source.naturalHeight;
  if (!sourceWidth || !sourceHeight) return null;

  const width = 180;
  const height = Math.max(120, Math.round((sourceHeight / sourceWidth) * width));
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d", { willReadFrequently: true });
  if (!context) return null;

  context.drawImage(source, 0, 0, width, height);
  const pixels = context.getImageData(0, 0, width, height).data;
  const luminance = new Uint8Array(width * height);
  const saturation = new Uint8Array(width * height);

  for (let index = 0, pixel = 0; index < pixels.length; index += 4, pixel += 1) {
    const red = pixels[index];
    const green = pixels[index + 1];
    const blue = pixels[index + 2];
    luminance[pixel] = Math.round(red * 0.299 + green * 0.587 + blue * 0.114);
    saturation[pixel] = Math.max(red, green, blue) - Math.min(red, green, blue);
  }

  const dark = percentile(luminance, 0.28);
  const light = percentile(luminance, 0.82);
  const dynamicRange = light - dark;
  // A blank wall or an overexposed frame can be bright and low-saturation too.
  if (dynamicRange < 18) return null;
  const threshold = Math.max(105, Math.round(dark + (light - dark) * 0.5));
  const rows: Array<{ y: number; left: number; right: number; count: number }> = [];

  for (let y = 0; y < height; y += 1) {
    let left = width;
    let right = -1;
    let count = 0;
    for (let x = 0; x < width; x += 1) {
      const pixel = y * width + x;
      const looksLikePaper = luminance[pixel] >= threshold && saturation[pixel] < 72;
      if (!looksLikePaper) continue;
      left = Math.min(left, x);
      right = Math.max(right, x);
      count += 1;
    }

    if (count >= width * 0.34 && right - left >= width * 0.42) {
      rows.push({ y, left, right, count });
    }
  }

  if (rows.length < height * 0.34) return null;

  const topY = rows[0].y;
  const bottomY = rows[rows.length - 1].y;
  const bandHeight = Math.max(4, Math.round(rows.length * 0.1));
  const topBand = rows.slice(0, bandHeight);
  const bottomBand = rows.slice(-bandHeight);
  const topLeft = median(topBand.map((row) => row.left));
  const topRight = median(topBand.map((row) => row.right));
  const bottomLeft = median(bottomBand.map((row) => row.left));
  const bottomRight = median(bottomBand.map((row) => row.right));
  const averageWidth = ((topRight - topLeft) + (bottomRight - bottomLeft)) / 2;
  const coverage = clamp((averageWidth * (bottomY - topY)) / (width * height));
  if (coverage < 0.16 || coverage > 0.93) return null;

  const boundaryRows = rows.filter((row) => row.left <= 2 || row.right >= width - 3).length;
  const borderTouchRatio = boundaryRows / rows.length;
  if (borderTouchRatio > 0.72) return null;

  const edgeSamples: number[] = [];
  for (const row of rows.filter((_, index) => index % 3 === 0)) {
    if (row.left > 1) edgeSamples.push(Math.abs(luminance[row.y * width + row.left] - luminance[row.y * width + row.left - 2]));
    if (row.right < width - 2) edgeSamples.push(Math.abs(luminance[row.y * width + row.right] - luminance[row.y * width + row.right + 2]));
  }
  const edgeSupport = clamp(median(edgeSamples) / 44);
  const contrast = clamp((light - dark) / 155);
  const rowContinuity = clamp(rows.length / Math.max(1, bottomY - topY + 1));
  const borderScore = 1 - borderTouchRatio;
  const confidence = clamp(coverage * 0.3 + contrast * 0.22 + rowContinuity * 0.18 + edgeSupport * 0.2 + borderScore * 0.1);

  if (confidence < 0.58) return null;

  return {
    corners: [
      { x: clamp(topLeft / (width - 1)), y: clamp(topY / (height - 1)) },
      { x: clamp(topRight / (width - 1)), y: clamp(topY / (height - 1)) },
      { x: clamp(bottomRight / (width - 1)), y: clamp(bottomY / (height - 1)) },
      { x: clamp(bottomLeft / (width - 1)), y: clamp(bottomY / (height - 1)) },
    ],
    confidence,
    coverage,
  };
}

export function drawDocumentDetection(
  canvas: HTMLCanvasElement,
  detection: DocumentDetection,
  width: number,
  height: number,
  sourceWidth = width,
  sourceHeight = height,
  splitSpread = false,
  splitRatio = 0.5,
) {
  const ratio = Math.max(1, window.devicePixelRatio || 1);
  canvas.width = Math.round(width * ratio);
  canvas.height = Math.round(height * ratio);
  canvas.style.width = `${width}px`;
  canvas.style.height = `${height}px`;
  const context = canvas.getContext("2d");
  if (!context) return;
  context.scale(ratio, ratio);
  context.clearRect(0, 0, width, height);

  const scale = Math.max(width / sourceWidth, height / sourceHeight);
  const renderedWidth = sourceWidth * scale;
  const renderedHeight = sourceHeight * scale;
  const offsetX = (width - renderedWidth) / 2;
  const offsetY = (height - renderedHeight) * 0.42;
  const points = detection.corners.map((point) => ({
    x: offsetX + point.x * renderedWidth,
    y: offsetY + point.y * renderedHeight,
  }));
  context.save();
  context.strokeStyle = "#3f82ff";
  context.lineWidth = 2.2;
  context.shadowColor = "rgba(35, 111, 255, 0.32)";
  context.shadowBlur = 10;
  context.beginPath();
  context.moveTo(points[0].x, points[0].y);
  points.slice(1).forEach((point) => context.lineTo(point.x, point.y));
  context.closePath();
  context.stroke();
  context.restore();

  points.forEach((point) => {
    context.beginPath();
    context.arc(point.x, point.y, 7, 0, Math.PI * 2);
    context.fillStyle = "#ffffff";
    context.fill();
    context.lineWidth = 4;
    context.strokeStyle = "#2e77ff";
    context.stroke();
  });

  if (splitSpread) {
    const topCenter = { x: points[0].x + (points[1].x - points[0].x) * splitRatio, y: points[0].y + (points[1].y - points[0].y) * splitRatio };
    const bottomCenter = { x: points[3].x + (points[2].x - points[3].x) * splitRatio, y: points[3].y + (points[2].y - points[3].y) * splitRatio };
    context.save();
    context.setLineDash([8, 7]);
    context.strokeStyle = "rgba(255,255,255,0.92)";
    context.lineWidth = 1.5;
    context.beginPath();
    context.moveTo(topCenter.x, topCenter.y);
    context.lineTo(bottomCenter.x, bottomCenter.y);
    context.stroke();
    context.restore();
  }
}

function affineTransform(
  source: Array<{ x: number; y: number }>,
  destination: Array<{ x: number; y: number }>,
) {
  const [s0, s1, s2] = source;
  const [d0, d1, d2] = destination;
  const denominator = s0.x * (s1.y - s2.y) + s1.x * (s2.y - s0.y) + s2.x * (s0.y - s1.y);
  if (Math.abs(denominator) < 0.001) return null;
  const solve = (v0: number, v1: number, v2: number) => ({
    a: (v0 * (s1.y - s2.y) + v1 * (s2.y - s0.y) + v2 * (s0.y - s1.y)) / denominator,
    c: (v0 * (s2.x - s1.x) + v1 * (s0.x - s2.x) + v2 * (s1.x - s0.x)) / denominator,
    e: (v0 * (s1.x * s2.y - s2.x * s1.y) + v1 * (s2.x * s0.y - s0.x * s2.y) + v2 * (s0.x * s1.y - s1.x * s0.y)) / denominator,
  });
  const x = solve(d0.x, d1.x, d2.x);
  const y = solve(d0.y, d1.y, d2.y);
  return { a: x.a, b: y.a, c: x.c, d: y.c, e: x.e, f: y.e };
}

export function rectifyDocument(source: DetectableImage, detection: DocumentDetection | null) {
  const sourceWidth = source instanceof HTMLVideoElement ? source.videoWidth : source.naturalWidth;
  const sourceHeight = source instanceof HTMLVideoElement ? source.videoHeight : source.naturalHeight;
  if (!sourceWidth || !sourceHeight) return null;

  if (!detection) {
    const raw = document.createElement("canvas");
    raw.width = sourceWidth;
    raw.height = sourceHeight;
    raw.getContext("2d")?.drawImage(source, 0, 0);
    return raw.toDataURL("image/jpeg", 0.92);
  }

  const sourcePoints = detection.corners.map((point) => ({ x: point.x * sourceWidth, y: point.y * sourceHeight }));
  const distance = (a: { x: number; y: number }, b: { x: number; y: number }) => Math.hypot(a.x - b.x, a.y - b.y);
  const naturalWidth = (distance(sourcePoints[0], sourcePoints[1]) + distance(sourcePoints[3], sourcePoints[2])) / 2;
  const naturalHeight = (distance(sourcePoints[0], sourcePoints[3]) + distance(sourcePoints[1], sourcePoints[2])) / 2;
  const limitScale = Math.min(1, 1800 / Math.max(naturalWidth, naturalHeight));
  const outputWidth = Math.max(320, Math.round(naturalWidth * limitScale));
  const outputHeight = Math.max(420, Math.round(naturalHeight * limitScale));
  const destinationPoints = [
    { x: 0, y: 0 },
    { x: outputWidth, y: 0 },
    { x: outputWidth, y: outputHeight },
    { x: 0, y: outputHeight },
  ];
  const canvas = document.createElement("canvas");
  canvas.width = outputWidth;
  canvas.height = outputHeight;
  const context = canvas.getContext("2d");
  if (!context) return null;
  context.fillStyle = "#fff";
  context.fillRect(0, 0, outputWidth, outputHeight);

  ([[0, 1, 2], [0, 2, 3]] as const).forEach((indices) => {
    const sourceTriangle = indices.map((index) => sourcePoints[index]);
    const destinationTriangle = indices.map((index) => destinationPoints[index]);
    const transform = affineTransform(sourceTriangle, destinationTriangle);
    if (!transform) return;
    context.save();
    context.beginPath();
    context.moveTo(destinationTriangle[0].x, destinationTriangle[0].y);
    context.lineTo(destinationTriangle[1].x, destinationTriangle[1].y);
    context.lineTo(destinationTriangle[2].x, destinationTriangle[2].y);
    context.closePath();
    context.clip();
    context.setTransform(transform.a, transform.b, transform.c, transform.d, transform.e, transform.f);
    context.drawImage(source, 0, 0);
    context.restore();
  });

  return canvas.toDataURL("image/jpeg", 0.92);
}

export async function rectifyBookSpread(source: DetectableImage, detection: DocumentDetection | null, splitRatio = 0.5) {
  const spreadUrl = rectifyDocument(source, detection);
  if (!spreadUrl) return null;
  const spread = await new Promise<HTMLImageElement>((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = reject;
    image.src = spreadUrl;
  });
  const gutterTrim = Math.max(2, Math.round(spread.naturalWidth * 0.008));
  const halfWidth = Math.round(spread.naturalWidth * clamp(splitRatio, 0.3, 0.7));
  const makePage = (side: "left" | "right") => {
    const sourceX = side === "left" ? 0 : halfWidth + gutterTrim;
    const sourceWidth = side === "left" ? halfWidth - gutterTrim : spread.naturalWidth - halfWidth - gutterTrim;
    const canvas = document.createElement("canvas");
    canvas.width = sourceWidth;
    canvas.height = spread.naturalHeight;
    canvas.getContext("2d")?.drawImage(spread, sourceX, 0, sourceWidth, spread.naturalHeight, 0, 0, sourceWidth, spread.naturalHeight);
    return canvas.toDataURL("image/jpeg", 0.92);
  };
  return [makePage("left"), makePage("right")] as const;
}

export async function detectBookGutter(source: DetectableImage, detection: DocumentDetection | null) {
  const spreadUrl = rectifyDocument(source, detection);
  if (!spreadUrl) return 0.5;
  const spread = await new Promise<HTMLImageElement>((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = reject;
    image.src = spreadUrl;
  });
  const width = 220;
  const height = Math.max(120, Math.round(spread.naturalHeight / spread.naturalWidth * width));
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d", { willReadFrequently: true });
  if (!context) return 0.5;
  context.drawImage(spread, 0, 0, width, height);
  const pixels = context.getImageData(0, 0, width, height).data;
  let bestX = Math.round(width / 2);
  let bestScore = Number.NEGATIVE_INFINITY;
  for (let x = Math.round(width * 0.36); x <= Math.round(width * 0.64); x += 1) {
    let light = 0;
    let samples = 0;
    for (let y = Math.round(height * 0.12); y < Math.round(height * 0.9); y += 2) {
      const offset = (y * width + x) * 4;
      light += pixels[offset] * 0.299 + pixels[offset + 1] * 0.587 + pixels[offset + 2] * 0.114;
      samples += 1;
    }
    const average = light / Math.max(1, samples);
    const centerPenalty = Math.abs(x / width - 0.5) * 75;
    const score = 255 - average - centerPenalty;
    if (score > bestScore) {
      bestScore = score;
      bestX = x;
    }
  }
  return clamp(bestX / width, 0.36, 0.64);
}
