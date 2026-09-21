import 'package:flutter_test/flutter_test.dart';
import 'package:script_mirror/domain/script_models.dart';

void main() {
  test('capture resolution profiles expose stable dimensions and labels', () {
    expect(CaptureResolution.hd720.width, 1280);
    expect(CaptureResolution.hd720.height, 720);
    expect(CaptureResolution.hd720.label, '720p');
    expect(CaptureResolution.fhd1080.width, 1920);
    expect(CaptureResolution.fhd1080.height, 1080);
    expect(CaptureResolution.fhd1080.label, '1080p');
  });

  test('settings preserve the selected capture resolution', () {
    const defaults = AppSettings();
    final hd = defaults.copyWith(captureResolution: CaptureResolution.hd720);

    expect(defaults.captureResolution, CaptureResolution.fhd1080);
    expect(hd.captureResolution, CaptureResolution.hd720);
    expect(
      CaptureResolution.fromName(hd.captureResolution.name),
      CaptureResolution.hd720,
    );
    expect(CaptureResolution.fromName('unknown'), CaptureResolution.fhd1080);
  });

  test('settings normalization repairs values outside supported UI ranges', () {
    const unsafe = AppSettings(
      fontSize: 100,
      backgroundOpacity: 2,
      lookaheadLines: 0,
      lineHeight: .2,
    );

    final safe = unsafe.normalized();

    expect(safe.fontSize, 42);
    expect(safe.backgroundOpacity, .9);
    expect(safe.lookaheadLines, 1);
    expect(safe.lineHeight, 1.15);
  });

  test('automatic recognition language follows the script characters', () {
    expect(
      detectRecognitionLanguage(const ['Stay focused on the lens.']),
      RecognitionLanguage.english,
    );
    expect(
      detectRecognitionLanguage(const ['看着镜头，不要忘记下一句。']),
      RecognitionLanguage.chinese,
    );
  });

  test('recognition language is preserved by settings copyWith', () {
    const settings = AppSettings(
      recognitionLanguage: RecognitionLanguage.english,
    );
    expect(
      settings.copyWith().recognitionLanguage,
      RecognitionLanguage.english,
    );
    expect(
      RecognitionLanguageX.fromStorage(
        settings.recognitionLanguage.storageValue,
      ),
      RecognitionLanguage.english,
    );
  });
}
