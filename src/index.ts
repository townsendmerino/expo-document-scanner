import { requireNativeModule } from 'expo-modules-core';

/**
 * Result of a document crop / scan operation.
 */
export interface CropResult {
  /** True if a document was detected and the image was perspective-corrected. */
  detected: boolean;
  /** Base64-encoded JPEG of the resulting image. */
  base64: string;
}

interface NativeExpoDocumentScanner {
  cropDocument(imageUri: string): Promise<CropResult>;
  scanDocument(): Promise<CropResult>;
}

let _module: NativeExpoDocumentScanner | null = null;
function getModule(): NativeExpoDocumentScanner {
  if (!_module) {
    _module = requireNativeModule<NativeExpoDocumentScanner>('ExpoDocumentScanner');
  }
  return _module;
}

/**
 * Read an image and return it as base64 JPEG.
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
 */
export function cropDocument(imageUri: string): Promise<CropResult> {
  return getModule().cropDocument(imageUri);
}

/**
 * Launch a camera UI, capture a photo, and return a perspective-corrected
 * crop as base64 JPEG. Resolves with `{ detected: false, base64: '' }` if the
 * user cancels.
 *
 * - **iOS**: Custom `AVCaptureSession` scanner with live document detection,
 *   a light-yellow overlay highlighting the detected quad, and auto-shutter
 *   after ~0.8s of stable framing (manual shutter button as fallback). The
 *   captured image runs through the same Vision document segmentation +
 *   perspective correction pipeline as {@link cropDocument}. Portrait-locked.
 *   Returns `detected: true` if the warp succeeded. Requires
 *   `NSCameraUsageDescription` in the consumer app's `Info.plist`.
 * - **Android**: Launches the system camera via `ACTION_IMAGE_CAPTURE`.
 *   Returns the captured photo unmodified — no on-device detection or
 *   cropping. Always resolves with `detected: false` (the field's name
 *   refers to "document detected", which this Android path skips).
 *
 * Both platforms return the same `CropResult` shape; the asymmetry is in
 * what `detected` means and whether the image is cropped.
 */
export function scanDocument(): Promise<CropResult> {
  return getModule().scanDocument();
}
