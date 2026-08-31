import 'dart:io';
import 'dart:typed_data';

import 'package:script_mirror/domain/alignment_engine.dart';
import 'package:script_mirror/domain/script_models.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Exercises the same offline recognizer and the script-constrained alignment
/// engine together. This is intentionally host-side: it never opens a
/// microphone and gives us a repeatable signal for the partial -> advance
/// contract before a real device is connected.
///
/// Usage:
///   dart run tool/sherpa_alignment_smoke.dart path/to/16k-mono.wav [minAdvances]
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 2) {
    stderr.writeln(
      'usage: dart run tool/sherpa_alignment_smoke.dart <wav> [minAdvances]',
    );
    exitCode = 64;
    return;
  }

  final wavPath = args.first;
  final minimumAdvances = args.length == 2 ? int.tryParse(args[1]) : 1;
  if (minimumAdvances == null || minimumAdvances < 1) {
    stderr.writeln('minAdvances must be a positive integer');
    exitCode = 64;
    return;
  }
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
    stderr.writeln('expected a readable 16 kHz mono wav');
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
  final engine = AlignmentEngine(
    lines: [
      ScriptLine(
        id: 'smoke-1',
        order: 0,
        text: '今天我想分享一个很好用的拍摄方式。',
        expectedDurationMs: 4_000,
        pauseAfterMs: 400,
      ),
      ScriptLine(
        id: 'smoke-2',
        order: 1,
        text: '它能让你不再担心忘词，同时保持自然的眼神表达。',
        expectedDurationMs: 5_000,
        pauseAfterMs: 400,
      ),
      ScriptLine(
        id: 'smoke-3',
        order: 2,
        text: '只需要准备好一篇文稿，就能轻松开始录制。',
        expectedDurationMs: 4_000,
        pauseAfterMs: 400,
      ),
    ],
  );
  var lastText = '';
  var advances = 0;
  var lastAdvancedIndex = -1;
  var monotonic = true;
  final transitions = <String>[];
  const chunkSamples = 3_200; // 200 ms at 16 kHz, matching NativeAudioCapture.

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
      final endpoint = recognizer.isEndpoint(stream);
      if (text.isNotEmpty && text != lastText) {
        lastText = text;
        final decision = engine.evaluate(
          AsrPartial(
            text: text,
            timestampMs: (end * 1000) ~/ wave.sampleRate,
            isFinal: endpoint,
            speechPause: endpoint,
          ),
        );
        if (decision.shouldAdvance) {
          advances++;
          if (decision.currentLineIndex <= lastAdvancedIndex) {
            monotonic = false;
          }
          lastAdvancedIndex = decision.currentLineIndex;
          transitions.add(
            '${decision.currentLineIndex - 1}->${decision.currentLineIndex}'
            ' (${decision.reason}, ${decision.coverage.toStringAsFixed(2)})',
          );
        }
      }
      if (endpoint) recognizer.reset(stream);
    }

    stream.inputFinished();
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    final text = recognizer.getResult(stream).text.trim();
    if (text.isNotEmpty && text != lastText) {
      final decision = engine.evaluate(
        AsrPartial(
          text: text,
          timestampMs: (wave.samples.length * 1000) ~/ wave.sampleRate,
          isFinal: true,
          speechPause: true,
        ),
      );
      if (decision.shouldAdvance) {
        advances++;
        if (decision.currentLineIndex <= lastAdvancedIndex) {
          monotonic = false;
        }
        lastAdvancedIndex = decision.currentLineIndex;
        transitions.add(
          '${decision.currentLineIndex - 1}->${decision.currentLineIndex}'
          ' (${decision.reason}, ${decision.coverage.toStringAsFixed(2)})',
        );
      }
    }
  } finally {
    stream.free();
    recognizer.free();
  }

  stdout.writeln('recognized: $lastText');
  stdout.writeln('advances: $advances');
  for (final transition in transitions) {
    stdout.writeln('transition: $transition');
  }
  stdout.writeln('monotonic: $monotonic');
  if (lastText.isEmpty || advances < minimumAdvances || !monotonic) {
    stderr.writeln(
      'alignment smoke did not meet stable monotonic advance requirement '
      '(minimum=$minimumAdvances)',
    );
    exitCode = 1;
  }
}
