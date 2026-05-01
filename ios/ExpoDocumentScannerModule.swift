import ExpoModulesCore
import Vision
import CoreImage
import AVFoundation
import UIKit

// MARK: - Option records (Expo's mechanism for typed JS-side option dicts)

struct ScanDocumentOptions: Record {
  @Field var autoShutter: Bool = true
  @Field var autoShutterMs: Int = 1500
  @Field var jpegQuality: Double = 0.9
  @Field var output: String = "base64"
  /// 0 = disabled (keep full resolution); >0 = cap longest edge at this many pixels.
  @Field var maxDimension: Int = 0
}

struct CropDocumentOptions: Record {
  @Field var jpegQuality: Double = 0.9
  @Field var output: String = "base64"
  /// 0 = disabled (keep full resolution); >0 = cap longest edge at this many pixels.
  @Field var maxDimension: Int = 0
}

// MARK: - Internal value types

enum ScanOutputMode {
  case base64
  case fileUri

  static func from(_ raw: String) -> ScanOutputMode {
    return raw == "fileUri" ? .fileUri : .base64
  }
}

public class ExpoDocumentScannerModule: Module {
  // Held for the duration of a scanDocument() call so the live scanner view
  // controller isn't deallocated while it's on-screen.
  private var activeScanner: LiveScannerViewController?

