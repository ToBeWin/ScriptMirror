import AVFoundation
import AVFAudio
import AVKit
import Flutter
import Photos
import UIKit

private final class ScriptMirrorEventStreamHandler: NSObject, FlutterStreamHandler {
  var sink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}

private final class ScriptMirrorPreviewView: NSObject, FlutterPlatformView {
  private let container: UIView

  init(frame: CGRect, controller: ScriptMirrorCaptureController) {
    container = UIView(frame: frame)
    container.backgroundColor = .black
    super.init()
    controller.attachPreview(to: container)
  }

  func view() -> UIView {
    container
  }
}

final class ScriptMirrorPreviewFactory: NSObject, FlutterPlatformViewFactory {
  private let controller: ScriptMirrorCaptureController

  init(controller: ScriptMirrorCaptureController) {
    self.controller = controller
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    ScriptMirrorPreviewView(frame: frame, controller: controller)
  }
}

/// Native iOS owner for the camera, microphone, preview and Photos hand-off.
///
/// The Flutter contract intentionally mirrors the Android CameraX bridge:
/// one capture owner records the movie, while the audio output publishes
/// bounded mono PCM frames to the offline sherpa-onnx recognizer. The native
/// owner never uploads audio or asks a second plugin to open the microphone.
final class ScriptMirrorCaptureController: NSObject,
  AVCaptureFileOutputRecordingDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate
{
  private let methodChannel: FlutterMethodChannel
  private let phaseChannel: FlutterEventChannel
  private let audioChannel: FlutterEventChannel
  private let phaseStream = ScriptMirrorEventStreamHandler()
  private let audioStream = ScriptMirrorEventStreamHandler()

  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "com.scriptmirror.capture.session")
  private let audioQueue = DispatchQueue(label: "com.scriptmirror.capture.audio")
  private let movieOutput = AVCaptureMovieFileOutput()
  private let audioOutput = AVCaptureAudioDataOutput()
  private let previewLayer: AVCaptureVideoPreviewLayer
  private weak var previewContainer: UIView?
  private let recognizerAudioFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: true
  )!

  private var prepared = false
  private var frontCamera = true
  private var mirrorPreview = true
  private var recordingURL: URL?
  private var interruptionRequested = false
  private var discardOnFinish = false
  private var pendingStartResult: FlutterResult?
  private var pendingStopResult: FlutterResult?
  private var finalizedResult: [String: Any]?
  private var audioConverter: AVAudioConverter?
  private var audioInputFormat: AVAudioFormat?
  private var audioTimestampOrigin: CMTime?
  private var startGeneration = 0
  private var disposed = false

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(name: "scriptmirror/capture", binaryMessenger: messenger)
    phaseChannel = FlutterEventChannel(name: "scriptmirror/capture_events", binaryMessenger: messenger)
    audioChannel = FlutterEventChannel(name: "scriptmirror/audio_feed", binaryMessenger: messenger)
    previewLayer = AVCaptureVideoPreviewLayer(session: session)
    super.init()

    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    phaseChannel.setStreamHandler(phaseStream)
    audioChannel.setStreamHandler(audioStream)

    previewLayer.videoGravity = .resizeAspectFill
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(deviceOrientationDidChange),
      name: UIDevice.orientationDidChangeNotification,
      object: nil
    )
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    UIDevice.current.endGeneratingDeviceOrientationNotifications()
  }

  func attachPreview(to view: UIView) {
    previewContainer = view
    DispatchQueue.main.async { [weak self, weak view] in
      guard let self, let view else { return }
      self.previewLayer.removeFromSuperlayer()
      self.previewLayer.frame = view.bounds
      view.layer.insertSublayer(self.previewLayer, at: 0)
      self.updateVideoConnections()
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestPermissions":
      requestPermissions(result)
    case "permissionsGranted":
      result(permissionsGranted())
    case "openMedia":
      let arguments = call.arguments as? [String: Any]
      openMedia(uri: arguments?["uri"] as? String, result: result)
    case "openAppSettings":
      openAppSettings(result)
    case "prepare":
      prepare(arguments: call.arguments as? [String: Any], result: result)
    case "start":
      let arguments = call.arguments as? [String: Any]
      start(countdownMs: arguments?["countdownMs"] as? Int ?? 0, result: result)
    case "cancelStart":
      let arguments = call.arguments as? [String: Any]
      cancelStart(preserveRecording: arguments?["preserveRecording"] as? Bool ?? false, result: result)
    case "stop":
      stop(result: result)
    case "takeFinalizedResult":
      takeFinalizedResult(result: result)
    case "dispose":
      dispose(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func permissionsGranted() -> Bool {
    let camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    let photos = PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
    return camera && microphone && photos
  }

  private func requestPermissions(_ result: @escaping FlutterResult) {
    let group = DispatchGroup()
    var cameraGranted = false
    var microphoneGranted = false
    var photosGranted = false

    group.enter()
    AVCaptureDevice.requestAccess(for: .video) { granted in
      cameraGranted = granted
      group.leave()
    }
    group.enter()
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      microphoneGranted = granted
      group.leave()
    }
    group.enter()
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      photosGranted = status == .authorized
      group.leave()
    }
    group.notify(queue: .main) {
      result(cameraGranted && microphoneGranted && photosGranted)
    }
  }

  private func prepare(arguments: [String: Any]?, result: @escaping FlutterResult) {
    let requestedFront = arguments?["frontCamera"] as? Bool ?? true
    let width = arguments?["width"] as? Int ?? 1920
    let height = arguments?["height"] as? Int ?? 1080
    let requestedMirror = arguments?["mirrorPreview"] as? Bool ?? true

    sessionQueue.async { [weak self] in
      guard let self, !self.disposed else { return }
      do {
        try self.configureSession(
          frontCamera: requestedFront,
          width: width,
          height: height,
          mirrorPreview: requestedMirror
        )
        self.emitPhase("preparing")
        self.complete(result, with: nil)
      } catch let error as CaptureControllerError {
        self.complete(
          result,
          with: FlutterError(code: error.code, message: error.message, details: nil)
        )
        self.emitPhase("failed", reason: error.code)
      } catch {
        self.complete(
          result,
          with: FlutterError(
            code: "camera_unavailable",
            message: "Camera setup failed",
            details: error.localizedDescription
          )
        )
        self.emitPhase("failed", reason: "camera_unavailable")
      }
    }
  }

  private func configureSession(
    frontCamera: Bool,
    width: Int,
    height: Int,
    mirrorPreview: Bool
  ) throws {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      throw CaptureControllerError(code: "camera_unavailable", message: "Camera permission is unavailable")
    }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw CaptureControllerError(code: "audio_unavailable", message: "Microphone permission is unavailable")
    }

    if session.isRunning { session.stopRunning() }
    do {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothHFP])
      // Request the recognizer's native format when the microphone supports
      // it. iOS may still choose a different hardware rate, so the callback
      // below reports that format and the Dart recognizer can fail safe.
      try audioSession.setPreferredSampleRate(16_000)
      try audioSession.setPreferredInputNumberOfChannels(1)
      try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      throw CaptureControllerError(code: "audio_unavailable", message: "Microphone could not start")
    }

    guard let camera = cameraDevice(front: frontCamera) else {
      throw CaptureControllerError(code: "camera_unavailable", message: "Camera is not available on this device")
    }
    guard let microphone = AVCaptureDevice.default(for: .audio) else {
      throw CaptureControllerError(code: "audio_unavailable", message: "Microphone is not available on this device")
    }

    let videoInput = try AVCaptureDeviceInput(device: camera)
    let audioInput = try AVCaptureDeviceInput(device: microphone)

    session.beginConfiguration()
    defer { session.commitConfiguration() }
    for input in session.inputs { session.removeInput(input) }
    for output in session.outputs { session.removeOutput(output) }

    if width >= 1920, height >= 1080, session.canSetSessionPreset(.hd1920x1080) {
      session.sessionPreset = .hd1920x1080
    } else if session.canSetSessionPreset(.hd1280x720) {
      session.sessionPreset = .hd1280x720
    } else {
      session.sessionPreset = .high
    }

    guard session.canAddInput(videoInput) else {
      throw CaptureControllerError(code: "camera_unavailable", message: "Camera input could not be added")
    }
    session.addInput(videoInput)
    guard session.canAddInput(audioInput) else {
      throw CaptureControllerError(code: "audio_unavailable", message: "Microphone input could not be added")
    }
    session.addInput(audioInput)

    guard session.canAddOutput(movieOutput) else {
      throw CaptureControllerError(code: "recording_unavailable", message: "Video output could not be added")
    }
    session.addOutput(movieOutput)

    guard session.canAddOutput(audioOutput) else {
      throw CaptureControllerError(code: "audio_unavailable", message: "Shared microphone output could not be added")
    }
    audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
    session.addOutput(audioOutput)

    self.frontCamera = frontCamera
    self.mirrorPreview = mirrorPreview
    updateVideoConnections()
    session.startRunning()
    prepared = true
  }

  private func cameraDevice(front: Bool) -> AVCaptureDevice? {
    let position: AVCaptureDevice.Position = front ? .front : .back
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera],
      mediaType: .video,
      position: position
    )
    return discovery.devices.first
  }

  private func updateVideoConnections() {
    let orientation = currentVideoOrientation()
    let connections = [movieOutput.connection(with: .video), previewLayer.connection]
    for connection in connections.compactMap({ $0 }) {
      connection.videoOrientation = orientation
      if connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = frontCamera && mirrorPreview
      }
    }
    DispatchQueue.main.async { [weak self] in
      guard let self, let previewContainer else { return }
      self.previewLayer.frame = previewContainer.bounds
    }
  }

  private func currentVideoOrientation() -> AVCaptureVideoOrientation {
    let interfaceOrientation = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first(where: { $0.activationState != .unattached })?
      .interfaceOrientation
    switch interfaceOrientation {
    case .landscapeLeft:
      return .landscapeLeft
    case .landscapeRight:
      return .landscapeRight
    case .portraitUpsideDown:
      return .portraitUpsideDown
    default:
      return .portrait
    }
  }

  @objc private func deviceOrientationDidChange() {
    sessionQueue.async { [weak self] in
      guard let self, !self.disposed else { return }
      self.updateVideoConnections()
    }
  }

  private func start(countdownMs: Int, result: @escaping FlutterResult) {
    sessionQueue.async { [weak self] in
      guard let self, !self.disposed else { return }
      guard self.prepared, self.session.isRunning else {
        self.complete(result, with: FlutterError(code: "camera_unavailable", message: "Camera is not ready", details: nil))
        return
      }
      guard !self.movieOutput.isRecording else {
        self.complete(result, with: FlutterError(code: "capture_busy", message: "A recording is already active", details: nil))
        return
      }

      self.startGeneration &+= 1
      let generation = self.startGeneration
      self.pendingStartResult = result
      let begin = { [weak self] in
        guard let self, !self.disposed, self.startGeneration == generation else { return }
        self.beginRecording(result: result)
      }
      if countdownMs > 0 {
        self.emitPhase("countdown")
        self.sessionQueue.asyncAfter(deadline: .now() + .milliseconds(countdownMs), execute: begin)
      } else {
        begin()
      }
    }
  }

  private func beginRecording(result: @escaping FlutterResult) {
    guard prepared, session.isRunning else {
      pendingStartResult = nil
      complete(result, with: FlutterError(code: "camera_unavailable", message: "Camera is not ready", details: nil))
      return
    }
    let url = makeRecordingURL()
    recordingURL = url
    interruptionRequested = false
    discardOnFinish = false
    audioTimestampOrigin = nil
    audioConverter = nil
    audioInputFormat = nil
    updateVideoConnections()
    movieOutput.startRecording(to: url, recordingDelegate: self)
    pendingStartResult = nil
    emitPhase("recording")
    complete(result, with: nil)
  }

  private func cancelStart(preserveRecording: Bool, result: @escaping FlutterResult) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.startGeneration &+= 1
      if let pending = self.pendingStartResult {
        self.pendingStartResult = nil
        self.complete(
          pending,
          with: FlutterError(
            code: "capture_cancelled",
            message: "Recording setup was cancelled",
            details: nil
          )
        )
      }
      if self.movieOutput.isRecording {
        if preserveRecording {
          self.interruptionRequested = true
          self.emitPhase("stopping", reason: "app_interrupted")
        } else {
          self.discardOnFinish = true
        }
        self.movieOutput.stopRecording()
      }
      self.complete(result, with: nil)
    }
  }

  private func stop(result: @escaping FlutterResult) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      guard self.movieOutput.isRecording else {
        self.complete(result, with: ["saved": false, "error": "录制尚未开始"])
        return
      }
      guard self.pendingStopResult == nil else {
        self.complete(result, with: ["saved": false, "error": "停止操作已在处理中"])
        return
      }
      self.pendingStopResult = result
      self.interruptionRequested = false
      self.discardOnFinish = false
      self.emitPhase("stopping")
      self.movieOutput.stopRecording()
    }
  }

  private func takeFinalizedResult(result: @escaping FlutterResult) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      let value = self.finalizedResult
      self.finalizedResult = nil
      self.complete(result, with: value)
    }
  }

  private func dispose(result: @escaping FlutterResult) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.startGeneration &+= 1
      self.disposed = true
      if let pending = self.pendingStartResult {
        self.pendingStartResult = nil
        self.complete(
          pending,
          with: FlutterError(code: "capture_disposed", message: "Recording service is closed", details: nil)
        )
      }
      if self.movieOutput.isRecording {
        self.discardOnFinish = true
        self.movieOutput.stopRecording()
      }
      if self.session.isRunning { self.session.stopRunning() }
      self.prepared = false
      self.complete(result, with: nil)
    }
  }

  @objc private func applicationDidEnterBackground() {
    sessionQueue.async { [weak self] in
      guard let self, !self.disposed, self.movieOutput.isRecording else { return }
      if self.pendingStopResult != nil || self.interruptionRequested { return }
      self.interruptionRequested = true
      self.emitPhase("stopping", reason: "app_interrupted")
      self.movieOutput.stopRecording()
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    // start() resolves at the native hand-off boundary, matching CameraX.
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      let interrupted = self.interruptionRequested
      let discarded = self.discardOnFinish
      let pending = self.pendingStopResult
      self.pendingStopResult = nil
      self.recordingURL = nil
      self.audioTimestampOrigin = nil
      self.audioConverter = nil
      self.audioInputFormat = nil
      self.interruptionRequested = false
      self.discardOnFinish = false

      if discarded {
        try? FileManager.default.removeItem(at: outputFileURL)
        self.emitPhase("failed", reason: "capture_cancelled")
        if let pending { self.complete(pending, with: ["saved": false, "error": "录制准备已取消"]) }
        return
      }

      if let error {
        let payload: [String: Any] = [
          "saved": false,
          "error": "录制服务暂时不可用",
          "interrupted": interrupted,
        ]
        if interrupted {
          self.finalizedResult = payload
          self.emitPhase("completed")
        } else if let pending {
          self.complete(pending, with: payload)
        }
        if !interrupted { self.emitPhase("failed", reason: "recording_failed") }
        _ = error
        return
      }

      self.saveVideo(outputFileURL, interrupted: interrupted) { [weak self] payload in
        guard let self else { return }
        self.sessionQueue.async {
          if interrupted {
            self.finalizedResult = payload
            self.emitPhase("completed")
          } else if let pending {
            self.complete(pending, with: payload)
            self.emitPhase("completed")
          } else {
            self.finalizedResult = payload
            self.emitPhase("completed")
          }
        }
      }
    }
  }

  private func saveVideo(_ url: URL, interrupted: Bool, completion: @escaping ([String: Any]) -> Void) {
    let duration = mediaDuration(url)
    let resolution = mediaResolution(url)
    var base: [String: Any] = [
      "storageLocation": "系统相册",
      "interrupted": interrupted,
    ]
    if let duration { base["durationMs"] = duration }
    if let resolution { base["resolution"] = resolution }

    guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized else {
      var payload = base
      payload["saved"] = false
      payload["error"] = "系统相册权限不可用"
      completion(payload)
      return
    }

    PHPhotoLibrary.shared().performChanges({
      PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
    }) { success, _ in
      var payload = base
      payload["saved"] = success
      if success {
        payload["mediaUri"] = url.absoluteString
      } else {
        payload["error"] = "视频文件写入相册失败"
      }
      completion(payload)
    }
  }

  private func makeRecordingURL() -> URL {
    let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ScriptMirror", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("ScriptMirror_\(UUID().uuidString).mov")
  }

  private func mediaDuration(_ url: URL) -> Int? {
    let seconds = AVAsset(url: url).duration.seconds
    guard seconds.isFinite, seconds > 0 else { return nil }
    return Int(seconds * 1000)
  }

  private func mediaResolution(_ url: URL) -> String? {
    guard let track = AVAsset(url: url).tracks(withMediaType: .video).first else { return nil }
    let size = track.naturalSize.applying(track.preferredTransform)
    let width = Int(abs(size.width).rounded())
    let height = Int(abs(size.height).rounded())
    guard width > 0, height > 0 else { return nil }
    return "\(width)×\(height)"
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard output === audioOutput, movieOutput.isRecording,
      let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
    else { return }
    let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

    let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
    guard frameCount > 0,
      let inputBuffer = AVAudioPCMBuffer(
        pcmFormat: inputFormat,
        frameCapacity: frameCount
      )
    else { return }
    inputBuffer.frameLength = frameCount
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer,
      at: 0,
      frameCount: Int32(frameCount),
      into: inputBuffer.mutableAudioBufferList
    ) == noErr else { return }

    if audioInputFormat == nil || audioInputFormat?.isEqual(inputFormat) == false {
      audioInputFormat = inputFormat
      audioConverter = AVAudioConverter(from: inputFormat, to: recognizerAudioFormat)
      audioConverter?.primeMethod = .none
    }
    guard let converter = audioConverter else { return }
    let outputCapacity = AVAudioFrameCount(
      ceil(Double(frameCount) * recognizerAudioFormat.sampleRate / inputFormat.sampleRate)
    ) + 16
    guard let outputBuffer = AVAudioPCMBuffer(
      pcmFormat: recognizerAudioFormat,
      frameCapacity: outputCapacity
    ) else { return }
    var conversionError: NSError?
    var suppliedInput = false
    let conversionStatus = converter.convert(
      to: outputBuffer,
      error: &conversionError
    ) { _, inputStatus in
      if suppliedInput {
        inputStatus.pointee = .endOfStream
        return nil
      }
      suppliedInput = true
      inputStatus.pointee = .haveData
      return inputBuffer
    }
    guard conversionStatus == .haveData || conversionStatus == .inputRanDry || conversionStatus == .endOfStream,
      outputBuffer.frameLength > 0,
      let channelData = outputBuffer.int16ChannelData?.pointee
    else { return }

    let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
    let data = Data(bytes: channelData, count: byteCount)
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if audioTimestampOrigin == nil { audioTimestampOrigin = timestamp }
    let origin = audioTimestampOrigin ?? timestamp
    let elapsedSeconds = max(0, CMTimeGetSeconds(timestamp - origin))
    let timestampMs = Int((elapsedSeconds * 1000).rounded())
    let payload: [String: Any] = [
      "pcm": FlutterStandardTypedData(bytes: data),
      "timestampMs": timestampMs,
      "sampleRateHz": 16_000,
      "channels": 1,
    ]
    DispatchQueue.main.async { [weak self] in
      self?.audioStream.sink?(payload)
    }
  }

  private func openMedia(uri: String?, result: @escaping FlutterResult) {
    guard let uri, let url = URL(string: uri), url.isFileURL else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      guard let presenter = Self.topViewController() else {
        result(false)
        return
      }
      let playerController = AVPlayerViewController()
      playerController.player = AVPlayer(url: url)
      presenter.present(playerController, animated: true) {
        playerController.player?.play()
        result(true)
      }
    }
  }

  private func openAppSettings(_ result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
    }
  }

  private func complete(_ result: @escaping FlutterResult, with value: Any?) {
    DispatchQueue.main.async { result(value) }
  }

  private func emitPhase(_ phase: String, reason: String? = nil) {
    var payload: [String: Any] = ["phase": phase]
    if let reason { payload["reason"] = reason }
    DispatchQueue.main.async { [weak self] in
      self?.phaseStream.sink?(payload)
    }
  }

  private static func topViewController(from root: UIViewController? = nil) -> UIViewController? {
    let root = root ?? UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: { $0.isKeyWindow })?.rootViewController
    if let navigation = root as? UINavigationController {
      return topViewController(from: navigation.visibleViewController)
    }
    if let tab = root as? UITabBarController {
      return topViewController(from: tab.selectedViewController)
    }
    if let presented = root?.presentedViewController {
      return topViewController(from: presented)
    }
    return root
  }
}

private struct CaptureControllerError: Error {
  let code: String
  let message: String
}
