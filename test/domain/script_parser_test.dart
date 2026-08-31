import 'package:flutter_test/flutter_test.dart';
import 'package:script_mirror/domain/script_parser.dart';

void main() {
  const parser = ScriptParser();

  test('splits Chinese and English sentence punctuation', () {
    final lines = parser.split('第一句。第二句！ Is this third? Fourth sentence.\n第五句');
    expect(lines.map((line) => line.text), <String>[
      '第一句。',
      '第二句！',
      'Is this third?',
      'Fourth sentence.',
      '第五句',
    ]);
    expect(lines.map((line) => line.order), <int>[0, 1, 2, 3, 4]);
  });

  test('keeps decimal points inside a sentence', () {
    final lines = parser.split('版本是 3.14。下一句。');
    expect(lines.map((line) => line.text), <String>['版本是 3.14。', '下一句。']);
  });

  test('keeps punctuation in the line and estimates useful defaults', () {
    final line = parser.split('今天分享三个方法；')[0];
    expect(line.expectedDurationMs, greaterThanOrEqualTo(1200));
    expect(line.pauseAfterMs, 450);
  });

  test('ignores empty paragraphs', () {
    expect(parser.split('  \n\n  '), isEmpty);
  });
}
