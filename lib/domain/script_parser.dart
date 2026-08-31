import 'script_models.dart';

/// Turns pasted prose into stable teleprompter units.
class ScriptParser {
  const ScriptParser();

  static final RegExp _sentenceEnd = RegExp(r'[。！？!?；;.]+');
  static final RegExp _lineBreak = RegExp(r'[\r\n]+');

  List<ScriptLine> split(String source) {
    final normalized = source.replaceAll('\u00a0', ' ').trim();
    if (normalized.isEmpty) return <ScriptLine>[];

    final chunks = <String>[];
    for (final paragraph in normalized.split(_lineBreak)) {
      final value = paragraph.trim();
      if (value.isEmpty) continue;
      var start = 0;
      for (final match in _sentenceEnd.allMatches(value)) {
        // A decimal point is part of the token, not a sentence boundary.
        // Keep the check local so the sentence regex remains conservative.
        if (match.group(0) == '.' &&
            match.start > 0 &&
            match.end < value.length &&
            _isAsciiDigit(value.codeUnitAt(match.start - 1)) &&
            _isAsciiDigit(value.codeUnitAt(match.end))) {
          continue;
        }
        final end = match.end;
        final sentence = value.substring(start, end).trim();
        if (sentence.isNotEmpty) chunks.add(sentence);
        start = end;
      }
      final tail = value.substring(start).trim();
      if (tail.isNotEmpty) chunks.add(tail);
    }

    return List<ScriptLine>.generate(chunks.length, (index) {
      final text = chunks[index];
      return ScriptLine(
        id: 'line-${index + 1}',
        order: index,
        text: text,
        expectedDurationMs: estimateDurationMs(text),
        pauseAfterMs: estimatePauseMs(text),
      );
    });
  }

  /// Uses a deliberately conservative speaking rate: Chinese characters and
  /// Latin words are counted separately so mixed scripts remain readable.
  static int estimateDurationMs(String text) {
    final han = RegExp(r'[\u3400-\u9fff]').allMatches(text).length;
    final latinWords = RegExp(r'[A-Za-z0-9]+').allMatches(text).length;
    final punctuation = RegExp(r'[，,、]').allMatches(text).length;
    final units = han + (latinWords * 2);
    return ((units * 235) + (punctuation * 110)).clamp(1200, 120000).toInt();
  }

  static int estimatePauseMs(String text) {
    if (RegExp(r'[！？!?]').hasMatch(text)) return 650;
    if (RegExp(r'[。；;]').hasMatch(text)) return 450;
    if (RegExp(r'[，,、]').hasMatch(text)) return 240;
    return 300;
  }

  static bool _isAsciiDigit(int codeUnit) =>
      codeUnit >= 0x30 && codeUnit <= 0x39;
}
