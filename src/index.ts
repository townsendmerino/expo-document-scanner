import { requireNativeModule } from 'expo-modules-core';

/**
 * Where the encoded JPEG is delivered. `'base64'` returns the bytes inline
 * (default; matches the original API), `'fileUri'` writes a single
 * `scan.jpg` to the app's cache directory and returns its `file://` URI —
 * useful for avoiding round-tripping large base64 strings through the JS
 * bridge when handing the image off to a model API or upload pipeline.
 */
export type ScanOutput = 'base64' | 'fileUri';

/**
 * Options shared by both `scanDocument` and `cropDocument`.
 */
export interface CommonOptions {
  /** JPEG quality 0–1. Default: `0.9`. Lower = smaller files / lower fidelity. */
  jpegQuality?: number;
  /** How the result is delivered. Default: `'base64'`. */
  output?: ScanOutput;
}

/**
 * Options specific to `scanDocument` (the live-scanner UI). The non-UI
 * options (autoShutter*, overlay*) are honored on iOS and ignored on
 * Android (the Android scanner delegates to the system camera intent).
 */
export interface ScanOptions extends CommonOptions {
  /** Whether the camera auto-captures when the document is steady. Default: `true`. */
  autoShutter?: boolean;
  /** Milliseconds the document must remain stable before auto-capture fires. Default: `1500`. */
  autoShutterMs?: number;
  /** Overlay fill/stroke color in `#RRGGBB`. Default: `'#FFFF00'` (yellow). */
  overlayColor?: string;
  /** Fill opacity for the overlay quad, 0–1. Stroke is always full opacity. Default: `0.25`. */
  overlayOpacity?: number;
}

/**
 * Options for `cropDocument` (post-capture processing of an existing image).
 */
export type CropOptions = CommonOptions;

/**
 * Result of a document crop / scan operation.
 *
 * Both `base64` and `uri` are always present on a successful result. Which
 * one is non-empty depends on the `output` option:
 *  - `output: 'base64'` (default) → `base64` populated, `uri` empty.
 *  - `output: 'fileUri'` → `uri` populated, `base64` empty.
 *
 * On user cancel (scanDocument) both fields are empty and `detected` is
 * `false`.
 */
export interface CropResult {
  /**
   * iOS: `true` when Vision found a document and the image was
   * perspective-corrected. `false` with the orientation-normalized
   * original image otherwise.
   *
   * Android: always `false` — the Android side does no on-device
   * detection or cropping.
   */
  detected: boolean;
  /** Base64-encoded JPEG. Empty when `output: 'fileUri'`. */
  base64: string;
  /** `file://` URI of the JPEG. Empty when `output: 'base64'`. */
  uri: string;
}

interface NativeExpoDocumentScanner {
  cropDocument(imageUri: string, options: CropOptions): Promise<CropResult>;
  scanDocument(options: ScanOptions): Promise<CropResult>;
}

let _module: NativeExpoDocumentScanner | null = null;
function getModule(): NativeExpoDocumentScanner {
  if (!_module) {
    _module = requireNativeModule<NativeExpoDocumentScanner>('ExpoDocumentScanner');
  }
  return _module;
}

/**
 * Read an image and return it as a JPEG (base64 or file URI).
 *
 * - **iOS**: Detects a document with `VNDetectDocumentSegmentationRequest`
 *   and returns a perspective-corrected crop. `detected: true` if the warp
 *   succeeded, `detected: false` with the orientation-normalized original
 *   image if no document was found.
 * - **Android**: Reads the file (or content URI) and returns its bytes
 *   unmodified. Always resolves with `detected: false`.
 *
 * @param imageUri Local file URI (with or without `file://` prefix), or
 *   a `content://` URI on Android.
 * @param options Output mode and JPEG quality. See {@link CropOptions}.
 */
export function cropDocument(imageUri: string, options: CropOptions = {}): Promise<CropResult> {
  return getModule().cropDocument(imageUri, options);
}

/**
 * Launch a camera UI, capture a photo, and return the result as a JPEG.
 * Resolves with `{ detected: false, base64: '', uri: '' }` if the user
 * cancels.
 *
 * - **iOS**: Custom `AVCaptureSession` scanner with live document detection,
 *   a colored overlay highlighting the detected quad, and auto-shutter
 *   after a configurable stable-framing dwell. The captured image runs
 *   through the same Vision document segmentation + perspective correction
 *   pipeline as {@link cropDocument}. Portrait-locked. Requires
 *   `NSCameraUsageDescription` in the consumer app's `Info.plist`.
 * - **Android**: Launches the system camera via `ACTION_IMAGE_CAPTURE`.
 *   Returns the captured photo unmodified — no on-device detection or
 *   cropping. The non-UI options (`autoShutter*`, `overlay*`) are
 *   ignored on Android.
 *
 * @param options UI tuning + output. See {@link ScanOptions}.
 */
export function scanDocument(options: ScanOptions = {}): Promise<CropResult> {
  return getModule().scanDocument(options);
}
