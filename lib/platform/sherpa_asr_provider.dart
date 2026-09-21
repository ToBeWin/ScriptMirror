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
import '../domain/script_models.dart';
import 'audio_feed.dart';

/// The model is packaged in the application bundle. It is copied to the
/// private app-support directory only because sherpa-onnx needs filesystem
/// paths; no network request is made and no audio leaves the device.
const _zhModelAssetDirectory =
    'assets/asr/sherpa-onnx-streaming-zipformer-small-ctc-zh-int8-2025-04-01';
const _zhModelAsset = '$_zhModelAssetDirectory/model.int8.onnx';
const _zhTokensAsset = '$_zhModelAssetDirectory/tokens.txt';
const _enModelAssetDirectory =
    'assets/asr/sherpa-onnx-streaming-zipformer-en-20m-2023-02-17';
const _enEncoderAsset =
    '$_enModelAssetDirectory/encoder-epoch-99-avg-1.int8.onnx';
const _enDecoderAsset = '$_enModelAssetDirectory/decoder-epoch-99-avg-1.onnx';
const _enJoinerAsset =
    '$_enModelAssetDirectory/joiner-epoch-99-avg-1.int8.onnx';
const _enTokensAsset = '$_enModelAssetDirectory/tokens.txt';
const _sampleRateHz = 16000;
const _zhModelSha256 =
    '68c9c943840f7d9cf3e8a4970ba50f404feb5277f611fa82b7e72267786fa84a';
const _zhTokensSha256 =
    '6fed8c6c248516f38e7faa19404b57413e8ce259f1cbc1fa4aebc86eac32fdfd';
const _enEncoderSha256 =
    '3810755ce7c3ab26b42a8bcf39d191308fa27fb0f53358823ba46141d03b7eb3';
const _enDecoderSha256 =
    '45a7f940ecfb53d89fa270ad11b88b961e53a317203eb24b1c8e95ed208b0f30';
const _enJoinerSha256 =
    'e085d73b593cf9b0707f370dbd656d58327d3fe36d80d849202ef81df02cb01e';
const _enTokensSha256 =
    '49e3c2646595fd907228b3c6787069658f67b17377c60aeb8619c4551b2316fb';

class _BundledAsrModel {
  const _BundledAsrModel({
    required this.language,
    required this.cacheDirectory,
    required this.tokensAsset,
    required this.checksums,
    this.ctcModelAsset,
    this.encoderAsset,
    this.decoderAsset,
    this.joinerAsset,
  });

  final RecognitionLanguage language;
  final String cacheDirectory;
  final String tokensAsset;
  final Map<String, String> checksums;
  final String? ctcModelAsset;
  final String? encoderAsset;
  final String? decoderAsset;
  final String? joinerAsset;

  bool get isTransducer => encoderAsset != null;

  String get languageLabel =>
      language == RecognitionLanguage.english ? '英文' : '中文';
}

const _zhModel = _BundledAsrModel(
  language: RecognitionLanguage.chinese,
  cacheDirectory: 'zh-small-ctc',
  ctcModelAsset: _zhModelAsset,
  tokensAsset: _zhTokensAsset,
  checksums: <String, String>{
    _zhModelAsset: _zhModelSha256,
    _zhTokensAsset: _zhTokensSha256,
  },
);

const _enModel = _BundledAsrModel(
  language: RecognitionLanguage.english,
  cacheDirectory: 'en-20m-transducer',
  encoderAsset: _enEncoderAsset,
  decoderAsset: _enDecoderAsset,
  joinerAsset: _enJoinerAsset,
  tokensAsset: _enTokensAsset,
  checksums: <String, String>{
    _enEncoderAsset: _enEncoderSha256,
    _enDecoderAsset: _enDecoderSha256,
    _enJoinerAsset: _enJoinerSha256,
    _enTokensAsset: _enTokensSha256,
  },
);

