import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:script_mirror/domain/asr_provider.dart';
import 'package:script_mirror/domain/script_models.dart';
import 'package:script_mirror/platform/sherpa_asr_provider.dart';

void main() {
  test('unavailable provider reports a truthful fallback state', () async {
    final provider = UnavailableAsrProvider();
    final events = <AsrStatusEvent>[];
    final subscription = provider.status.listen(events.add);

    expect(await provider.start(), isFalse);
    await Future<void>.delayed(Duration.zero);

    expect(provider.currentStatus.status, AsrStatus.unavailable);
    expect(events.single.reason, contains('定时/手动'));

    await provider.stop();
    await Future<void>.delayed(Duration.zero);
    expect(provider.currentStatus.status, AsrStatus.stopped);

    await subscription.cancel();
    await provider.dispose();
  });

  test('pcm16ToFloat32 decodes little-endian signed samples', () {
    final bytes = Uint8List.fromList(<int>[
      0x00, 0x00, // 0.0
      0x00, 0x40, // 0.5
      0x00, 0xC0, // -0.5
      0xFF, 0x7F, // almost 1.0
    ]);

    expect(
      pcm16ToFloat32(bytes),
      orderedEquals(<double>[0, .5, -.5, 0.999969482421875]),
    );
  });

  test('sherpa provider selects the matching offline language model', () async {
    final english = SherpaAsrProvider(
      language: RecognitionLanguage.automatic,
      scriptLines: const ['Stay focused on the lens.'],
    );
    final chinese = SherpaAsrProvider(
      language: RecognitionLanguage.automatic,
      scriptLines: const ['看着镜头，不要忘记下一句。'],
    );
    final forcedEnglish = SherpaAsrProvider(
      language: RecognitionLanguage.english,
      scriptLines: const ['看着镜头'],
    );

    expect(english.resolvedLanguage, RecognitionLanguage.english);
    expect(chinese.resolvedLanguage, RecognitionLanguage.chinese);
    expect(forcedEnglish.resolvedLanguage, RecognitionLanguage.english);

    await english.dispose();
    await chinese.dispose();
    await forcedEnglish.dispose();
  });
}
