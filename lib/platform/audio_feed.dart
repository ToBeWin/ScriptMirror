import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One bounded PCM16 frame emitted by the native capture owner.
///
/// Frames are deliberately small and timestamped so an ASR provider can
/// consume the same microphone signal that is being encoded into the video.
class AudioPcmFrame {
  const AudioPcmFrame({
    required this.pcm16,
    required this.timestampMs,
    required this.sampleRateHz,
    required this.channels,
  });

  final Uint8List pcm16;
  final int timestampMs;
  final int sampleRateHz;
  final int channels;
}

/// Describes the audio path without claiming that a text recognizer exists.
class AudioFeedCapability {
  const AudioFeedCapability({
    required this.available,
    required this.sampleRateHz,
    required this.channels,
    required this.reason,
  });

  final bool available;
  final int sampleRateHz;
  final int channels;
  final String reason;
}

abstract interface class AudioFeed {
  Stream<AudioPcmFrame> get frames;
  AudioFeedCapability get capability;
}

/// The Android native capture owner exposes PCM only while a recording is
/// active. No second Dart/plugin microphone is opened.
class NativeAudioFeed implements AudioFeed {
  static const _events = EventChannel('scriptmirror/audio_feed');

  @override
  AudioFeedCapability get capability => const AudioFeedCapability(
    available: true,
    sampleRateHz: 16000,
    channels: 1,
    reason: '由原生录制所有者共享 PCM 音频；供本地离线识别使用',
  );

  @override
  Stream<AudioPcmFrame> get frames => _events
      .receiveBroadcastStream()
      .map<AudioPcmFrame?>(_parse)
      .where((frame) => frame != null)
      .cast<AudioPcmFrame>();

  static AudioPcmFrame? _parse(dynamic event) {
    if (event is! Map) return null;
    final raw = event['pcm'];
    final timestampMs = event['timestampMs'];
    final sampleRateHz = event['sampleRateHz'];
    final channels = event['channels'];
    if (raw is! Uint8List ||
        timestampMs is! int ||
        sampleRateHz is! int ||
        channels is! int) {
      return null;
    }
    return AudioPcmFrame(
      pcm16: raw,
      timestampMs: timestampMs,
      sampleRateHz: sampleRateHz,
      channels: channels,
    );
  }
}

class UnavailableAudioFeed implements AudioFeed {
  const UnavailableAudioFeed({this.reason = '当前平台没有可用的原生共享音频流'});

  @override
  AudioFeedCapability get capability => AudioFeedCapability(
    available: false,
    sampleRateHz: 0,
    channels: 0,
    reason: reason,
  );

  final String reason;

  @override
  Stream<AudioPcmFrame> get frames => const Stream<AudioPcmFrame>.empty();
}

AudioFeed audioFeedForCurrentPlatform() =>
    defaultTargetPlatform == TargetPlatform.android
    ? NativeAudioFeed()
    : const UnavailableAudioFeed();
