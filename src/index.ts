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
 * Detect a document in an existing image and return a perspective-corrected
 * crop as base64 JPEG.
 *
 * - **iOS**: Uses `VNDetectDocumentSegmentationRequest` + `CIPerspectiveCorrection`.
 * - **Android**: Not supported. Use {@link scanDocument} instead, which launches
 *   the ML Kit Document Scanner UI. Calling this on Android rejects with
 *   `UNSUPPORTED_PLATFORM`.
 *
 * @param imageUri Local file URI (with or without `file://` prefix).
 */
export function cropDocument(imageUri: string): Promise<CropResult> {
  return getModule().cropDocument(imageUri);
}

/**
 * Launch a camera UI, capture a photo, and return a perspective-corrected
 * crop as base64 JPEG. Resolves with `{ detected: false, base64: '' }` if the
 * user cancels.
 *
 * - **iOS**: Presents the system `UIImagePickerController` (simple shutter +
 *   "Use Photo / Retake" flow), then runs the same Vision document
 *   segmentation + perspective correction pipeline as {@link cropDocument}.
 *   Requires `NSCameraUsageDescription` in the consumer app's `Info.plist`.
 * - **Android**: Launches Google ML Kit's bundled Document Scanner activity,
 *   which handles capture, edge detection, and perspective correction in one
 *   flow. Requires Google Play Services.
 *
 * Note: the two platforms intentionally use different UIs — iOS gets a
 * minimal "tap shutter" experience, Android gets ML Kit's full live-detection
 * scanner. Both return the same `CropResult` shape.
 */
export function scanDocument(): Promise<CropResult> {
  return getModule().scanDocument();
}
