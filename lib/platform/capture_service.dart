import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/script_models.dart';
import 'audio_feed.dart';

class CaptureConfig {
  const CaptureConfig({
    this.frontCamera = true,
    this.width = 1920,
    this.height = 1080,
    this.mirrorPreview = true,
    this.audioEnabled = true,
  });

  final bool frontCamera;
  final int width;
  final int height;
  final bool mirrorPreview;
  final bool audioEnabled;

  CaptureConfig forResolution(CaptureResolution resolution) => CaptureConfig(
    frontCamera: frontCamera,
    width: resolution.width,
    height: resolution.height,
    mirrorPreview: mirrorPreview,
    audioEnabled: audioEnabled,
  );
}

class CaptureResult {
  const CaptureResult({
    required this.saved,
    this.mediaUri,
    this.durationMs,
    this.resolution,
    this.storageLocation,
    this.error,
    this.interrupted = false,
  });

  final bool saved;
  final String? mediaUri;
  final int? durationMs;
  final String? resolution;

  /// Human-readable system media location, for example `DCIM/ScriptMirror`
  /// on Android or `系统相册` on iOS.
  /// It is optional because legacy providers may not expose a path after the
  /// insert; callers should fall back to the generic system gallery label.
  final String? storageLocation;
  final String? error;

  /// True when the native owner finalized the recording because the host
  /// activity was interrupted (for example by a call, lock screen, or
  /// background transition), rather than an explicit Stop tap.
  final bool interrupted;
}

/// Native capture lifecycle update. The optional reason lets the UI explain a
/// failure without exposing platform-specific error codes to the rest of the
/// app.
class CapturePhaseEvent {
  const CapturePhaseEvent({required this.phase, this.reason});

  final CapturePhase phase;
  final String? reason;
}

/// Flutter-facing contract. The mobile implementation owns the native camera,
/// microphone, shared audio feed and system media library; UI code must not call
/// platform APIs directly.
abstract interface class CaptureService {
  Stream<CapturePhaseEvent> get phase;
  AudioFeed get audioFeed;
  Future<void> prepare(CaptureConfig config);
  Future<void> start({Duration countdown = const Duration(seconds: 3)});

  /// Cancels an asynchronous native start that is waiting for the platform
  /// camera owner to expose a usable capture session.
  ///
  /// A tiny hand-off window exists after the native owner has created a take but
  /// before Flutter receives the successful platform result. In that window a
  /// user cancel must discard the just-started take, while a host lifecycle
  /// interruption must preserve it for the recovery flow. The native owner
  /// applies that distinction atomically.
  Future<void> cancelStart({bool preserveRecording = false});

  Future<CaptureResult> stop();

  /// Returns a recording finalized by a host interruption, once.
  ///
  /// A process restart cannot rely on this in-memory result; the durable
  /// session recovery record remains the source of truth in that case.
  Future<CaptureResult?> takeFinalizedResult();
  Future<void> dispose();
}

/// Native capture bridge used on Android and iOS. The channel is deliberately
/// small so Flutter remains independent from CameraX, AVFoundation, MediaStore
/// and Photos details.
class PlatformCaptureService implements CaptureService {
  static const _channel = MethodChannel('scriptmirror/capture');
  static const _events = EventChannel('scriptmirror/capture_events');

