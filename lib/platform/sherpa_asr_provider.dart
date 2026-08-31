import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../domain/alignment_engine.dart';
import '../domain/asr_provider.dart';
import 'audio_feed.dart';

/// The model is packaged in the application bundle. It is copied to the
/// private app-support directory only because sherpa-onnx needs filesystem
/// paths; no network request is made and no audio leaves the device.
const _modelAssetDirectory =
    'assets/asr/sherpa-onnx-streaming-zipformer-small-ctc-zh-int8-2025-04-01';
const _modelAsset = '$_modelAssetDirectory/model.int8.onnx';
const _tokensAsset = '$_modelAssetDirectory/tokens.txt';
const _sampleRateHz = 16000;
const _modelSha256 =
    '68c9c943840f7d9cf3e8a4970ba50f404feb5277f611fa82b7e72267786fa84a';
const _tokensSha256 =
    '6fed8c6c248516f38e7faa19404b57413e8ce259f1cbc1fa4aebc86eac32fdfd';

/// Local streaming Chinese ASR backed by sherpa-onnx.
///
/// CaptureService remains the only microphone owner. This provider subscribes
/// to its shared PCM EventChannel and never opens a second recorder.
class SherpaAsrProvider implements AsrProvider {
  SherpaAsrProvider()
    : _statusController = StreamController<AsrStatusEvent>.broadcast(),
      _partialController = StreamController<AsrPartial>.broadcast();

  static bool _bindingsInitialized = false;

  final StreamController<AsrStatusEvent> _statusController;
  final StreamController<AsrPartial> _partialController;
  StreamSubscription<AudioPcmFrame>? _audioSubscription;
  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OnlineStream? _stream;
  AsrStatusEvent _currentStatus = const AsrStatusEvent(
    status: AsrStatus.unavailable,
  );
  String _lastEmittedText = '';
  int _lastFrameTimestampMs = 0;
  int _startGeneration = 0;
  bool _disposed = false;

  @override
  Stream<AsrPartial> get partials => _partialController.stream;

  @override
  Stream<AsrStatusEvent> get status => _statusController.stream;

  @override
  AsrStatusEvent get currentStatus => _currentStatus;

  @override
  Future<bool> start({AudioFeed? audioFeed}) async {
    if (_disposed) return false;
    if (_audioSubscription != null) return true;
    final generation = ++_startGeneration;

    final feed = audioFeed;
    if (feed == null || !feed.capability.available) {
      _emit(
        AsrStatusEvent(
          status: AsrStatus.unavailable,
          reason: feed?.capability.reason ?? '本机没有可用的共享麦克风音频',
        ),
      );
      return false;
    }
    if (feed.capability.sampleRateHz != _sampleRateHz ||
        feed.capability.channels != 1) {
      _emit(
        const AsrStatusEvent(
          status: AsrStatus.degraded,
          reason: '当前音频格式不受本地识别模型支持，已切换为定时/手动提词',
        ),
      );
      return false;
    }

    _emit(
      const AsrStatusEvent(
        status: AsrStatus.initializing,
        reason: '正在加载本地离线识别模型',
      ),
    );
    try {
      await _ensureRecognizer();
      // stop() can run while the bundled model is being copied/initialized
      // (for example when the user cancels the first-run countdown). Do not
      // attach a late EventChannel subscription to a page that has already
      // invalidated this start attempt.
      if (_disposed || generation != _startGeneration) return false;
      _stream = _recognizer!.createStream();
      _lastEmittedText = '';
      _lastFrameTimestampMs = 0;
      if (_disposed || generation != _startGeneration) {
        _stream?.free();
        _stream = null;
        return false;
      }
      _audioSubscription = feed.frames.listen(
        _acceptFrame,
        onError: (_, _) => _degrade('共享音频流中断，已切换为定时/手动提词'),
        cancelOnError: false,
      );
      _emit(
        const AsrStatusEvent(
          status: AsrStatus.listening,
          reason: '本地离线识别已就绪，音频不会上传',
        ),
      );
      return true;
    } catch (_) {
      _stream?.free();
      _stream = null;
      if (_disposed || generation != _startGeneration) return false;
      _emit(
        const AsrStatusEvent(
          status: AsrStatus.degraded,
          reason: '本地识别模型初始化失败，已切换为定时/手动提词',
        ),
      );
      return false;
    }
  }

  @override
  Future<void> stop() async {
    // Invalidate an in-flight _ensureRecognizer() before awaiting any stream
    // cancellation. This makes start()'s late continuation a no-op.
    _startGeneration++;
    await _audioSubscription?.cancel();
    _audioSubscription = null;

    final recognizer = _recognizer;
    final stream = _stream;
    _stream = null;
    if (recognizer != null && stream != null) {
      try {
        stream.inputFinished();
        while (recognizer.isReady(stream)) {
          recognizer.decode(stream);
        }
        // Flush a final partial after inputFinished(). Without this, the last
        // spoken words can remain only inside sherpa's stream and never reach
        // the alignment engine before the capture page navigates away.
        _emitResult(
          recognizer.getResult(stream).text.trim(),
          timestampMs: _lastFrameTimestampMs,
          isFinal: true,
          speechPause: true,
        );
      } catch (_) {
        // Stopping capture must not be held hostage by ASR finalization.
      } finally {
        stream.free();
      }
    }
    _lastEmittedText = '';
    _lastFrameTimestampMs = 0;
    if (!_disposed) _emit(const AsrStatusEvent(status: AsrStatus.stopped));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    _recognizer?.free();
    _recognizer = null;
    await _statusController.close();
    await _partialController.close();
  }

