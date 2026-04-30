import AVFoundation
import UIKit
import Vision

/// A simple full-screen camera with live document detection, auto-shutter,
/// and a light-yellow overlay highlighting the detected document.
///
/// Result delivery is via the two callbacks. Exactly one is invoked.
final class LiveScannerViewController: UIViewController {

  // MARK: Public callbacks

  var onCapture: ((UIImage) -> Void)?
  var onCancel: (() -> Void)?

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

  /// Auto-shutter triggers after this many consecutive stable frames.
  /// At ~30fps, 24 frames ≈ 0.8 seconds.
  private let stableFramesForAutoCapture = 24
  /// Per-corner tolerance (in normalized [0,1] space) for "still stable".
  private let stabilityTolerance: CGFloat = 0.02

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
      // Keep frames upright so the overlay math stays simple
      if let conn = videoOutput.connection(with: .video), conn.isVideoOrientationSupported {
        conn.videoOrientation = .portrait
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
    if let conn = previewLayer.connection, conn.isVideoOrientationSupported {
      conn.videoOrientation = .portrait
    }
    view.layer.addSublayer(previewLayer)
  }

  private func setupOverlay() {
    overlayLayer.fillColor = UIColor.yellow.withAlphaComponent(0.25).cgColor
    overlayLayer.strokeColor = UIColor.yellow.cgColor
    overlayLayer.lineWidth = 2
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

  /// Draws the quad on screen by mapping Vision's normalized image-space
  /// corners through the preview layer's transform.
  private func drawOverlay(for observation: VNRectangleObservation?) {
    guard let observation = observation else {
      overlayLayer.path = nil
      return
    }

    func toView(_ p: CGPoint) -> CGPoint {
      // Vision: bottom-left origin, normalized [0,1]. Preview layer expects
      // top-left origin in capture-device coords.
      let flipped = CGPoint(x: p.x, y: 1 - p.y)
      return previewLayer.layerPointConverted(fromCaptureDevicePoint: flipped)
    }

    let path = UIBezierPath()
    path.move(to: toView(observation.topLeft))
    path.addLine(to: toView(observation.topRight))
    path.addLine(to: toView(observation.bottomRight))
    path.addLine(to: toView(observation.bottomLeft))
    path.close()
    overlayLayer.path = path.cgPath
  }

  private func updateCaption(detected: Bool, stableFrames: Int) {
    if hasCaptured { return }
    if !detected {
      captionLabel.text = "Position document in frame"
    } else if stableFrames < stableFramesForAutoCapture {
      captionLabel.text = "Hold steady…"
    } else {
      captionLabel.text = "Capturing…"
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

    let request = VNDetectDocumentSegmentationRequest()
    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
    do {
      try handler.perform([request])
    } catch {
      return
    }

    let observation = (request.results as? [VNRectangleObservation])?.first

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.updateStabilityCounter(with: observation)
      self.drawOverlay(for: observation)
      self.updateCaption(detected: observation != nil, stableFrames: self.stableFrameCount)

      if !self.hasCaptured,
         observation != nil,
         self.stableFrameCount >= self.stableFramesForAutoCapture {
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
