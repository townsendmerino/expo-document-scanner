package expo.modules.documentscanner

import android.app.Activity
import android.net.Uri
import android.util.Base64
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class ExpoDocumentScannerModule : Module() {
  private var pendingPromise: Promise? = null

  companion object {
    private const val REQUEST_CODE = 0xD05CA1
  }

  override fun definition() = ModuleDefinition {
    Name("ExpoDocumentScanner")

    // Post-capture cropping is not part of the ML Kit Document Scanner API
    // surface — it bundles capture + crop together. Callers should use
    // scanDocument() on Android.
    AsyncFunction("cropDocument") { _: String, promise: Promise ->
      promise.reject(
        "UNSUPPORTED_PLATFORM",
        "cropDocument(uri) is not supported on Android. Use scanDocument() to " +
        "launch the ML Kit Document Scanner, which captures and crops in one flow.",
        null
      )
    }

    AsyncFunction("scanDocument") { promise: Promise ->
      val activity = appContext.currentActivity
      if (activity == null) {
        promise.reject("NO_ACTIVITY", "No current activity is available", null)
        return@AsyncFunction
      }
      if (pendingPromise != null) {
        promise.reject("ALREADY_RUNNING", "A document scan is already in progress", null)
        return@AsyncFunction
      }

      val options = GmsDocumentScannerOptions.Builder()
        .setGalleryImportAllowed(false)
        .setPageLimit(1)
        .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_JPEG)
        .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
        .build()

      pendingPromise = promise

      GmsDocumentScanning.getClient(options)
        .getStartScanIntent(activity)
        .addOnSuccessListener { intentSender ->
          try {
            activity.startIntentSenderForResult(intentSender, REQUEST_CODE, null, 0, 0, 0)
          } catch (e: Exception) {
            pendingPromise = null
            promise.reject("LAUNCH_FAILED", e.message ?: "Failed to launch scanner", e)
          }
        }
        .addOnFailureListener { e ->
          pendingPromise = null
          promise.reject("CLIENT_FAILED", e.message ?: "Failed to obtain scanner intent", e)
        }
    }

    OnActivityResult { _, payload ->
      if (payload.requestCode != REQUEST_CODE) return@OnActivityResult
      val promise = pendingPromise ?: return@OnActivityResult
      pendingPromise = null

      if (payload.resultCode != Activity.RESULT_OK) {
        // User cancelled or scanner failed — surface as "no document"
        promise.resolve(mapOf("detected" to false, "base64" to ""))
        return@OnActivityResult
      }

      val result = GmsDocumentScanningResult.fromActivityResultIntent(payload.data)
      val uri: Uri? = result?.pages?.firstOrNull()?.imageUri
      if (uri == null) {
        promise.resolve(mapOf("detected" to false, "base64" to ""))
        return@OnActivityResult
      }

      try {
        val bytes = readBytes(uri)
        promise.resolve(
          mapOf("detected" to true, "base64" to Base64.encodeToString(bytes, Base64.NO_WRAP))
        )
      } catch (e: Exception) {
        promise.reject("READ_FAILED", e.message ?: "Failed to read scan result", e)
      }
    }
  }

  private fun readBytes(uri: Uri): ByteArray {
    val ctx = appContext.reactContext
      ?: throw IllegalStateException("No React context available")
    return ctx.contentResolver.openInputStream(uri)?.use { it.readBytes() }
      ?: throw IllegalStateException("Could not open URI: $uri")
  }
}