  static bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static Future<bool> requestPermissions() async {
    if (!isSupported) return true;
    try {
      return await _channel.invokeMethod<bool>('requestPermissions') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> permissionsGranted() async {
    if (!isSupported) return true;
    try {
      return await _channel.invokeMethod<bool>('permissionsGranted') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> openMedia(String mediaUri) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('openMedia', <String, Object>{
            'uri': mediaUri,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens this app's system settings page so a permanently denied camera or
  /// microphone permission can be restored without making the user hunt for
  /// the app in platform settings.
  static Future<bool> openAppSettings() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('openAppSettings') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  AudioFeed get audioFeed => NativeAudioFeed();

  @override
  Stream<CapturePhaseEvent> get phase => _events
      .receiveBroadcastStream()
      .map<CapturePhaseEvent?>(_parsePhase)
      .where((event) => event != null)
      .cast<CapturePhaseEvent>();

  static CapturePhaseEvent? _parsePhase(dynamic event) {
    if (event is! Map) return null;
    final name = event['phase'];
    if (name is! String) return null;
    for (final phase in CapturePhase.values) {
      if (phase.name == name) {
        final rawReason = event['reason'];
        return CapturePhaseEvent(
          phase: phase,
          reason: rawReason is String ? rawReason : null,
        );
      }
    }
    return null;
  }

  @override
  Future<void> prepare(CaptureConfig config) async {
    await _channel.invokeMethod<void>('prepare', <String, Object>{
      'frontCamera': config.frontCamera,
      'width': config.width,
      'height': config.height,
      'mirrorPreview': config.mirrorPreview,
      'audioEnabled': config.audioEnabled,
    });
  }

  @override
  Future<void> start({Duration countdown = const Duration(seconds: 3)}) async {
    await _channel.invokeMethod<void>('start', <String, Object>{
      'countdownMs': countdown.inMilliseconds,
    });
  }

  @override
  Future<void> cancelStart({bool preserveRecording = false}) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('cancelStart', <String, Object>{
        'preserveRecording': preserveRecording,
      });
    } on MissingPluginException {
      // The channel may already be gone while the route is being removed.
    } on PlatformException {
      // Cancellation is best effort; the Flutter generation guard prevents a
      // late start result from changing the visible page state.
    }
  }

  @override
  Future<CaptureResult> stop() async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>('stop');
    final values = raw ?? const <Object?, Object?>{};
    return CaptureResult(
      saved: values['saved'] as bool? ?? false,
      mediaUri: values['mediaUri'] as String?,
      durationMs: values['durationMs'] as int?,
      resolution: values['resolution'] as String?,
      storageLocation: values['storageLocation'] as String?,
      error: values['error'] as String?,
      interrupted: values['interrupted'] as bool? ?? false,
    );
  }

  @override
  Future<CaptureResult?> takeFinalizedResult() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'takeFinalizedResult',
      );
      if (raw == null) return null;
      final values = raw;
      return CaptureResult(
        saved: values['saved'] as bool? ?? false,
        mediaUri: values['mediaUri'] as String?,
        durationMs: values['durationMs'] as int?,
        resolution: values['resolution'] as String?,
        storageLocation: values['storageLocation'] as String?,
        error: values['error'] as String?,
        interrupted: values['interrupted'] as bool? ?? true,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> dispose() async {
    // State disposal can race Flutter engine teardown (for example when the
    // app is swiped away or the host activity is destroyed). Cleanup is best
    // effort in that window and must not surface an unhandled channel error.
    try {
      await _channel.invokeMethod<void>('dispose');
    } on MissingPluginException {
      // The platform view/channel has already gone away.
    } on PlatformException {
      // Native teardown is independently guarded and remains authoritative.
    }
  }
}

/// Non-mobile/test fallback. It drives the same lifecycle but never claims
/// that a video file was written.
class PreviewCaptureService implements CaptureService {
  PreviewCaptureService()
    : _phaseController = StreamController<CapturePhaseEvent>.broadcast();

  final StreamController<CapturePhaseEvent> _phaseController;
  CapturePhase _current = CapturePhase.idle;
  bool _disposed = false;

  @override
  Stream<CapturePhaseEvent> get phase => _phaseController.stream;

  @override
  AudioFeed get audioFeed => const UnavailableAudioFeed();

  void _setPhase(CapturePhase next, {String? reason}) {
    if (_disposed || _phaseController.isClosed) return;
    _current = next;
    _phaseController.add(CapturePhaseEvent(phase: next, reason: reason));
  }

  @override
  Future<void> prepare(CaptureConfig config) async {
    if (_disposed) return;
    _setPhase(CapturePhase.preparing);
  }

  @override
  Future<void> start({Duration countdown = const Duration(seconds: 3)}) async {
    if (_disposed) return;
    _setPhase(CapturePhase.countdown);
    await Future<void>.delayed(countdown);
    if (_disposed) return;
    _setPhase(CapturePhase.recording);
  }

  @override
  Future<void> cancelStart({bool preserveRecording = false}) async {
    // PreviewCaptureService never waits for a native camera future. The
    // method still exists so tests and non-mobile builds exercise the same
    // cancellation contract as the native implementation.
  }

  @override
  Future<CaptureResult> stop() async {
    if (_disposed) {
      return const CaptureResult(saved: false, error: '录制服务已关闭');
    }
    if (_current != CapturePhase.recording &&
        _current != CapturePhase.countdown) {
      return const CaptureResult(saved: false, error: '录制尚未开始');
    }
    _setPhase(CapturePhase.stopping);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _setPhase(CapturePhase.completed);
    return const CaptureResult(saved: false, error: '预览模式未写入视频文件');
  }

  @override
  Future<CaptureResult?> takeFinalizedResult() async => null;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _phaseController.close();
  }
}
