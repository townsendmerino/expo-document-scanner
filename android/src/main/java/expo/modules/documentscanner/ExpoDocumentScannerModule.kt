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
import java.io.File
import java.net.URI

class ExpoDocumentScannerModule : Module() {
  private var pendingPromise: Promise? = null
  private var pendingUri: Uri? = null

  companion object {
    private const val REQUEST_CODE = 0xD05CA1
    private const val FILE_PROVIDER_SUFFIX = ".expodocumentscannerfileprovider"
  }

  override fun definition() = ModuleDefinition {
    Name("ExpoDocumentScanner")

    // Read an existing image and return it as base64. No detection, no
    // perspective correction — Android intentionally does no on-device
    // processing; the caller (e.g. an LLM) handles that downstream.
    AsyncFunction("cropDocument") { imageUri: String, promise: Promise ->
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
        promise.resolve(
          mapOf("detected" to false, "base64" to Base64.encodeToString(bytes, Base64.NO_WRAP))
        )
      } catch (e: Exception) {
        promise.reject("READ_FAILED", e.message ?: "Failed to read image at $imageUri", e)
      }
    }

    // Launch the system camera. Returns the captured image as base64,
    // unprocessed. detected=false is intentional — Android does not run
    // detection or cropping on this side.
    AsyncFunction("scanDocument") { promise: Promise ->
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
        val cacheDir = File(context.cacheDir, "expo-document-scanner").apply { mkdirs() }
        val tempFile = File(cacheDir, "scan-${System.currentTimeMillis()}.jpg")
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
        activity.startActivityForResult(intent, REQUEST_CODE)
      } catch (e: Exception) {
        promise.reject("LAUNCH_FAILED", e.message ?: "Failed to launch camera", e)
      }
    }

    OnActivityResult { _, payload ->
      if (payload.requestCode != REQUEST_CODE) return@OnActivityResult
      val promise = pendingPromise ?: return@OnActivityResult
      val uri = pendingUri
      pendingPromise = null
      pendingUri = null

      if (payload.resultCode != Activity.RESULT_OK || uri == null) {
        // User cancelled or capture failed
        promise.resolve(mapOf("detected" to false, "base64" to ""))
        return@OnActivityResult
      }

      try {
        val bytes = readBytes(uri)
        promise.resolve(
          mapOf("detected" to false, "base64" to Base64.encodeToString(bytes, Base64.NO_WRAP))
        )
      } catch (e: Exception) {
        promise.reject("READ_FAILED", e.message ?: "Failed to read captured image", e)
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
