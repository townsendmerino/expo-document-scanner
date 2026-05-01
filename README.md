# expo-document-scanner

An Expo native module for capturing documents — with on-device detection on iOS and a deliberately simple "just take a picture" path on Android.

- **iOS**: Custom `AVCaptureSession` UI with live document detection (Apple's Vision framework: `VNDetectDocumentSegmentationRequest`) driving auto-shutter, and `CIPerspectiveCorrection` to warp the captured frame to a clean rectangle.
- **Android**: System camera intent (`MediaStore.ACTION_IMAGE_CAPTURE`) — captures a photo and returns it base64-encoded with no on-device processing. Designed for handing the raw image to a downstream model (e.g. Gemini, GPT-4V) that does its own OCR and layout analysis.

## Status

Pre-1.0. iOS does on-device detection + cropping; Android intentionally does not (see [Platform behavior](#platform-behavior) below).

## Install

```sh
npm install expo-document-scanner
# or
yarn add expo-document-scanner
```

Then run a prebuild / pod install:

```sh
npx expo prebuild
cd ios && pod install
```

iOS minimum: **15.0**. Android minimum SDK: **21**. No Play Services dependency.

### Permissions

- **iOS**: `scanDocument()` opens the camera, so the consumer app's `Info.plist` must include `NSCameraUsageDescription`. `cropDocument(uri)` operates on a file URI you provide and does not require any Info.plist keys on its own.
- **Android**: `scanDocument()` launches the system camera via `ACTION_IMAGE_CAPTURE`, which has its own permission flow handled by the camera app. The module does not declare `<uses-permission android:name="android.permission.CAMERA"/>`. The module ships its own `FileProvider` (authority `${applicationId}.expodocumentscannerfileprovider`) so no consumer-side manifest changes are needed.

## Usage

```ts
import { cropDocument, scanDocument } from 'expo-document-scanner';

// Default — capture + return image as base64 (works on both platforms)
const { detected, base64 } = await scanDocument();

// Or write to disk and get a file URI back (avoids round-tripping a big
// base64 string through the JS bridge):
const { uri } = await scanDocument({ output: 'fileUri' });

// Customize the live-scanner UI (iOS only — Android delegates to the
// system camera and ignores these):
const result = await scanDocument({
  autoShutter: true,
  autoShutterMs: 2000,        // longer dwell before auto-fire
  jpegQuality: 0.85,
  maxDimension: 1560,         // cap longest edge — small OCR payloads
});

// Process an existing photo without launching a camera:
const cropped = await cropDocument(photo.uri);
```

### `scanDocument(options?): Promise<CropResult>`

Opens a camera and returns the captured image. Resolves with `{ detected: false, base64: '', uri: '' }` if the user cancels.

- **iOS**: Custom `AVCaptureSession`-based scanner with **live document detection** driving **auto-shutter** — when a document has been stably framed for the configured dwell time, the camera captures automatically. A manual shutter button is available as a fallback. The captured image is run through the same Vision document segmentation + perspective correction pipeline as `cropDocument`. Portrait-locked. `detected: true` means the warp succeeded.
- **Android**: Launches the system camera via `ACTION_IMAGE_CAPTURE`. Whatever camera app the user has handles the actual capture UX (preview, shutter, retake). Returns the captured photo unmodified. `detected` is always `false` — the module does no on-device detection or cropping. The non-UI options (`autoShutter*`, `overlay*`) are ignored.

### `cropDocument(imageUri, options?): Promise<CropResult>`

Takes a local file URI (with or without `file://`) and returns the image.

- **iOS**: Runs the same Vision document segmentation + `CIPerspectiveCorrection` pipeline used by `scanDocument`. Returns `detected: true` with the cropped JPEG, or `detected: false` with the orientation-normalized original if no document is found.
- **Android**: Just reads the file (or content URI) and returns its bytes with `detected: false`. No detection or cropping.

### Options

```ts
type ScanOutput = 'base64' | 'fileUri';

interface CommonOptions {
  /** JPEG quality 0–1. Default: 0.9. */
  jpegQuality?: number;
  /** How the result is delivered. Default: 'base64'. */
  output?: ScanOutput;
  /**
   * If set, downsample so longest edge ≤ this many pixels. Useful for
   * keeping OCR payloads small. Vision still runs on the full source —
   * only the final encode is resized. Default: unset (no resize).
   * iOS only; Android currently ignores.
   */
  maxDimension?: number;
}

interface ScanOptions extends CommonOptions {
  /** Whether the camera auto-captures on stable framing. Default: true. */
  autoShutter?: boolean;
  /** Stable-framing dwell before auto-shutter fires, in ms. Default: 1500. */
  autoShutterMs?: number;
}

type CropOptions = CommonOptions;
```

### `maxDimension`

If your downstream OCR / vision model doesn't need full-resolution input (most don't), capping the longest edge dramatically reduces the JPEG size with no quality cost for typical OCR. Vision detection still runs on the full source for accurate corner detection — only the final encode is resized, using high-quality interpolation (Lanczos on iOS).

For typical iPad rear-camera capture (~5–7 megapixels after Vision crop) and Gemini OCR:

| `maxDimension` | Encoded JPEG (q=0.9) | Notes |
|---|---|---|
| unset | 3–5 MB | Original behavior |
| 1880 | ~250–400 KB | Conservative; preserves fine handwriting detail |
| 1560 | ~150–250 KB | Matches Gemini's recommended input size |
| 1024 | ~80–120 KB | Aggressive; still fine for most printed/handwritten text |

Currently iOS only. On Android the option is accepted for API symmetry but ignored — Android delegates to the system camera and would need an extra decode/encode cycle to honor the option, which we'll add when Android grows beyond a passthrough.

### `output: 'fileUri'`

When set, the JPEG is written to a fixed path and returned as a `file://` URI:

- **iOS**: `<NSCachesDirectory>/expo-document-scanner/scan.jpg`
- **Android**: `<context.cacheDir>/expo-document-scanner/scan.jpg`

Each call **overwrites the previous file**. There's only ever one scan on disk at a time — no cleanup logic in your app, no file accumulation. iOS will purge the caches directory under disk pressure if the app is backgrounded; Android does the same.

### `CropResult`

```ts
interface CropResult {
  detected: boolean;
  /** Base64-encoded JPEG. Empty when `output: 'fileUri'`. */
  base64: string;
  /** file:// URI of the JPEG. Empty when `output: 'base64'`. */
  uri: string;
}
```

Both `base64` and `uri` are always present on success — only one is non-empty depending on the requested `output` mode.

## Platform behavior

The two platforms intentionally do different things:

| | iOS | Android |
|---|---|---|
| Camera UI | Custom AVFoundation, portrait-locked | System camera (whatever app the user has) |
| Auto-shutter on stable framing | Yes (~1.5s default, configurable) | No (system camera handles capture) |
| Manual shutter fallback | Yes | n/a — system UI |
| On-device document detection / cropping | Yes (Vision + perspective correction) | No — raw image only |
| Multi-page support | No (single image) | No |

The asymmetry is by design. iOS has Apple's Vision framework available system-wide, so it's effectively free to detect and crop on-device. Android's equivalent (ML Kit Document Scanner) ships its own scanning UI that doesn't compose well with a custom one, and adds a Play Services dependency. The simpler "just hand back the photo" approach keeps the Android side dependency-free and lets a downstream LLM handle layout interpretation.

## Roadmap

- Optional Android-side detection / cropping (CameraX-based custom scanner) for parity, gated behind a flag
- Multi-page scans (`pages: string[]` instead of a single base64)
- File-URI return option to avoid round-tripping large base64 strings through the JS bridge

## Contributing

PRs welcome. The project layout follows the standard Expo module template:

```
expo-document-scanner/
├── src/                # TypeScript surface
├── ios/                # Swift module + LiveScannerViewController
├── android/            # Kotlin module + Gradle config + FileProvider
├── ExpoDocumentScanner.podspec
├── expo-module.config.json
└── package.json
```

## License

MIT — see [LICENSE](./LICENSE).

[vision]: https://developer.apple.com/documentation/vision/vndetectdocumentsegmentationrequest