  public func definition() -> ModuleDefinition {
    Name("ExpoDocumentScanner")

    AsyncFunction("cropDocument") { (imageUri: String, options: CropDocumentOptions, promise: Promise) in
      let path = imageUri.hasPrefix("file://") ? String(imageUri.dropFirst(7)) : imageUri

      guard let original = UIImage(contentsOfFile: path) else {
        promise.reject("INVALID_IMAGE", "Could not load image at \(path)")
        return
      }

      let outputMode = ScanOutputMode.from(options.output)
      let quality = Self.clampUnit(options.jpegQuality)
      let maxDim = max(0, options.maxDimension)
      self.processImage(original, output: outputMode, jpegQuality: quality, maxDimension: maxDim, promise: promise)
    }

    AsyncFunction("scanDocument") { (options: ScanDocumentOptions, promise: Promise) in
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

        // Translate JS options into the scanner's internal config. The
        // video pipeline isn't strictly 30 fps but it's close enough for
        // UX dwell calculations.
        let frames = max(1, Int((Double(options.autoShutterMs) / 1000.0) * 30.0))

        let config = LiveScannerConfig(
          autoShutter: options.autoShutter,
          autoShutterFrames: frames
        )

        let outputMode = ScanOutputMode.from(options.output)
        let quality = Self.clampUnit(options.jpegQuality)
        let maxDim = max(0, options.maxDimension)

        let scanner = LiveScannerViewController(config: config)
        scanner.modalPresentationStyle = .fullScreen

        scanner.onCapture = { [weak self] image in
          guard let self = self else { return }
          // Dismiss first, then run the (potentially slow) Vision pipeline.
          scanner.dismiss(animated: true) {
            self.activeScanner = nil
            self.processImage(image, output: outputMode, jpegQuality: quality, maxDimension: maxDim, promise: promise)
          }
        }
        scanner.onCancel = { [weak self] in
          guard let self = self else { return }
          scanner.dismiss(animated: true) {
            self.activeScanner = nil
            // Mirror Android: cancel resolves with empty fields rather than
            // rejecting, so callers can use `if (!base64 && !uri) cancel`.
            promise.resolve(["detected": false, "base64": "", "uri": ""])
          }
        }

        self.activeScanner = scanner
        rootVC.present(scanner, animated: true)
      }
    }
  }

  // MARK: - Vision pipeline (shared between cropDocument and scanDocument)

  private func processImage(
    _ original: UIImage,
    output: ScanOutputMode,
    jpegQuality: Double,
    maxDimension: Int,
    promise: Promise
  ) {
    NSLog("%@", "[ExpoDocumentScanner] processImage: enter, original size=\(original.size)")
    let image = original.normalizedForVision()
    NSLog("%@", "[ExpoDocumentScanner] processImage: normalized, size=\(image.size)")
    guard let cgImage = image.cgImage else {
      NSLog("%@", "[ExpoDocumentScanner] processImage: NO CGIMAGE")
      promise.reject("INVALID_IMAGE", "No CGImage available")
      return
    }
    NSLog("%@", "[ExpoDocumentScanner] processImage: cgImage \(cgImage.width)x\(cgImage.height)")

    DispatchQueue.global(qos: .userInitiated).async {
      NSLog("%@", "[ExpoDocumentScanner] processImage: bg queue start")

      let request = VNDetectDocumentSegmentationRequest()
      let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
      NSLog("%@", "[ExpoDocumentScanner] processImage: vision handler ready")

      do {
        try handler.perform([request])
      } catch {
        NSLog("%@", "[ExpoDocumentScanner] processImage: vision FAILED - \(error.localizedDescription)")
        promise.reject("HANDLER_FAILED", error.localizedDescription)
        return
      }
      NSLog("%@", "[ExpoDocumentScanner] processImage: vision performed, results=\(request.results?.count ?? 0)")

      let croppedImage: UIImage
      let detected: Bool

      if let obs = (request.results as? [VNRectangleObservation])?.first {
        NSLog("%@", "[ExpoDocumentScanner] processImage: doc detected, confidence=\(obs.confidence)")

        // Apply perspective correction
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let tl = CGPoint(x: obs.topLeft.x * w,     y: obs.topLeft.y * h)
        let tr = CGPoint(x: obs.topRight.x * w,    y: obs.topRight.y * h)
        let bl = CGPoint(x: obs.bottomLeft.x * w,  y: obs.bottomLeft.y * h)
        let br = CGPoint(x: obs.bottomRight.x * w, y: obs.bottomRight.y * h)

        let ci = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
          NSLog("%@", "[ExpoDocumentScanner] processImage: CIFilter unavailable")
          promise.reject("FILTER_FAILED", "CIPerspectiveCorrection unavailable")
          return
        }
        filter.setValue(ci,                     forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: tl),  forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: tr),  forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bl),  forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: br),  forKey: "inputBottomRight")
        NSLog("%@", "[ExpoDocumentScanner] processImage: CIFilter configured")

        guard let out = filter.outputImage,
              let cgOut = CIContext().createCGImage(out, from: out.extent) else {
          NSLog("%@", "[ExpoDocumentScanner] processImage: warp FAILED")
          promise.reject("WARP_FAILED", "Perspective correction failed")
          return
        }
        NSLog("%@", "[ExpoDocumentScanner] processImage: warp done, size=\(cgOut.width)x\(cgOut.height)")
        croppedImage = UIImage(cgImage: cgOut)
        detected = true
      } else {
        NSLog("%@", "[ExpoDocumentScanner] processImage: no doc detected, using original")
        croppedImage = image
        detected = false
      }

      NSLog("%@", "[ExpoDocumentScanner] processImage: about to resize, maxDim=\(maxDimension), input=\(croppedImage.size)")
      let resultImage = Self.resizeIfNeeded(croppedImage, maxDimension: maxDimension)
      NSLog("%@", "[ExpoDocumentScanner] processImage: resize done, output=\(resultImage.size)")

      guard let jpeg = resultImage.jpegData(compressionQuality: CGFloat(jpegQuality)) else {
        NSLog("%@", "[ExpoDocumentScanner] processImage: jpeg encode FAILED")
        promise.reject("ENCODE_FAILED", "Could not encode image")
        return
      }
      NSLog("%@", "[ExpoDocumentScanner] processImage: jpeg encoded, bytes=\(jpeg.count)")

      Self.deliver(jpeg: jpeg, detected: detected, output: output, promise: promise)
      NSLog("%@", "[ExpoDocumentScanner] processImage: deliver returned")
    }
  }

  /// Downsample so the longest edge ≤ maxDimension. Returns the input
  /// unchanged if maxDimension is 0 or the image is already small enough.
  /// Uses .high interpolation, which on iOS is Lanczos for downsampling.
  private static func resizeIfNeeded(_ image: UIImage, maxDimension: Int) -> UIImage {
    guard maxDimension > 0 else { return image }
    let size = image.size
    let longest = max(size.width, size.height)
    let cap = CGFloat(maxDimension)
    if longest <= cap { return image }

    let scale = cap / longest
    let newSize = CGSize(width: size.width * scale, height: size.height * scale)

    let format = UIGraphicsImageRendererFormat.default()
    // pixel-for-pixel render; ignore the device's @2x/@3x scale factor
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
    return renderer.image { ctx in
      ctx.cgContext.interpolationQuality = .high
      image.draw(in: CGRect(origin: .zero, size: newSize))
    }
  }

  // MARK: - Output delivery

  /// Resolves the promise with either base64 or a file:// URI to a JPEG
  /// at `<caches>/expo-document-scanner/scan.jpg`. The fixed filename
  /// means each call overwrites the previous file — there's only ever
  /// one scan on disk at a time, no cleanup logic required.
  private static func deliver(jpeg: Data, detected: Bool, output: ScanOutputMode, promise: Promise) {
    switch output {
    case .base64:
      promise.resolve([
        "detected": detected,
        "base64": jpeg.base64EncodedString(),
        "uri": "",
      ])

    case .fileUri:
      do {
        let url = try scratchFileURL()
        // Belt + suspenders: write atomically, also explicitly remove any
        // prior file in case its perms or partial-write state would
        // confuse readers.
        try? FileManager.default.removeItem(at: url)
        try jpeg.write(to: url, options: .atomic)
        promise.resolve([
          "detected": detected,
          "base64": "",
          "uri": url.absoluteString,
        ])
      } catch {
        promise.reject("FILE_WRITE_FAILED", error.localizedDescription)
      }
    }
  }

  private static func scratchFileURL() throws -> URL {
    let fm = FileManager.default
    let cachesDir = try fm.url(
      for: .cachesDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let dir = cachesDir.appendingPathComponent("expo-document-scanner", isDirectory: true)
    if !fm.fileExists(atPath: dir.path) {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir.appendingPathComponent("scan.jpg", isDirectory: false)
  }

  // MARK: - Helpers

  private static func clampUnit(_ x: Double) -> Double {
    return max(0.0, min(1.0, x))
  }

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
