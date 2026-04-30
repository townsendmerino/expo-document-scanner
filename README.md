# expo-document-scanner

An Expo native module for capturing documents — with on-device detection on iOS and a deliberately simple "just take a picture" path on Android.

- **iOS**: Custom `AVCaptureSession` UI with live document detection (Apple's Vision framework: `VNDetectDocumentSegmentationRequest`), a light-yellow overlay drawing the detected quad, auto-shutter, and `CIPerspectiveCorrection` to warp the captured frame to a clean rectangle.
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

// Capture + return image (works on both platforms)
const { detected, base64 } = await scanDocument();
// On iOS, `detected` is true if Vision found a document and the image was cropped.
// On Android, `detected` is always false — the image is the raw camera capture.
// Either way, `base64` contains a JPEG ready to send to your model.

// Or, if you already have a photo, just hand it back as base64
const result = await cropDocument(photo.uri);
```

### `scanDocument(): Promise<CropResult>`

Opens a camera and returns the captured image as base64 JPEG. Resolves with `{ detected: false, base64: '' }` if the user cancels.

- **iOS**: Custom `AVCaptureSession`-based scanner with **live document detection**, a **light-yellow overlay** highlighting the detected document, and **auto-shutter** — when a document has been stably framed for ~0.8 seconds, the camera captures automatically. A manual shutter button is available as a fallback. The captured image is run through the same Vision document segmentation + perspective correction pipeline as `cropDocument`. Portrait-locked. `detected: true` means the warp succeeded.
- **Android**: Launches the system camera via `ACTION_IMAGE_CAPTURE`. Whatever camera app the user has handles the actual capture UX (preview, shutter, retake). Returns the captured photo unmodified as base64. `detected` is always `false` — the module does no on-device detection or cropping.

### `cropDocument(imageUri: string): Promise<CropResult>`

Takes a local file URI (with or without `file://`) and returns the image as base64.

- **iOS**: Runs the same Vision document segmentation + `CIPerspectiveCorrection` pipeline used by `scanDocument`. Returns `detected: true` with the cropped JPEG, or `detected: false` with the orientation-normalized original if no document is found.
- **Android**: Just reads the file (or content URI) and returns its bytes as base64 with `detected: false`. No detection or cropping.

### `CropResult`

```ts
interface CropResult {
  detected: boolean;
  base64: string; // JPEG bytes, base64-encoded
}
```

## Platform behavior

The two platforms intentionally do different things:

| | iOS | Android |
|---|---|---|
| Camera UI | Custom AVFoundation, portrait-locked | System camera (whatever app the user has) |
| Live edge detection on preview | Yes (yellow quad overlay) | No |
| Auto-shutter | Yes (~0.8s stable framing) | No (system camera handles capture) |
| Manual shutter fallback | Yes (button on overlay) | n/a — system UI |
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
