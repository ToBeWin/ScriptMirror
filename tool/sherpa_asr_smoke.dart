import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Small host-side smoke test for the bundled streaming model.
///
/// Usage:
///   dart run tool/sherpa_asr_smoke.dart path/to/16k-mono.wav
///
/// This intentionally exercises the same model family and endpoint settings
/// as SherpaAsrProvider, without opening a microphone or requiring Android.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/sherpa_asr_smoke.dart <wav>');
    exitCode = 64;
    return;
  }

  final wavPath = args.single;
  final modelDirectory =
      '${Directory.current.path}/assets/asr/'
      'sherpa-onnx-streaming-zipformer-small-ctc-zh-int8-2025-04-01';
  final modelPath = '$modelDirectory/model.int8.onnx';
  final tokensPath = '$modelDirectory/tokens.txt';
  if (!File(wavPath).existsSync() ||
      !File(modelPath).existsSync() ||
      !File(tokensPath).existsSync()) {
    stderr.writeln('missing wav or bundled model asset');
    exitCode = 66;
    return;
  }

  sherpa.initBindings();
  final wave = sherpa.readWave(wavPath);
  if (wave.samples.isEmpty || wave.sampleRate != 16000) {
    stderr.writeln(
      'expected a readable 16 kHz mono wav, got ${wave.sampleRate} Hz',
    );
    exitCode = 65;
    return;
  }

  final recognizer = sherpa.OnlineRecognizer(
    sherpa.OnlineRecognizerConfig(
      feat: const sherpa.FeatureConfig(sampleRate: 16000, featureDim: 80),
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
    ),
  );
  final stream = recognizer.createStream();
  var lastText = '';
  const chunkSamples = 3200; // 200 ms at 16 kHz, matching the native feed.
  try {
    for (var offset = 0; offset < wave.samples.length; offset += chunkSamples) {
      final end = (offset + chunkSamples).clamp(0, wave.samples.length).toInt();
      stream.acceptWaveform(
        samples: Float32List.fromList(wave.samples.sublist(offset, end)),
        sampleRate: wave.sampleRate,
      );
      while (recognizer.isReady(stream)) {
        recognizer.decode(stream);
      }
      final text = recognizer.getResult(stream).text.trim();
      if (text.isNotEmpty && text != lastText) {
        lastText = text;
        stdout.writeln(text);
      }
      if (recognizer.isEndpoint(stream)) recognizer.reset(stream);
    }

    stream.inputFinished();
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    final finalText = recognizer.getResult(stream).text.trim();
    if (finalText.isNotEmpty && finalText != lastText) {
      stdout.writeln(finalText);
    }
    if (lastText.isEmpty && finalText.isEmpty) {
      stderr.writeln('no recognition text emitted');
      exitCode = 1;
    }
  } finally {
    stream.free();
    recognizer.free();
  }
}