/// Local streaming Chinese/English ASR backed by sherpa-onnx on Android and
/// iOS. Automatic selection follows the script language; an explicit setting
/// can override it for mixed-language scripts.
///
/// CaptureService remains the only microphone owner. This provider subscribes
/// to its shared PCM EventChannel and never opens a second recorder.
class SherpaAsrProvider implements AsrProvider {
  SherpaAsrProvider({
    RecognitionLanguage language = RecognitionLanguage.automatic,
    Iterable<String> scriptLines = const <String>[],
  }) : _requestedLanguage = language,
       _scriptLines = List<String>.unmodifiable(scriptLines),
       _statusController = StreamController<AsrStatusEvent>.broadcast(),
       _partialController = StreamController<AsrPartial>.broadcast();

  static bool _bindingsInitialized = false;

  final StreamController<AsrStatusEvent> _statusController;
  final StreamController<AsrPartial> _partialController;
  final RecognitionLanguage _requestedLanguage;
  final List<String> _scriptLines;
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

  RecognitionLanguage get resolvedLanguage =>
      _requestedLanguage == RecognitionLanguage.automatic
      ? detectRecognitionLanguage(_scriptLines)
      : _requestedLanguage;

  _BundledAsrModel get _model =>
      resolvedLanguage == RecognitionLanguage.english ? _enModel : _zhModel;

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
      AsrStatusEvent(
        status: AsrStatus.initializing,
        reason: '正在加载本地离线${_model.languageLabel}识别模型',
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
        AsrStatusEvent(
          status: AsrStatus.listening,
          reason: '本地离线${_model.languageLabel}识别已就绪，音频不会上传',
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

    final model = _model;
    final tokensPath = await _copyBundledModel(model, model.tokensAsset);
    final sherpaModel = model.isTransducer
        ? sherpa.OnlineModelConfig(
            transducer: sherpa.OnlineTransducerModelConfig(
              encoder: await _copyBundledModel(model, model.encoderAsset!),
              decoder: await _copyBundledModel(model, model.decoderAsset!),
              joiner: await _copyBundledModel(model, model.joinerAsset!),
            ),
            tokens: tokensPath,
            numThreads: 1,
            provider: 'cpu',
            debug: false,
          )
        : sherpa.OnlineModelConfig(
            zipformer2Ctc: sherpa.OnlineZipformer2CtcModelConfig(
              model: await _copyBundledModel(model, model.ctcModelAsset!),
            ),
            tokens: tokensPath,
            numThreads: 1,
            provider: 'cpu',
            debug: false,
            modelingUnit: 'cjkchar',
          );
    final config = sherpa.OnlineRecognizerConfig(
      feat: const sherpa.FeatureConfig(
        sampleRate: _sampleRateHz,
        featureDim: 80,
      ),
      model: sherpaModel,
      decodingMethod: 'greedy_search',
      enableEndpoint: true,
      rule1MinTrailingSilence: 2.4,
      rule2MinTrailingSilence: 1.2,
      rule3MinUtteranceLength: 20,
    );
    _recognizer = sherpa.OnlineRecognizer(config);
  }

  Future<String> _copyBundledModel(_BundledAsrModel model, String asset) async {
    final support = await getApplicationSupportDirectory();
    final targetDirectory = Directory(
      path.join(support.path, 'asr', model.cacheDirectory),
    );
    await targetDirectory.create(recursive: true);
    final target = File(path.join(targetDirectory.path, path.basename(asset)));
    final data = await rootBundle.load(asset);
    final expectedSha256 = model.checksums[asset];
    if (expectedSha256 == null) {
      throw ArgumentError.value(asset, 'asset', 'Unknown ASR asset');
    }
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

AsrProvider asrProviderForCurrentPlatform({
  RecognitionLanguage language = RecognitionLanguage.automatic,
  Iterable<String> scriptLines = const <String>[],
}) {
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    return SherpaAsrProvider(language: language, scriptLines: scriptLines);
  }
  return UnavailableAsrProvider(reason: '本地离线识别目前仅支持移动端录制链路');
}
