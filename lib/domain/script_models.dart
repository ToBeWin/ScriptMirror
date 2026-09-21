import '../i18n/app_strings.dart';

/// The smallest unit shown by the teleprompter and consumed by alignment.
class ScriptLine {
  ScriptLine({
    required this.id,
    required this.order,
    required this.text,
    required this.expectedDurationMs,
    required this.pauseAfterMs,
    this.keywords = const <String>[],
  });

  final String id;
  int order;
  String text;
  int expectedDurationMs;
  int pauseAfterMs;
  final List<String> keywords;

  ScriptLine copyWith({
    String? text,
    int? order,
    int? expectedDurationMs,
    int? pauseAfterMs,
  }) => ScriptLine(
    id: id,
    order: order ?? this.order,
    text: text ?? this.text,
    expectedDurationMs: expectedDurationMs ?? this.expectedDurationMs,
    pauseAfterMs: pauseAfterMs ?? this.pauseAfterMs,
    keywords: keywords,
  );
}

class Script {
  Script({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.lines,
  });

  final String id;
  String title;
  DateTime createdAt;
  DateTime updatedAt;
  final List<ScriptLine> lines;

  int get estimatedDurationMs => lines.fold<int>(
    0,
    (total, line) => total + line.expectedDurationMs + line.pauseAfterMs,
  );
}

/// Video profiles exposed to the user. CameraX may still choose a lower
/// profile on devices that cannot satisfy the request; the completion page
/// reports the actual encoded resolution from the saved media.
enum CaptureResolution {
  hd720(width: 1280, height: 720, label: '720p'),
  fhd1080(width: 1920, height: 1080, label: '1080p');

  const CaptureResolution({
    required this.width,
    required this.height,
    required this.label,
  });

  final int width;
  final int height;
  final String label;

  static CaptureResolution fromName(String? value) => switch (value) {
    'hd720' => CaptureResolution.hd720,
    'fhd1080' => CaptureResolution.fhd1080,
    _ => CaptureResolution.fhd1080,
  };
}

/// Language used by the on-device speech recognizer. This is intentionally
/// separate from [AppLanguage]: the interface language and the language a
/// creator speaks do not have to be the same.
enum RecognitionLanguage { automatic, chinese, english }

extension RecognitionLanguageX on RecognitionLanguage {
  String get storageValue => name;

  static RecognitionLanguage fromStorage(String? value) => switch (value) {
    'chinese' => RecognitionLanguage.chinese,
    'english' => RecognitionLanguage.english,
    _ => RecognitionLanguage.automatic,
  };
}

/// Chooses the bundled recognizer for a script when the user leaves language
/// selection on automatic. A small CJK/Latin ratio is more reliable than the
/// app UI language for international creators who keep English UI with a
/// Chinese script (or the reverse).
RecognitionLanguage detectRecognitionLanguage(Iterable<String> lines) {
  final text = lines.join(' ');
  final cjkCount = RegExp(r'[\u3400-\u9fff]').allMatches(text).length;
  final latinCount = RegExp(r'[A-Za-z]').allMatches(text).length;
  if (latinCount > cjkCount) return RecognitionLanguage.english;
  return RecognitionLanguage.chinese;
}

/// User-level teleprompter and capture preferences. Values are intentionally
/// small and serializable so they can be persisted alongside scripts in
/// SQLite.
class AppSettings {
  const AppSettings({
    this.fontSize = 32,
    this.backgroundOpacity = .55,
    this.lookaheadLines = 2,
    this.lineHeight = 1.35,
    this.mirrorPreview = true,
    this.captureResolution = CaptureResolution.fhd1080,
    this.recognitionLanguage = RecognitionLanguage.automatic,
    this.language = AppLanguage.english,
  });

  final double fontSize;
  final double backgroundOpacity;
  final int lookaheadLines;
  final double lineHeight;
  final bool mirrorPreview;
  final CaptureResolution captureResolution;
  final RecognitionLanguage recognitionLanguage;
  final AppLanguage language;

  /// Keeps persisted or externally supplied values inside the ranges that the
  /// settings sheets and the recording renderer can safely consume. This is
  /// intentionally separate from the const constructor so old/corrupt local
  /// databases can be repaired without changing the public model contract.
  AppSettings normalized() => AppSettings(
    fontSize: fontSize.isFinite ? fontSize.clamp(18, 42).toDouble() : 32,
    backgroundOpacity: backgroundOpacity.isFinite
        ? backgroundOpacity.clamp(.2, .9).toDouble()
        : .55,
    lookaheadLines: lookaheadLines.clamp(1, 3),
    lineHeight: lineHeight.isFinite
        ? lineHeight.clamp(1.15, 1.8).toDouble()
        : 1.35,
    mirrorPreview: mirrorPreview,
    captureResolution: captureResolution,
    recognitionLanguage: recognitionLanguage,
    language: language,
  );

  AppSettings copyWith({
    double? fontSize,
    double? backgroundOpacity,
    int? lookaheadLines,
    double? lineHeight,
    bool? mirrorPreview,
    CaptureResolution? captureResolution,
    RecognitionLanguage? recognitionLanguage,
    AppLanguage? language,
  }) => AppSettings(
    fontSize: fontSize ?? this.fontSize,
    backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
    lookaheadLines: lookaheadLines ?? this.lookaheadLines,
    lineHeight: lineHeight ?? this.lineHeight,
    mirrorPreview: mirrorPreview ?? this.mirrorPreview,
    captureResolution: captureResolution ?? this.captureResolution,
    recognitionLanguage: recognitionLanguage ?? this.recognitionLanguage,
    language: language ?? this.language,
  );
}

enum RecoveryState { recording, stopping }

/// Single active capture checkpoint used to offer a truthful resume path after
/// an app interruption. Media is still finalized by the native capture owner.
class CaptureRecovery {
  const CaptureRecovery({
    required this.scriptId,
    required this.currentLineIndex,
    required this.startedAtMs,
    this.mediaUri,
    this.state = RecoveryState.recording,
  });

  final String scriptId;
  final int currentLineIndex;
  final int startedAtMs;
  final String? mediaUri;
  final RecoveryState state;
}

enum RecognitionMode { disabled, system, online, offline }

enum CapturePhase {
  idle,
  preparing,
  countdown,
  recording,
  stopping,
  completed,
  failed,
}

enum AlignmentState {
  unavailable,
  initializing,
  listening,
  confirming,
  degraded,
}

class TeleprompterSession {
  TeleprompterSession({
    required this.scriptId,
    this.currentLineIndex = 0,
    this.manualOverrideUntilMs,
    this.recognitionMode = RecognitionMode.disabled,
    this.alignmentState = AlignmentState.unavailable,
    this.capturePhase = CapturePhase.idle,
  });

  final String scriptId;
  int currentLineIndex;
  int? manualOverrideUntilMs;
  RecognitionMode recognitionMode;
  AlignmentState alignmentState;
  CapturePhase capturePhase;
}
