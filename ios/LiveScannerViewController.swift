import AVFoundation
import UIKit
import Vision

/// Configuration passed in from the JS-facing module — driven by ScanOptions.
struct LiveScannerConfig {
  var autoShutter: Bool = true
  var autoShutterFrames: Int = 45
  var overlayFillColor: UIColor = UIColor.yellow.withAlphaComponent(0.25)
  var overlayStrokeColor: UIColor = .yellow
  var overlayLineWidth: CGFloat = 2
}

/// A simple full-screen camera with live document detection, auto-shutter,
/// and a colored overlay highlighting the detected document.
///
/// Result delivery is via the two callbacks. Exactly one is invoked.
final class LiveScannerViewController: UIViewController {

  // MARK: Public callbacks

  var onCapture: ((UIImage) -> Void)?
  var onCancel: (() -> Void)?

  // MARK: Configuration

  let config: LiveScannerConfig

  init(config: LiveScannerConfig = LiveScannerConfig()) {
    self.config = config
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: AVFoundation

  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "expo-document-scanner.session")
  private let videoOutput = AVCaptureVideoDataOutput()
  private let photoOutput = AVCapturePhotoOutput()
  private var previewLayer: AVCaptureVideoPreviewLayer!

  // MARK: Detection state

  /// Most recent observation, used both to draw the overlay and to track
  /// stability for auto-shutter.
  private var lastObservation: VNRectangleObservation?
  /// Frame count over which the quad has been stable (within tolerance).
  private var stableFrameCount = 0
  /// Once we've fired the shutter, we ignore subsequent detections.
  private var hasCaptured = false

  /// Per-corner tolerance (in normalized [0,1] space) for "still stable".
  /// Not exposed via ScanOptions — most users don't have intuition for this
  /// value; tuning it is reserved for module maintainers.
  private let stabilityTolerance: CGFloat = 0.015

  // MARK: Diagnostic logging

  /// Frame counter used to gate diagnostic prints to roughly 1Hz.
  private var loggedFrameCounter = 0
  /// Print every Nth frame's data to the console. ~30fps → ~1 second.
  private let logEveryNthFrame = 30

  // MARK: UI

  private let overlayLayer = CAShapeLayer()
  private let captionLabel = UILabel()
  private let cancelButton = UIButton(type: .system)
  private let shutterButton = UIButton(type: .custom)
  private let flashView = UIView()

  // MARK: Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    setupSession()
    setupPreview()
    setupOverlay()
    setupChrome()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    sessionQueue.async { [weak self] in
      self?.session.startRunning()
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    sessionQueue.async { [weak self] in
      self?.session.stopRunning()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer.frame = view.bounds
    overlayLayer.frame = view.bounds
    flashView.frame = view.bounds
  }

  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
  override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }

  // MARK: Session setup