  Future<void> _ensureRecognizer() async {
    if (_recognizer != null) return;
    if (!_bindingsInitialized) {
      sherpa.initBindings();
      _bindingsInitialized = true;
    }

    final modelPath = await _copyBundledModel(_modelAsset);
    final tokensPath = await _copyBundledModel(_tokensAsset);
    final config = sherpa.OnlineRecognizerConfig(
      feat: const sherpa.FeatureConfig(
        sampleRate: _sampleRateHz,
        featureDim: 80,
      ),
      model: sherpa.OnlineModelConfig(
        zipformer2Ctc: sherpa.OnlineZipformer2CtcModelConfig(model: modelPath),
        tokens: tokensPath,
        numThreads: 1,
        provider: 'cpu',
        debug: false,
        modelingUnit: 'cjkchar',
      ),
      decodingMethod: 'greedy_search',
      enableEndpoint: true,
      rule1MinTrailingSilence: 2.4,
      rule2MinTrailingSilence: 1.2,
      rule3MinUtteranceLength: 20,
    );
    _recognizer = sherpa.OnlineRecognizer(config);
  }

  Future<String> _copyBundledModel(String asset) async {
    final support = await getApplicationSupportDirectory();
    final targetDirectory = Directory(
      path.join(support.path, 'asr', 'zh-small-ctc'),
    );
    await targetDirectory.create(recursive: true);
    final target = File(path.join(targetDirectory.path, path.basename(asset)));
    final data = await rootBundle.load(asset);
    final expectedSha256 = switch (asset) {
      _modelAsset => _modelSha256,
      _tokensAsset => _tokensSha256,
      _ => throw ArgumentError.value(asset, 'asset', 'Unknown ASR asset'),
    };
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    if (sha256.convert(bytes).toString() != expectedSha256) {
      throw StateError('bundled_asr_asset_checksum_mismatch');
    }

    if (await target.exists() && await target.length() == data.lengthInBytes) {
      final targetSha256 = await _sha256File(target);
      if (targetSha256 == expectedSha256) return target.path;
    }

    await target.writeAsBytes(bytes, flush: true);
    if (await _sha256File(target) != expectedSha256) {
      try {
        await target.delete();
      } catch (_) {
        // Keep the original checksum error as the actionable failure.
      }
      throw StateError('copied_asr_asset_checksum_mismatch');
    }
    return target.path;
  }

  Future<String> _sha256File(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  void _acceptFrame(AudioPcmFrame frame) {
    final recognizer = _recognizer;
    final stream = _stream;
    if (_disposed || recognizer == null || stream == null) return;
    if (frame.sampleRateHz != _sampleRateHz || frame.channels != 1) {
      _degrade('共享音频格式发生变化，已切换为定时/手动提词');
      return;
    }
    _lastFrameTimestampMs = frame.timestampMs;

    try {
      final samples = pcm16ToFloat32(frame.pcm16);
      if (samples.isEmpty) return;
      stream.acceptWaveform(samples: samples, sampleRate: _sampleRateHz);
      while (recognizer.isReady(stream)) {
        recognizer.decode(stream);
      }

      final endpoint = recognizer.isEndpoint(stream);
      _emitResult(
        recognizer.getResult(stream).text.trim(),
        timestampMs: frame.timestampMs,
        isFinal: endpoint,
        speechPause: endpoint,
      );
      if (endpoint) {
        _lastEmittedText = '';
        recognizer.reset(stream);
      }
    } catch (_) {
      _degrade('本地识别运行异常，已切换为定时/手动提词');
    }
  }

  void _degrade(String reason) {
    if (_currentStatus.status == AsrStatus.degraded &&
        _currentStatus.reason == reason) {
      return;
    }
    final subscription = _audioSubscription;
    _audioSubscription = null;
    unawaited(subscription?.cancel());
    _emit(AsrStatusEvent(status: AsrStatus.degraded, reason: reason));
  }

  void _emitResult(
    String text, {
    required int timestampMs,
    required bool isFinal,
    required bool speechPause,
  }) {
    if (text.isEmpty || (!isFinal && text == _lastEmittedText)) return;
    _lastEmittedText = text;
    if (_partialController.isClosed) return;
    _partialController.add(
      AsrPartial(
        text: text,
        timestampMs: timestampMs,
        isFinal: isFinal,
        speechPause: speechPause,
      ),
    );
  }

  void _emit(AsrStatusEvent event) {
    _currentStatus = event;
    if (!_statusController.isClosed) _statusController.add(event);
  }
}

/// Converts little-endian signed PCM16 from AudioRecord to sherpa's expected
/// mono float samples in [-1, 1]. Kept top-level so it can be unit tested
/// without loading the native inference runtime.
Float32List pcm16ToFloat32(Uint8List bytes) {
  final sampleCount = bytes.length ~/ 2;
  final values = Float32List(sampleCount);
  final data = ByteData.sublistView(bytes, 0, sampleCount * 2);
  for (var index = 0; index < sampleCount; index++) {
    values[index] = data.getInt16(index * 2, Endian.little) / 32768.0;
  }
  return values;
}

AsrProvider asrProviderForCurrentPlatform() {
  if (defaultTargetPlatform == TargetPlatform.android) {
    return SherpaAsrProvider();
  }
  return UnavailableAsrProvider(reason: '本地离线识别目前仅支持 Android 录制链路');
}
