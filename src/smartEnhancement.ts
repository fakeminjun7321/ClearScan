export type SmartMode = "fast" | "quality";
export type SmartFeature = "shadow" | "deblur" | "bleed" | "flatten" | "denoise" | "upscale";

const clampByte = (value: number) => Math.max(0, Math.min(255, Math.round(value)));

function loadImage(source: string) {
  return new Promise<HTMLImageElement>((resolve, reject) => {
    const image = new Image();
    image.crossOrigin = "anonymous";
    image.onload = () => resolve(image);
    image.onerror = () => reject(new Error("문서 이미지를 불러오지 못했습니다."));
    image.src = source;
  });
}

/**
 * A real, local pixel-processing fallback for the prototype. The same API can
 * later be backed by a Core ML/TFLite model without changing the review flow.
 */
export async function enhanceDocumentImage(
  source: string,
  features: Set<SmartFeature>,
  mode: SmartMode,
) {
  const image = await loadImage(source);
  const upscale = features.has("upscale") ? 2 : 1;
  const maxSide = mode === "quality" ? 2200 : 1500;
  const sizeScale = Math.min(upscale, maxSide / Math.max(image.naturalWidth, image.naturalHeight));
  const width = Math.max(1, Math.round(image.naturalWidth * sizeScale));
  const height = Math.max(1, Math.round(image.naturalHeight * sizeScale));
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d", { willReadFrequently: true });
  if (!context) throw new Error("이미지 보정을 시작할 수 없습니다.");
  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = mode === "quality" ? "high" : "medium";
  context.drawImage(image, 0, 0, width, height);

  const frame = context.getImageData(0, 0, width, height);
  const pixels = frame.data;
  const rowLight = new Float32Array(height);
  const columnLight = new Float32Array(width);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const offset = (y * width + x) * 4;
      const light = pixels[offset] * 0.299 + pixels[offset + 1] * 0.587 + pixels[offset + 2] * 0.114;
      rowLight[y] += light / width;
      columnLight[x] += light / height;
    }
  }

  if (features.has("shadow") || features.has("flatten") || features.has("bleed") || features.has("denoise")) {
    for (let y = 0; y < height; y += 1) {
      for (let x = 0; x < width; x += 1) {
        const offset = (y * width + x) * 4;
        const red = pixels[offset];
        const green = pixels[offset + 1];
        const blue = pixels[offset + 2];
        const light = red * 0.299 + green * 0.587 + blue * 0.114;
        const localBackground = (rowLight[y] + columnLight[x]) / 2;
        let gain = 1;
        if (features.has("shadow")) gain *= Math.min(1.28, Math.max(0.94, 218 / Math.max(150, localBackground)));
        if (features.has("flatten")) {
          const edgeDistance = Math.min(x / width, (width - x) / width, y / height, (height - y) / height);
          gain *= 1 + Math.max(0, 0.12 - edgeDistance) * 0.42;
        }
        let nextRed = red * gain;
        let nextGreen = green * gain;
        let nextBlue = blue * gain;
        if (features.has("bleed") && light > 142 && Math.max(red, green, blue) - Math.min(red, green, blue) < 30) {
          const lift = Math.max(0, (light - 142) / 113) * 22;
          nextRed += lift;
          nextGreen += lift;
          nextBlue += lift;
        }
        if (features.has("denoise") && light > 205) {
          const average = (nextRed + nextGreen + nextBlue) / 3;
          nextRed = nextRed * 0.72 + average * 0.28;
          nextGreen = nextGreen * 0.72 + average * 0.28;
          nextBlue = nextBlue * 0.72 + average * 0.28;
        }
        pixels[offset] = clampByte(nextRed);
        pixels[offset + 1] = clampByte(nextGreen);
        pixels[offset + 2] = clampByte(nextBlue);
      }
    }
  }

  if (features.has("deblur")) {
    const original = new Uint8ClampedArray(pixels);
    const amount = mode === "quality" ? 0.68 : 0.38;
    for (let y = 1; y < height - 1; y += 1) {
      for (let x = 1; x < width - 1; x += 1) {
        const offset = (y * width + x) * 4;
        for (let channel = 0; channel < 3; channel += 1) {
          const center = original[offset + channel];
          const neighbours = (
            original[offset - 4 + channel] + original[offset + 4 + channel]
            + original[offset - width * 4 + channel] + original[offset + width * 4 + channel]
          ) / 4;
          pixels[offset + channel] = clampByte(center + (center - neighbours) * amount);
        }
      }
    }
  }

  context.putImageData(frame, 0, 0);
  return canvas.toDataURL("image/jpeg", mode === "quality" ? 0.94 : 0.87);
}
