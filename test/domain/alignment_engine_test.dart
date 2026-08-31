import 'package:flutter_test/flutter_test.dart';
import 'package:script_mirror/domain/alignment_engine.dart';
import 'package:script_mirror/domain/script_models.dart';

List<ScriptLine> _lines() => [
  ScriptLine(
    id: '1',
    order: 0,
    text: '今天分享一个方法。',
    expectedDurationMs: 2000,
    pauseAfterMs: 400,
  ),
  ScriptLine(
    id: '2',
    order: 1,
    text: '它能让你不再担心忘词。',
    expectedDurationMs: 2500,
    pauseAfterMs: 400,
  ),
  ScriptLine(
    id: '3',
    order: 2,
    text: '同时保持自然的眼神表达。',
    expectedDurationMs: 2500,
    pauseAfterMs: 400,
  ),
  ScriptLine(
    id: '4',
    order: 3,
    text: '现在开始录制。',
    expectedDurationMs: 1800,
    pauseAfterMs: 400,
  ),
];

void main() {
  test('normalizer removes punctuation and configured fillers', () {
    const normalizer = TextNormalizer();
    expect(normalizer.normalize('嗯，今天分享！'), '今天分享');
    expect(normalizer.normalize('Hello, WORLD!'), 'helloworld');
  });

  test('requires stable evidence before advancing', () {
    final engine = AlignmentEngine(lines: _lines());
    final first = engine.evaluate(
      const AsrPartial(text: '今天分享一个方法', timestampMs: 100),
    );
    expect(first.shouldAdvance, isFalse);
    expect(first.reason, 'confirming');

    final second = engine.evaluate(
      const AsrPartial(text: '今天分享一个方法。', timestampMs: 200),
    );
    expect(second.shouldAdvance, isTrue);
    expect(second.currentLineIndex, 1);
  });

  test('manual movement freezes automatic alignment temporarily', () {
    final engine = AlignmentEngine(lines: _lines());
    final moved = engine.manualMove(2, timestampMs: 1000);
    expect(moved.currentLineIndex, 2);
    final frozen = engine.evaluate(
      const AsrPartial(text: '它能让你不再担心忘词', timestampMs: 1500),
    );
    expect(frozen.shouldAdvance, isFalse);
    expect(frozen.reason, 'manualFreeze');
  });

  test('cumulative ASR partials reset their matching window after a pause', () {
    final engine = AlignmentEngine(
      lines: [
        ScriptLine(
          id: 'a',
          order: 0,
          text: 'aaaaaaaa',
          expectedDurationMs: 1000,
          pauseAfterMs: 0,
        ),
        ScriptLine(
          id: 'b',
          order: 1,
          text: 'bbbbbbbb',
          expectedDurationMs: 1000,
          pauseAfterMs: 0,
        ),
        ScriptLine(
          id: 'c',
          order: 2,
          text: 'cccccccc',
          expectedDurationMs: 1000,
          pauseAfterMs: 0,
        ),
        ScriptLine(
          id: 'd',
          order: 3,
          text: 'aaaaaaaabbbbbb',
          expectedDurationMs: 1000,
          pauseAfterMs: 0,
        ),
      ],
    );

    engine.evaluate(const AsrPartial(text: 'aaaaaaaa', timestampMs: 0));
    final firstEnd = engine.evaluate(
      const AsrPartial(text: 'aaaaaaaa', timestampMs: 100, speechPause: true),
    );
    expect(firstEnd.currentLineIndex, 1);

    engine.evaluate(const AsrPartial(text: 'bbbbbbb', timestampMs: 200));
    final secondEnd = engine.evaluate(
      const AsrPartial(text: 'bbbbbbb', timestampMs: 300, speechPause: true),
    );
    expect(secondEnd.currentLineIndex, 2);
    expect(secondEnd.reason, 'stableCoverage');
  });

  test('timed fallback never moves past the last line', () {
    final engine = AlignmentEngine(lines: _lines());
    for (var i = 0; i < 3; i++) {
      engine.timedFallback(timestampMs: i * 5000);
    }
    final end = engine.timedFallback(timestampMs: 20000);
    expect(end.currentLineIndex, 3);
    expect(end.shouldAdvance, isFalse);
    expect(end.reason, 'endOfScript');
  });

  test('late recognition from a previous line never moves the script back', () {
    final engine = AlignmentEngine(lines: _lines());
    engine.evaluate(
      const AsrPartial(text: '今天分享一个方法', timestampMs: 100),
    );
    final advanced = engine.evaluate(
      const AsrPartial(text: '今天分享一个方法', timestampMs: 200),
    );
    expect(advanced.currentLineIndex, 1);
    expect(advanced.shouldAdvance, isTrue);

    final latePrevious = engine.evaluate(
      const AsrPartial(text: '今天分享一个方法', timestampMs: 300),
    );
    expect(latePrevious.currentLineIndex, 1);
    expect(latePrevious.shouldAdvance, isFalse);
  });
}
