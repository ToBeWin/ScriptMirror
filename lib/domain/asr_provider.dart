import 'dart:async';

import 'alignment_engine.dart';
import '../platform/audio_feed.dart';

/// Provider-independent ASR lifecycle. A provider must never own a second
/// microphone while CaptureService is recording; production providers should
/// consume the audio fan-out exposed by the native capture owner.
enum AsrStatus { unavailable, initializing, listening, degraded, stopped }

class AsrStatusEvent {
  const AsrStatusEvent({required this.status, this.reason});

  final AsrStatus status;
  final String? reason;
}

abstract interface class AsrProvider {
  Stream<AsrPartial> get partials;
  Stream<AsrStatusEvent> get status;
  AsrStatusEvent get currentStatus;

  /// Returns whether the provider can emit partial results for this session.
  Future<bool> start({AudioFeed? audioFeed});

  Future<void> stop();
  Future<void> dispose();
}

/// Explicit fallback used until a provider is connected to the native audio
/// fan-out. Recording remains fully usable with timed and manual advancement.
class UnavailableAsrProvider implements AsrProvider {
  UnavailableAsrProvider({this.reason = '识别暂不可用，已切换为定时/手动提词'})
    : _statusController = StreamController<AsrStatusEvent>.broadcast();

  final String reason;
  final StreamController<AsrStatusEvent> _statusController;
  final StreamController<AsrPartial> _partialController =
      StreamController<AsrPartial>.broadcast();
  AsrStatusEvent _currentStatus = const AsrStatusEvent(
    status: AsrStatus.unavailable,
  );

  @override
  Stream<AsrPartial> get partials => _partialController.stream;

  @override
  Stream<AsrStatusEvent> get status => _statusController.stream;

  @override
  AsrStatusEvent get currentStatus => _currentStatus;

  @override
  Future<bool> start({AudioFeed? audioFeed}) async {
    _emit(AsrStatusEvent(status: AsrStatus.unavailable, reason: reason));
    return false;
  }

  @override
  Future<void> stop() async {
    _emit(const AsrStatusEvent(status: AsrStatus.stopped));
  }

  @override
  Future<void> dispose() async {
    await _statusController.close();
    await _partialController.close();
  }

  void _emit(AsrStatusEvent event) {
    _currentStatus = event;
    if (!_statusController.isClosed) _statusController.add(event);
  }
}
