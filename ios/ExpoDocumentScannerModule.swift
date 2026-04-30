import ExpoModulesCore
import Vision
import CoreImage
import AVFoundation
import UIKit

public class ExpoDocumentScannerModule: Module {
  // Held for the duration of a scanDocument() call so the live scanner view
  // controller isn't deallocated while it's on-screen.
  private var activeScanner: LiveScannerViewController?

  public func definition() -> ModuleDefinition {
    Name("ExpoDocumentScanner")

    AsyncFunction("cropDocument") { (imageUri: String, promise: Promise) in
      let path = imageUri.hasPrefix("file://") ? String(imageUri.dropFirst(7)) : imageUri

      guard let original = UIImage(contentsOfFile: path) else {
        promise.reject("INVALID_IMAGE", "Could not load image at \(path)")
        return
      }

      self.processImage(original, promise: promise)
    }

    AsyncFunction("scanDocument") { (promise: Promise) in
      DispatchQueue.main.async {
        guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil else {
          promise.reject(
            "CAMERA_UNAVAILABLE",
            "Camera is not available on this device (e.g. running in the simulator)"
          )
          return
        }

        guard let rootVC = Self.topViewController() else {
          promise.reject("NO_ROOT_VC", "Could not find a view controller to present from")
          return
        }

        if self.activeScanner != nil {
          promise.reject("ALREADY_RUNNING", "A document scan is already in progress")
          return
        }

        let scanner = LiveScannerViewController()
        scanner.modalPresentationStyle = .fullScreen

        scanner.onCapture = { [weak self] image in
          guard let self = self else { return }
          // Dismiss first, then run the (potentially slow) Vision pipeline.
          scanner.dismiss(animated: true) {
            self.activeScanner = nil
            self.processImage(image, promise: promise)
          }
        }
        scanner.onCancel = { [weak self] in
          guard let self = self else { return }
          scanner.dismiss(animated: true) {
            self.activeScanner = nil
            // Treat cancel as "no document" rather than rejecting, mirroring
            // the Android behavior.
            promise.resolve(["detected": false, "base64": ""])
          }
        }

        self.activeScanner = scanner
        rootVC.present(scanner, animated: true)
      }
    }
  }

  // MARK: - Vision pipeline (shared between cropDocument and scanDocument)

  private func processImage(_ original: UIImage, promise: Promise) {
    let image = original.normalizedForVision()
    guard let cgImage = image.cgImage else {
      promise.reject("INVALID_IMAGE", "No CGImage available")
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      let request = VNDetectDocumentSegmentationRequest()
      let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)

      do {
        try handler.perform([request])
      } catch {
        promise.reject("HANDLER_FAILED", error.localizedDescription)
        return
      }

      guard let obs = (request.results as? [VNRectangleObservation])?.first else {
        // No document detected — return the orientation-normalized raw image.
        guard let jpeg = image.jpegData(compressionQuality: 0.9) else {
          promise.reject("ENCODE_FAILED", "Could not encode raw image")
          return
        }
        promise.resolve(["detected": false, "base64": jpeg.base64EncodedString()])
        return
      }

      // Vision coords: bottom-left origin, normalized [0,1]
      let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
      let tl = CGPoint(x: obs.topLeft.x * w,     y: obs.topLeft.y * h)
      let tr = CGPoint(x: obs.topRight.x * w,    y: obs.topRight.y * h)
      let bl = CGPoint(x: obs.bottomLeft.x * w,  y: obs.bottomLeft.y * h)
      let br = CGPoint(x: obs.bottomRight.x * w, y: obs.bottomRight.y * h)

      let ci = CIImage(cgImage: cgImage)
      guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
        promise.reject("FILTER_FAILED", "CIPerspectiveCorrection unavailable")
        return
      }
      filter.setValue(ci,                     forKey: kCIInputImageKey)
      filter.setValue(CIVector(cgPoint: tl),  forKey: "inputTopLeft")
      filter.setValue(CIVector(cgPoint: tr),  forKey: "inputTopRight")
      filter.setValue(CIVector(cgPoint: bl),  forKey: "inputBottomLeft")
      filter.setValue(CIVector(cgPoint: br),  forKey: "inputBottomRight")

      guard let out = filter.outputImage,
            let cgOut = CIContext().createCGImage(out, from: out.extent) else {
        promise.reject("WARP_FAILED", "Perspective correction failed")
        return
      }

      guard let jpeg = UIImage(cgImage: cgOut).jpegData(compressionQuality: 0.9) else {
        promise.reject("ENCODE_FAILED", "Could not encode cropped image")
        return
      }

      promise.resolve(["detected": true, "base64": jpeg.base64EncodedString()])
    }
  }

  // MARK: - Helpers

  /// Walks the active key window's view controller chain to find the topmost
  /// presented controller — that's what we present the camera from.
  private static func topViewController() -> UIViewController? {
    let keyWindow = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first(where: { $0.isKeyWindow })

    var top = keyWindow?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}

// MARK: - UIImage orientation normalization

private extension UIImage {
  func normalizedForVision() -> UIImage {
    if imageOrientation == .up { return self }
    UIGraphicsBeginImageContextWithOptions(size, false, scale)
    draw(in: CGRect(origin: .zero, size: size))
    let normalized = UIGraphicsGetImageFromCurrentImageContext() ?? self
    UIGraphicsEndImageContext()
    return normalized
  }
}