  private func setupSession() {
    session.beginConfiguration()
    session.sessionPreset = .photo

    guard
      let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
      let input = try? AVCaptureDeviceInput(device: device),
      session.canAddInput(input)
    else {
      session.commitConfiguration()
      return
    }
    session.addInput(input)

    // Live frames → Vision
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "expo-document-scanner.video"))
    if session.canAddOutput(videoOutput) {
      session.addOutput(videoOutput)
      // Keep frames upright so the overlay math stays simple. The
      // videoOrientation property is deprecated and silently no-ops on iOS
      // 17+, leaving frames in the camera's native landscape — which then
      // skews the on-screen overlay against the portrait preview. Use
      // videoRotationAngle on iOS 17+ to actually rotate the buffer.
      if let conn = videoOutput.connection(with: .video) {
        Self.applyPortraitOrientation(to: conn)
      }
    }

    // Still photo capture
    if session.canAddOutput(photoOutput) {
      session.addOutput(photoOutput)
    }

    session.commitConfiguration()
  }

  private func setupPreview() {
    previewLayer = AVCaptureVideoPreviewLayer(session: session)
    previewLayer.videoGravity = .resizeAspectFill
    if let conn = previewLayer.connection {
      Self.applyPortraitOrientation(to: conn)
    }
    view.layer.addSublayer(previewLayer)
  }

  /// Rotates the connection's output to portrait, using whichever API is
  /// available for the running iOS version. videoOrientation is deprecated
  /// on iOS 17+ and silently no-ops there; videoRotationAngle is the
  /// replacement. Without using both APIs, the preview and the video buffer
  /// can disagree on orientation, which skews the overlay against the
  /// document.
  private static func applyPortraitOrientation(to connection: AVCaptureConnection) {
    if #available(iOS 17.0, *) {
      let portraitAngle: CGFloat = 90
      if connection.isVideoRotationAngleSupported(portraitAngle) {
        connection.videoRotationAngle = portraitAngle
        return
      }
    }
    if connection.isVideoOrientationSupported {
      connection.videoOrientation = .portrait
    }
  }

  private func setupOverlay() {
    overlayLayer.fillColor = config.overlayFillColor.cgColor
    overlayLayer.strokeColor = config.overlayStrokeColor.cgColor
    overlayLayer.lineWidth = config.overlayLineWidth
    overlayLayer.lineJoin = .round
    overlayLayer.frame = view.bounds
    view.layer.addSublayer(overlayLayer)

    flashView.backgroundColor = .white
    flashView.alpha = 0
    flashView.isUserInteractionEnabled = false
    view.addSubview(flashView)
  }

  private func setupChrome() {
    // Caption
    captionLabel.translatesAutoresizingMaskIntoConstraints = false
    captionLabel.text = "Position document in frame"
    captionLabel.textColor = .white
    captionLabel.font = .systemFont(ofSize: 16, weight: .medium)
    captionLabel.textAlignment = .center
    captionLabel.numberOfLines = 0
    captionLabel.layer.shadowColor = UIColor.black.cgColor
    captionLabel.layer.shadowOpacity = 0.6
    captionLabel.layer.shadowOffset = .zero
    captionLabel.layer.shadowRadius = 3
    view.addSubview(captionLabel)

    // Cancel
    cancelButton.translatesAutoresizingMaskIntoConstraints = false
    let xConfig = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
    cancelButton.setImage(UIImage(systemName: "xmark", withConfiguration: xConfig), for: .normal)
    cancelButton.tintColor = .white
    cancelButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
    cancelButton.layer.cornerRadius = 22
    cancelButton.addTarget(self, action: #selector(handleCancelTap), for: .touchUpInside)
    view.addSubview(cancelButton)

    // Shutter
    shutterButton.translatesAutoresizingMaskIntoConstraints = false
    shutterButton.backgroundColor = .white
    shutterButton.layer.cornerRadius = 36
    shutterButton.layer.borderWidth = 4
    shutterButton.layer.borderColor = UIColor.white.cgColor
    shutterButton.layer.shadowColor = UIColor.black.cgColor
    shutterButton.layer.shadowOpacity = 0.4
    shutterButton.layer.shadowRadius = 4
    shutterButton.addTarget(self, action: #selector(handleShutterTap), for: .touchUpInside)
    view.addSubview(shutterButton)

    NSLayoutConstraint.activate([
      captionLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      captionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      captionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

      cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      cancelButton.widthAnchor.constraint(equalToConstant: 44),
      cancelButton.heightAnchor.constraint(equalToConstant: 44),

      shutterButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
      shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      shutterButton.widthAnchor.constraint(equalToConstant: 72),
      shutterButton.heightAnchor.constraint(equalToConstant: 72),
    ])
  }

  // MARK: Actions

  @objc private func handleCancelTap() {
    onCancel?()
  }

  @objc private func handleShutterTap() {
    capturePhoto()
  }

  // MARK: Auto-shutter

  /// Compares two observations corner-by-corner and reports whether they're
  /// within `stabilityTolerance`. Both points are in normalized image space.
  private func observationsAreStable(_ a: VNRectangleObservation, _ b: VNRectangleObservation) -> Bool {
    let tol = stabilityTolerance
    return abs(a.topLeft.x     - b.topLeft.x)     < tol &&
           abs(a.topLeft.y     - b.topLeft.y)     < tol &&
           abs(a.topRight.x    - b.topRight.x)    < tol &&
           abs(a.topRight.y    - b.topRight.y)    < tol &&
           abs(a.bottomLeft.x  - b.bottomLeft.x)  < tol &&
           abs(a.bottomLeft.y  - b.bottomLeft.y)  < tol &&
           abs(a.bottomRight.x - b.bottomRight.x) < tol &&
           abs(a.bottomRight.y - b.bottomRight.y) < tol
  }

  private func updateStabilityCounter(with observation: VNRectangleObservation?) {
    guard let observation = observation else {
      stableFrameCount = 0
      return
    }
    if let prev = lastObservation, observationsAreStable(prev, observation) {
      stableFrameCount += 1
    } else {
      stableFrameCount = 1
    }
    lastObservation = observation
  }

  // MARK: Photo capture

  private func capturePhoto() {
    guard !hasCaptured else { return }
    hasCaptured = true

    // Brief flash to signal capture
    flashView.alpha = 0.85
    UIView.animate(withDuration: 0.25) { [weak self] in
      self?.flashView.alpha = 0
    }
    captionLabel.text = "Capturing…"

    let settings = AVCapturePhotoSettings()
    photoOutput.capturePhoto(with: settings, delegate: self)
  }

  // MARK: Overlay drawing

  /// Maps a Vision-normalized corner (bottom-left origin) into preview-layer
  /// view coordinates, accounting for .resizeAspectFill cropping. We bypass
  /// AVCaptureVideoPreviewLayer.layerPointConverted(fromCaptureDevicePoint:)
  /// entirely because its docs leave the coordinate-space semantics ambiguous
  /// when the connection has rotation applied — this function is fully
  /// deterministic given the actual buffer dimensions and the layer bounds.
  private func toView(_ visionPoint: CGPoint, bufferSize: CGSize) -> CGPoint {
    // Vision: bottom-left origin, normalized [0,1] → flip to top-left.
    let nx = visionPoint.x
    let ny = 1.0 - visionPoint.y

    let layerSize = previewLayer.bounds.size
    guard bufferSize.width > 0, bufferSize.height > 0,
          layerSize.width > 0, layerSize.height > 0 else {
      return .zero
    }

    // .resizeAspectFill: scale until the SHORTER dimension fills the layer,
    // then crop the longer dimension. Each side gets cropped equally.
    let scale = max(layerSize.width / bufferSize.width,
                    layerSize.height / bufferSize.height)
    let displayedW = bufferSize.width * scale
    let displayedH = bufferSize.height * scale
    let offsetX = (layerSize.width - displayedW) / 2
    let offsetY = (layerSize.height - displayedH) / 2

    return CGPoint(
      x: offsetX + nx * displayedW,
      y: offsetY + ny * displayedH
    )
  }

  /// Draws the quad on screen using the manual transform above. When
  /// `debugLog` is true, prints buffer dims, layer dims, and transformed
  /// view points so we can correlate what's drawn with what Vision saw.
  private func drawOverlay(
    for observation: VNRectangleObservation?,
    bufferSize: CGSize,
    debugLog: Bool = false
  ) {
    guard let observation = observation else {
      overlayLayer.path = nil
      return
    }

    let tl = toView(observation.topLeft,    bufferSize: bufferSize)
    let tr = toView(observation.topRight,   bufferSize: bufferSize)
    let bl = toView(observation.bottomLeft, bufferSize: bufferSize)
    let br = toView(observation.bottomRight, bufferSize: bufferSize)

    if debugLog {
      let f = previewLayer.frame
      print(String(
        format: "[ExpoDocumentScanner] view tl=(%.1f, %.1f) tr=(%.1f, %.1f) bl=(%.1f, %.1f) br=(%.1f, %.1f) preview=(%.1f, %.1f, %.1f x %.1f) buffer=%.0fx%.0f",
        tl.x, tl.y, tr.x, tr.y, bl.x, bl.y, br.x, br.y,
        f.origin.x, f.origin.y, f.width, f.height,
        bufferSize.width, bufferSize.height
      ))
    }

    let path = UIBezierPath()
    path.move(to: tl)
    path.addLine(to: tr)
    path.addLine(to: br)
    path.addLine(to: bl)
    path.close()
    overlayLayer.path = path.cgPath
  }

  private func updateCaption(detected: Bool, stableFrames: Int) {
    if hasCaptured { return }
    if !detected {
      captionLabel.text = "Position document in frame"
    } else if config.autoShutter && stableFrames < config.autoShutterFrames {
      captionLabel.text = "Hold steady…"
    } else if config.autoShutter {
      captionLabel.text = "Capturing…"
    } else {
      // Auto-shutter disabled — just confirm we see the document.
      captionLabel.text = "Tap shutter to capture"
    }
  }
}

// MARK: - Live frame processing

extension LiveScannerViewController: AVCaptureVideoDataOutputSampleBufferDelegate {

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    if hasCaptured { return }
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    loggedFrameCounter += 1
    let shouldLog = (loggedFrameCounter % logEveryNthFrame) == 0

    let bufferSize = CGSize(
      width: CVPixelBufferGetWidth(pixelBuffer),
      height: CVPixelBufferGetHeight(pixelBuffer)
    )

    if shouldLog {
      print("[ExpoDocumentScanner] buffer=\(Int(bufferSize.width))x\(Int(bufferSize.height))")
    }

    let request = VNDetectDocumentSegmentationRequest()
    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
    do {
      try handler.perform([request])
    } catch {
      return
    }

    let observation = (request.results as? [VNRectangleObservation])?.first

    if shouldLog, let obs = observation {
      print(String(
        format: "[ExpoDocumentScanner] obs tl=(%.3f, %.3f) tr=(%.3f, %.3f) bl=(%.3f, %.3f) br=(%.3f, %.3f) confidence=%.2f",
        obs.topLeft.x, obs.topLeft.y,
        obs.topRight.x, obs.topRight.y,
        obs.bottomLeft.x, obs.bottomLeft.y,
        obs.bottomRight.x, obs.bottomRight.y,
        obs.confidence
      ))
    } else if shouldLog {
      print("[ExpoDocumentScanner] obs (none detected)")
    }

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.updateStabilityCounter(with: observation)
      self.drawOverlay(for: observation, bufferSize: bufferSize, debugLog: shouldLog)
      self.updateCaption(detected: observation != nil, stableFrames: self.stableFrameCount)

      if !self.hasCaptured,
         self.config.autoShutter,
         observation != nil,
         self.stableFrameCount >= self.config.autoShutterFrames {
        self.capturePhoto()
      }
    }
  }
}

// MARK: - Photo capture delegate

extension LiveScannerViewController: AVCapturePhotoCaptureDelegate {

  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    guard error == nil,
          let data = photo.fileDataRepresentation(),
          let image = UIImage(data: data)
    else {
      // Reset capture state so the user can retry
      hasCaptured = false
      captionLabel.text = "Capture failed — try again"
      return
    }
    onCapture?(image)
  }
}
