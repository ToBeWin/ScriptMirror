/**
 * 镜词（Jingci / ScriptMirror）— Vibe Coding Agent Contract
 *
 * This is an executable project brief for coding agents. Read it before making
 * changes. It intentionally describes product decisions, guardrails, and the
 * definition of done; it is not runtime application code.
 */
module.exports = {
  product: {
    name: '镜词',
    englishName: 'ScriptMirror',
    tagline: '看着镜头，也不用忘记下一句。',
    oneLiner: '一款离线优先的手机自拍视频提词器：在录制时用文稿对齐辅助推进台词。',
    targetUsers: ['需要自拍口播的个人创作者', '课程讲师', '销售与演讲练习者'],
    nonGoals: ['账号体系', '社交社区', '云端视频托管', '滤镜/美颜工作站', '通用会议转写'],
  },

  delivery: {
    firstTarget: 'Android',
    architectureTarget: 'Android-first, iOS-ready',
    uiFramework: 'Flutter',
    nativeModules: { android: 'Kotlin', ios: 'Swift (future)' },
    minimumAndroidSdk: 26,
    offlineFirst: true,
    initialApkGoal: 'Release APK/AAB should stay below 60 MB excluding optional offline language packs.',
  },

  engineeringPrinciples: [
    'Recording comes before intelligence: ASR failure must never stop or corrupt recording.',
    'Treat the provided script as a constrained alignment target, not as an optional transcript comparison.',
    'Keep the capture screen calm: only the controls needed during recording are visible.',
    'No account, telemetry, network request, or cloud upload is enabled by default.',
    'All state transitions are explicit, testable, idempotent where practical, and recoverable after interruption.',
    'Do not add large ML models to the base install. Download language packs only after explicit user action.',
    'Prefer platform APIs and a small number of maintained dependencies over clever plugin stacks.',
  ],

  mandatoryArchitecture: {
    flutterOwns: [
      'navigation', 'script editing and local persistence', 'teleprompter renderer and animation',
      'alignment state machine', 'settings', 'recording-session UI state',
    ],
    nativeOwns: [
      'camera preview and video muxing', 'single microphone capture pipeline',
      'audio fan-out to video recording and ASR', 'platform permissions and interruption handling',
      'ASR provider adapter', 'media-store save and recovery',
    ],
    rule: 'Never let two unrelated plugins independently open the microphone during a recording session. One native audio owner must fan audio out to recording and recognition.',
  },

  featureScope: {
    mustHave: [
      'Paste/create/edit scripts; auto split at Chinese and English sentence punctuation; allow merge/split/reorder.',
      'Per-line expected duration and post-line pause, with sensible automatic defaults.',
      'Front/rear video capture, countdown, start/stop, and video saved to the device gallery.',
      'Upper-half translucent teleprompter overlay showing current line and 2 future lines.',
      'Adjustable font size, line spacing, overlay opacity, future-line count, mirror preview, and camera resolution.',
      'Timed progression fallback plus manual previous/next controls while recording.',
      'Streaming partial-ASR events and script alignment that advances lines conservatively.',
      'Clear ASR state: unavailable, initializing, listening, degraded, and offline/online mode.',
      'Safe recovery when the app is interrupted; retain the current script position and preserve completed media when possible.',
    ],
    later: [
      'Optional downloadable offline Chinese recognition pack.',
      'Script rehearsal that estimates per-line duration.',
      'Multiple languages, external microphone support, remote clicker, and caption export.',
    ],
    doNotBuildForV1: [
      'Login, sync, subscriptions, collaboration, social feeds, AI copywriting, face filters, dual-camera capture.',
    ],
  },

  alignmentContract: {
    input: 'Partial ASR text events with timestamp and confidence when available.',
    searchWindow: 'Previous line, current line, and next 3 lines only.',
    normalize: ['lowercase Latin text', 'remove punctuation and whitespace', 'normalize Chinese/Arabic numerals', 'collapse filler words when configured'],
    matching: ['character n-gram similarity', 'keyword-weighted overlap', 'prefix progress', 'short rolling history'],
    advanceWhen: [
      'Current-line coverage is at least 80%, OR',
      'Coverage is at least 65% and a speech pause is detected, OR',
      'Timed fallback expires and the user has not disabled auto advance.',
    ],
    protections: [
      'Require stable evidence across multiple partial events before automatic line change.',
      'Use a higher threshold for jumping over a line than for advancing one line.',
      'Never move backwards automatically; manual previous is always available.',
      'Keep the current line visible during uncertainty; do not make the UI flicker.',
    ],
  },

  qualityGates: {
    recording: [
      'A 10-minute 1080p test completes on each supported test device without recording failure.',
      'Video contains usable audio and can be found in the system gallery after success.',
      'On forced interruption, the user is told what was saved and can resume script position.',
    ],
    alignment: [
      'Manual controls work with ASR completely disabled.',
      'Normal-speed, fast, and slow Chinese reads advance in the expected order without visible oscillation.',
      'A skipped line does not cause repeated forward/backward jumping.',
    ],
    UX: [
      'First recording can be started within three taps after a script is selected.',
      'Recording controls remain reachable with one thumb and have at least 48dp hit areas.',
      'The overlay is readable in bright and dark camera scenes at all supported font sizes.',
    ],
    privacy: [
      'No network call occurs unless the user deliberately enables an online ASR provider.',
      'Permissions are requested immediately before their related action and explain why.',
    ],
  },

  workingRules: [
    'Before adding a dependency, justify its binary-size, maintenance, and Android compatibility cost.',
    'Use repository abstractions for media, scripts, settings, and ASR; UI must not call platform APIs directly.',
    'Write unit tests for normalization, matching score, line-advance thresholds, and recovery state transitions.',
    'Use integration/device tests for permissions, recording lifecycle, camera switching, and interruption recovery.',
    'Never log raw scripts, transcripts, audio, video paths, or permission results in release builds.',
    'Keep every user-visible string localizable. Chinese is the initial locale.',
    'When an implementation choice conflicts with stability, select stability and document the degraded behavior.',
  ],
};
