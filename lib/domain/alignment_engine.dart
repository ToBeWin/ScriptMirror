import 'script_models.dart';

class AsrPartial {
  const AsrPartial({
    required this.text,
    required this.timestampMs,
    this.isFinal = false,
    this.confidence,
    this.speechPause = false,
  });

  final String text;
  final int timestampMs;
  final bool isFinal;
  final double? confidence;
  final bool speechPause;
}

class AlignmentDecision {
  const AlignmentDecision({
    required this.currentLineIndex,
    required this.candidateLineIndex,
    required this.coverage,
    required this.shouldAdvance,
    required this.reason,
  });

  final int currentLineIndex;
  final int candidateLineIndex;
  final double coverage;
  final bool shouldAdvance;
  final String reason;
}

/// Normalization is intentionally conservative: it removes presentation noise
/// while keeping the words that define a script line.
class TextNormalizer {
  const TextNormalizer({this.removeFillers = true});

  final bool removeFillers;

  String normalize(String input) {
    var value = input
        .toLowerCase()
        .replaceAll('〇', '0')
        .replaceAll('一', '1')
        .replaceAll('二', '2')
        .replaceAll('三', '3')
        .replaceAll('四', '4')
        .replaceAll('五', '5')
        .replaceAll('六', '6')
        .replaceAll('七', '7')
        .replaceAll('八', '8')
        .replaceAll('九', '9')
        .replaceAll('十', '10');
    if (removeFillers) {
      value = value.replaceAll(RegExp(r'(嗯+|呃+|那个|就是说)'), '');
    }
    return value.replaceAll(RegExp(r'[^\u3400-\u9fffA-Za-z0-9]+'), '');
  }
}

class _LineScore {
  const _LineScore(this.coverage, this.score);

  final double coverage;
  final double score;
}

/// Conservative, script-constrained alignment for streaming ASR partials.
/// It never moves backwards automatically and only evaluates a small window.
class AlignmentEngine {
  AlignmentEngine({
    required List<ScriptLine> lines,
    this.normalizer = const TextNormalizer(),
    this.autoAdvance = true,
    this.manualFreezeDurationMs = 1800,
  }) : _lines = List<ScriptLine>.unmodifiable(lines);

  final List<ScriptLine> _lines;
  final TextNormalizer normalizer;
  final bool autoAdvance;
  final int manualFreezeDurationMs;
  final List<String> _recentPartials = <String>[];
  int currentLineIndex = 0;
  int? _stableCandidate;
  int _stableEvidence = 0;
  int _manualFreezeUntilMs = 0;
  bool _clearPartialsBeforeNextEvaluation = false;

  AlignmentDecision evaluate(AsrPartial partial) {
    if (_clearPartialsBeforeNextEvaluation) {
      _recentPartials.clear();
      _clearPartialsBeforeNextEvaluation = false;
    }
    if (_lines.isEmpty) {
      return const AlignmentDecision(
        currentLineIndex: 0,
        candidateLineIndex: 0,
        coverage: 0,
        shouldAdvance: false,
        reason: 'emptyScript',
      );
    }

    final normalized = normalizer.normalize(partial.text);
    if (normalized.isNotEmpty) {
      _rememberPartial(normalized);
    }
    // sherpa-onnx emits cumulative text for a streaming utterance. A pause
    // closes that utterance; keep its text for this final evaluation, then
    // start the next utterance with a clean matching window.
    _clearPartialsBeforeNextEvaluation = partial.speechPause;
    final merged = _recentPartials.join();
    if (merged.isEmpty) return _stay('noSpeech');

    final start = (currentLineIndex - 1).clamp(0, _lines.length - 1).toInt();
    final end = (currentLineIndex + 3).clamp(0, _lines.length - 1).toInt();
    var bestIndex = currentLineIndex;
    var best = _score(merged, _lines[currentLineIndex].text);
    for (var index = start; index <= end; index++) {
      final score = _score(merged, _lines[index].text);
      if (score.score > best.score) {
        best = score;
        bestIndex = index;
      }
    }

    if (!autoAdvance || partial.timestampMs < _manualFreezeUntilMs) {
      return AlignmentDecision(
        currentLineIndex: currentLineIndex,
        candidateLineIndex: bestIndex < currentLineIndex
            ? currentLineIndex
            : bestIndex,
        coverage: best.coverage,
        shouldAdvance: false,
        reason: !autoAdvance ? 'autoAdvanceDisabled' : 'manualFreeze',
      );
    }

    final currentCoverage = _score(
      merged,
      _lines[currentLineIndex].text,
    ).coverage;
    final qualifies =
        currentCoverage >= .8 ||
        (currentCoverage >= .65 && partial.speechPause);
    if (!qualifies) {
      _resetEvidence();
      return AlignmentDecision(
        currentLineIndex: currentLineIndex,
        candidateLineIndex: bestIndex < currentLineIndex
            ? currentLineIndex
            : bestIndex,
        coverage: currentCoverage,
        shouldAdvance: false,
        reason: 'insufficientCoverage',
      );
    }

    final target = bestIndex > currentLineIndex
        ? bestIndex
        : (currentLineIndex + 1).clamp(0, _lines.length - 1).toInt();
    final isJump = target > currentLineIndex + 1;
    final requiredCoverage = isJump ? .9 : .8;
    final targetCoverage = _score(merged, _lines[target].text).coverage;
    if (isJump && targetCoverage < requiredCoverage) {
      _resetEvidence();
      return _stay(
        'jumpNeedsMoreEvidence',
        coverage: targetCoverage,
        candidate: target,
      );
    }

    if (_stableCandidate == target) {
      _stableEvidence++;
    } else {
      _stableCandidate = target;
      _stableEvidence = 1;
    }
    if (_stableEvidence < 2) {
      return _stay('confirming', coverage: targetCoverage, candidate: target);
    }

    final previousIndex = currentLineIndex;
    currentLineIndex = target;
    _resetEvidence();
    return AlignmentDecision(
      currentLineIndex: currentLineIndex,
      candidateLineIndex: target,
      coverage: targetCoverage,
      shouldAdvance: target != previousIndex,
      reason: isJump ? 'stableSkip' : 'stableCoverage',
    );
  }

