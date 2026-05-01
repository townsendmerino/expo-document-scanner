package expo.modules.documentscanner

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.MediaStore
import android.util.Base64
import androidx.core.content.FileProvider
import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.records.Field
import expo.modules.kotlin.records.Record
import java.io.File
import java.net.URI

class ScanDocumentOptions : Record {
  @Field var autoShutter: Boolean = true
  @Field var autoShutterMs: Int = 1500
  @Field var overlayColor: String = "#FFFF00"
  @Field var overlayOpacity: Double = 0.25
  @Field var jpegQuality: Double = 0.9
  @Field var output: String = "base64"
}

class CropDocumentOptions : Record {
  @Field var jpegQuality: Double = 0.9
  @Field var output: String = "base64"
}

class ExpoDocumentScannerModule : Module() {
  private var pendingPromise: Promise? = null
  private var pendingUri: Uri? = null
  private var pendingOutput: String = OUTPUT_BASE64

  companion object {
    private const val REQUEST_CODE = 0xD05CA1
    private const val FILE_PROVIDER_SUFFIX = ".expodocumentscannerfileprovider"
    private const val SCAN_DIR = "expo-document-scanner"
    private const val SCAN_FILENAME = "scan.jpg"
    private const val OUTPUT_BASE64 = "base64"
    private const val OUTPUT_FILE_URI = "fileUri"
  }

  override fun definition() = ModuleDefinition {
    Name("ExpoDocumentScanner")

    // Read an existing image and return it as base64 or a file URI. No
    // detection or perspective correction — Android intentionally does no
    // on-device processing; the caller (e.g. an LLM) handles that downstream.
    AsyncFunction("cropDocument") { imageUri: String, options: CropDocumentOptions, promise: Promise ->
      val ctx = appContext.reactContext
      if (ctx == null) {
        promise.reject("NO_CONTEXT", "No React context available", null)
        return@AsyncFunction
      }
      try {
        val bytes = if (imageUri.startsWith("content://")) {
          ctx.contentResolver.openInputStream(Uri.parse(imageUri))?.use { it.readBytes() }
            ?: throw IllegalStateException("Could not open URI: $imageUri")
        } else {
          val path = if (imageUri.startsWith("file://")) URI(imageUri).path else imageUri
          File(path).readBytes()
        }
        deliver(bytes, options.output, detected = false, promise)
      } catch (e: Exception) {
        promise.reject("READ_FAILED", e.message ?: "Failed to read image at $imageUri", e)
      }
    }

    // Launch the system camera. Returns the captured image as base64 or a
    // file URI, unprocessed. detected=false is intentional — Android does
    // not run detection or cropping on this side. UI options (autoShutter,
    // overlay*) are accepted for API symmetry with iOS but ignored here
    // because the system camera owns its own UX.
    AsyncFunction("scanDocument") { options: ScanDocumentOptions, promise: Promise ->
      val activity = appContext.currentActivity
      val context = appContext.reactContext
      if (activity == null || context == null) {
        promise.reject("NO_ACTIVITY", "No current activity is available", null)
        return@AsyncFunction
      }
      if (pendingPromise != null) {
        promise.reject("ALREADY_RUNNING", "A document scan is already in progress", null)
        return@AsyncFunction
      }

      try {
        // Fixed filename — each scan overwrites the previous, so there's
        // only ever one file on disk. No cleanup logic needed.
        val cacheDir = File(context.cacheDir, SCAN_DIR).apply { mkdirs() }
        val tempFile = File(cacheDir, SCAN_FILENAME)
        if (tempFile.exists()) tempFile.delete()
        val authority = "${context.packageName}$FILE_PROVIDER_SUFFIX"
        val uri = FileProvider.getUriForFile(context, authority, tempFile)

        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
          putExtra(MediaStore.EXTRA_OUTPUT, uri)
          addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
          addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        if (intent.resolveActivity(context.packageManager) == null) {
          promise.reject(
            "CAMERA_UNAVAILABLE",
            "No camera app is available to handle ACTION_IMAGE_CAPTURE",
            null
          )
          return@AsyncFunction
        }

        pendingPromise = promise
        pendingUri = uri
        pendingOutput = if (options.output == OUTPUT_FILE_URI) OUTPUT_FILE_URI else OUTPUT_BASE64
        activity.startActivityForResult(intent, REQUEST_CODE)
      } catch (e: Exception) {
        promise.reject("LAUNCH_FAILED", e.message ?: "Failed to launch camera", e)
      }
    }

    OnActivityResult { _, payload ->
      if (payload.requestCode != REQUEST_CODE) return@OnActivityResult
      val promise = pendingPromise ?: return@OnActivityResult
      val uri = pendingUri
      val output = pendingOutput
      pendingPromise = null
      pendingUri = null

      if (payload.resultCode != Activity.RESULT_OK || uri == null) {
        // User cancelled or capture failed — empty fields.
        promise.resolve(mapOf("detected" to false, "base64" to "", "uri" to ""))
        return@OnActivityResult
      }

      try {
        when (output) {
          OUTPUT_FILE_URI -> {
            // Camera wrote directly to the FileProvider URI we handed it.
            // Return that URI; no need to re-encode.
            promise.resolve(mapOf("detected" to false, "base64" to "", "uri" to uri.toString()))
          }
          else -> {
            val bytes = readBytes(uri)
            promise.resolve(
              mapOf(
                "detected" to false,
                "base64" to Base64.encodeToString(bytes, Base64.NO_WRAP),
                "uri" to "",
              )
            )
          }
        }
      } catch (e: Exception) {
        promise.reject("READ_FAILED", e.message ?: "Failed to read captured image", e)
      }
    }
  }

  /// Encodes `bytes` per the requested output mode and resolves the promise.
  /// `fileUri` writes to <cache>/expo-document-scanner/scan.jpg, overwriting
  /// any previous scan.
  private fun deliver(bytes: ByteArray, output: String, detected: Boolean, promise: Promise) {
    if (output == OUTPUT_FILE_URI) {
      try {
        val ctx = appContext.reactContext
          ?: throw IllegalStateException("No React context available")
        val cacheDir = File(ctx.cacheDir, SCAN_DIR).apply { mkdirs() }
        val outFile = File(cacheDir, SCAN_FILENAME)
        if (outFile.exists()) outFile.delete()
        outFile.writeBytes(bytes)
        promise.resolve(
          mapOf(
            "detected" to detected,
            "base64" to "",
            "uri" to "file://${outFile.absolutePath}",
          )
        )
      } catch (e: Exception) {
        promise.reject("FILE_WRITE_FAILED", e.message ?: "Failed to write image", e)
      }
    } else {
      promise.resolve(
        mapOf(
          "detected" to detected,
          "base64" to Base64.encodeToString(bytes, Base64.NO_WRAP),
          "uri" to "",
        )
      )
    }
  }

  private fun readBytes(uri: Uri): ByteArray {
    val ctx = appContext.reactContext
      ?: throw IllegalStateException("No React context available")
    return ctx.contentResolver.openInputStream(uri)?.use { it.readBytes() }
      ?: throw IllegalStateException("Could not open URI: $uri")
  }
}
