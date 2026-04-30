# expo-document-scanner

An Expo native module for capturing, detecting, and perspective-correcting documents.

- **iOS**: Apple's [Vision framework][vision] (`VNDetectDocumentSegmentationRequest`) for document detection and `CIPerspectiveCorrection` for the warp. Camera capture uses the system `UIImagePickerController`.
- **Android**: Google's [ML Kit Document Scanner][mlkit] for the full bundled scan flow.

## Status

Pre-1.0. Both platforms expose `scanDocument()` and `cropDocument(uri)`, but they intentionally use different camera UIs — see [Platform UI differences](#platform-ui-differences).

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

iOS minimum: **15.0**. Android minimum SDK: **21**. The Android module requires Google Play Services.

### Permissions

- **iOS**: `scanDocument()` opens the system camera, so the consumer app's `Info.plist` must include `NSCameraUsageDescription`. `cropDocument(uri)` operates on a file URI you provide and does not require any Info.plist keys on its own.
- **Android**: ML Kit's Document Scanner handles its own camera permission prompt at runtime. No manifest changes required.

## Usage

```ts
import { cropDocument, scanDocument } from 'expo-document-scanner';

// Capture + crop in one call (works on both platforms)
const result = await scanDocument();
if (result.detected) {
  console.log('Cropped JPEG (base64):', result.base64.slice(0, 32), '...');
}

// Or, if you already have a photo (iOS only), just run the crop pipeline
const cropped = await cropDocument(photo.uri);
```

### `scanDocument(): Promise<CropResult>`

Opens a camera, captures a photo, and returns a perspective-corrected JPEG as base64. Resolves with `{ detected: false, base64: '' }` if the user cancels.

- **iOS**: Presents `UIImagePickerController` (system camera with shutter + "Use Photo / Retake"), then runs the captured image through the same Vision pipeline as `cropDocument`.
- **Android**: Launches ML Kit's bundled Document Scanner activity (live edge detection + auto-capture + corner adjustment + multi-page support; we return page 0).

### `cropDocument(imageUri: string): Promise<CropResult>`

iOS only. Takes a local file URI (with or without `file://`), runs document segmentation, and returns a perspective-corrected JPEG as base64.

If no document is detected, `detected` is `false` and `base64` contains the orientation-normalized original image so callers can still hand the bytes off downstream (OCR, LLM, etc.).

On Android this rejects with `UNSUPPORTED_PLATFORM` — use `scanDocument()` instead.

### `CropResult`

```ts
interface CropResult {
  detected: boolean;
  base64: string; // JPEG bytes, base64-encoded
}
```

## Platform UI differences

`scanDocument()` works on both platforms but the camera UX is intentionally different:

| | iOS (`UIImagePickerController`) | Android (ML Kit) |
|---|---|---|
| Live edge detection on preview | No | Yes |
| Auto-capture when document framed | No | Yes |
| Manual corner adjustment screen | No | Yes |
| Multi-page support | No | Yes (we return page 0) |
| Built-in retake / confirm step | Yes | Yes |

iOS gets a minimal "tap shutter, confirm" experience; Android gets ML Kit's full scanner. Both return the same `CropResult` shape, so callers don't have to branch.

## Roadmap

- Multi-page scans (`pages: string[]` instead of a single base64)
- Optional PDF result format (ML Kit supports it natively; iOS would use `PDFKit`)
- File-URI return option to avoid round-tripping large base64 strings through the JS bridge

## Contributing

PRs welcome. The project layout follows the standard Expo module template:

```
expo-document-scanner/
├── src/                # TypeScript surface
├── ios/                # Swift module
├── android/            # Kotlin module + Gradle config
├── ExpoDocumentScanner.podspec
├── expo-module.config.json
└── package.json
```

## License

MIT — see [LICENSE](./LICENSE).

[vision]: https://developer.apple.com/documentation/vision/vndetectdocumentsegmentationrequest
[mlkit]: https://developers.google.com/ml-kit/vision/doc-scanner