  AlignmentDecision manualMove(int index, {required int timestampMs}) {
    if (_lines.isEmpty) return _stay('emptyScript');
    currentLineIndex = index.clamp(0, _lines.length - 1).toInt();
    _manualFreezeUntilMs = timestampMs + manualFreezeDurationMs;
    _recentPartials.clear();
    _resetEvidence();
    return AlignmentDecision(
      currentLineIndex: currentLineIndex,
      candidateLineIndex: currentLineIndex,
      coverage: 1,
      shouldAdvance: true,
      reason: 'manualMove',
    );
  }

  AlignmentDecision timedFallback({required int timestampMs}) {
    if (!autoAdvance || timestampMs < _manualFreezeUntilMs || _lines.isEmpty) {
      return _stay(
        timestampMs < _manualFreezeUntilMs
            ? 'manualFreeze'
            : 'timedFallbackDisabled',
      );
    }
    if (currentLineIndex >= _lines.length - 1) return _stay('endOfScript');
    currentLineIndex++;
    _recentPartials.clear();
    _resetEvidence();
    return AlignmentDecision(
      currentLineIndex: currentLineIndex,
      candidateLineIndex: currentLineIndex,
      coverage: 0,
      shouldAdvance: true,
      reason: 'timedFallback',
    );
  }

  AlignmentDecision _stay(
    String reason, {
    double coverage = 0,
    int? candidate,
  }) => AlignmentDecision(
    currentLineIndex: currentLineIndex,
    candidateLineIndex: candidate ?? currentLineIndex,
    coverage: coverage,
    shouldAdvance: false,
    reason: reason,
  );

  void _resetEvidence() {
    _stableCandidate = null;
    _stableEvidence = 0;
  }

  void _rememberPartial(String normalized) {
    final previous = _recentPartials.isEmpty ? null : _recentPartials.last;
    if (previous != null) {
      // Streaming recognizers normally repeat the already-decoded prefix.
      // Replace that prefix instead of joining it again, which would make a
      // single utterance look like duplicated speech to the matcher.
      if (normalized.startsWith(previous) || normalized == previous) {
        _recentPartials[_recentPartials.length - 1] = normalized;
        return;
      }
      // Ignore a late shorter correction when it is still a prefix of the
      // latest text; the next longer partial will replace it.
      if (previous.startsWith(normalized)) return;
    }
    _recentPartials.add(normalized);
    if (_recentPartials.length > 5) _recentPartials.removeAt(0);
  }

  _LineScore _score(String partial, String line) {
    final target = normalizer.normalize(line);
    if (target.isEmpty) return const _LineScore(0, 0);
    final lcs = _longestCommonSubsequence(partial, target);
    final coverage = lcs / target.length;
    final prefix = _commonPrefix(partial, target) / target.length;
    final ngram = _bigramSimilarity(partial, target);
    return _LineScore(
      coverage,
      (coverage * .6) + (prefix * .25) + (ngram * .15),
    );
  }

  int _commonPrefix(String a, String b) {
    final length = a.length < b.length ? a.length : b.length;
    var index = 0;
    while (index < length && a.codeUnitAt(index) == b.codeUnitAt(index)) {
      index++;
    }
    return index;
  }

  double _bigramSimilarity(String a, String b) {
    if (a.length < 2 || b.length < 2) return a == b ? 1 : 0;
    final aBigrams = <String>{
      for (var i = 0; i < a.length - 1; i++) a.substring(i, i + 2),
    };
    final bBigrams = <String>{
      for (var i = 0; i < b.length - 1; i++) b.substring(i, i + 2),
    };
    final intersection = aBigrams.intersection(bBigrams).length;
    return (2 * intersection) / (aBigrams.length + bBigrams.length);
  }

  int _longestCommonSubsequence(String a, String b) {
    final previous = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      var diagonal = 0;
      for (var j = 1; j <= b.length; j++) {
        final top = previous[j];
        if (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1)) {
          previous[j] = diagonal + 1;
        } else if (previous[j - 1] > previous[j]) {
          previous[j] = previous[j - 1];
        }
        diagonal = top;
      }
    }
    return previous[b.length];
  }
}
