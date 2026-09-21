import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:script_mirror/data/script_repository.dart';
import 'package:script_mirror/data/session_recovery_repository.dart';
import 'package:script_mirror/data/settings_repository.dart';
import 'package:script_mirror/domain/script_models.dart' as domain;
import 'package:script_mirror/i18n/app_strings.dart';
import 'package:script_mirror/main.dart';
import 'package:script_mirror/platform/capture_service.dart';

class _MemorySettingsRepository implements SettingsRepository {
  _MemorySettingsRepository()
    : settings = const domain.AppSettings(language: AppLanguage.chinese);

  domain.AppSettings settings;

  @override
  Future<domain.AppSettings> loadSettings() async => settings;

  @override
  Future<void> saveSettings(domain.AppSettings next) async {
    settings = next;
  }
}

class _MemoryRecoveryRepository implements SessionRecoveryRepository {
  int clearCount = 0;

  @override
  Future<void> clearRecovery() async => clearCount++;

  @override
  Future<domain.CaptureRecovery?> loadActiveRecovery() async => null;

  @override
  Future<void> saveRecovery(domain.CaptureRecovery recovery) async {}
}

class _DelayedScriptRepository extends InMemoryScriptRepository {
  _DelayedScriptRepository(super.initial);

  @override
  Future<void> save(domain.Script script) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await super.save(script);
  }
}

void main() {
  // Keep the legacy interaction suite readable while the product's first-run
  // language is now English. Dedicated localization tests below exercise the
  // new default and the persisted language switch.
  setUp(() => AppStrings.setLanguage(AppLanguage.chinese));

  testWidgets('first run uses English product chrome', (tester) async {
    AppStrings.setLanguage(AppLanguage.english);
    await tester.pumpWidget(const ScriptMirrorApp());
    await tester.pumpAndSettle();

    expect(find.text('Start recording'), findsOneWidget);
    expect(find.text('开始拍摄'), findsNothing);
    expect(find.text('Recent scripts'), findsOneWidget);
  });

  testWidgets('language preference can switch and persist', (tester) async {
    final repository = _MemorySettingsRepository();
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byIcon(Icons.language_outlined),
      280,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byIcon(Icons.language_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(repository.settings.language, AppLanguage.english);
    expect(AppStrings.currentLanguage, AppLanguage.english);
    expect(find.text('Language'), findsWidgets);
  });

  testWidgets('home shows the primary capture flow', (tester) async {
    await tester.pumpWidget(const ScriptMirrorApp());

    expect(find.text('镜词'), findsOneWidget);
    expect(find.text('开始拍摄'), findsOneWidget);
    expect(find.text('最近文稿'), findsOneWidget);
  });

  testWidgets('user can open the preparation screen', (tester) async {
    await tester.pumpWidget(const ScriptMirrorApp());
    await tester.tap(find.text('开始拍摄'));
    await tester.pumpAndSettle();

    expect(find.text('拍摄准备'), findsOneWidget);
    expect(find.text('前置镜头'), findsOneWidget);
    expect(find.text('开始录制'), findsOneWidget);
    expect(find.text('夏季防晒分享'), findsOneWidget);
  });

  testWidgets('start recording ignores a rapid duplicate tap', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final channel = const MethodChannel('scriptmirror/capture');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'permissionsGranted':
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return true;
        case 'requestPermissions':
          return false;
        default:
          return null;
      }
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(const MaterialApp(home: PreparePage()));
    await tester.pumpAndSettle();
    final startButton = find.text('开始录制');
    await tester.ensureVisible(startButton);
    await tester.tap(startButton);
    await tester.pump();

    expect(find.text('正在准备…'), findsOneWidget);
    // The first tap locks the button before awaiting permissions; the second
    // tap must not start another permission flow or push another route.
    await tester.tap(find.text('正在准备…'));
    await tester.pump();
    expect(find.byType(RecordingPage), findsNothing);

    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('权限未开启，无法开始录制；请在系统设置重新允许相机和麦克风'), findsOneWidget);
    // Reset Flutter's global platform override before the test invariant
    // check runs; addTearDown remains a safety net for early failures.
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('compact viewport keeps the primary capture controls reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const ScriptMirrorApp());
    await tester.pumpAndSettle();
    expect(find.text('开始拍摄'), findsOneWidget);

    await tester.tap(find.text('开始拍摄'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('开始录制'),
      260,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('开始录制'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      const MaterialApp(home: RecordingPage(autoAdvance: false)),
    );
    await tester.pump();
    expect(find.text('取消'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sample script cards open their preparation flow', (
    tester,
  ) async {
    await tester.pumpWidget(const ScriptMirrorApp());
    await tester.tap(find.text('夏季防晒分享'));
    await tester.pumpAndSettle();

    expect(find.text('拍摄准备'), findsOneWidget);
    expect(find.text('今天我想分享一个很好用的拍摄方式。'), findsOneWidget);
  });

  testWidgets('auto advance tile toggles from its body', (tester) async {
    await tester.pumpWidget(const ScriptMirrorApp());
    await tester.tap(find.text('开始拍摄'));
    await tester.pumpAndSettle();

    expect(find.text('按预设时长自动滚动'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('自动推进'),
      280,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('自动推进'));
    await tester.pump();
    expect(find.text('手动翻句'), findsOneWidget);

    await tester.tap(find.text('自动推进'));
    await tester.pump();
    expect(find.text('按预设时长自动滚动'), findsOneWidget);
  });

  testWidgets('settings persist mirror and resolution changes', (tester) async {
    final repository = _MemorySettingsRepository();
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('自拍镜像'),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('自拍镜像'));
    await tester.pumpAndSettle();
    expect(find.byType(Switch), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('预览与成片均正常'), findsOneWidget);
    expect(repository.settings.mirrorPreview, isFalse);

    await tester.tap(find.text('默认画质'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('720p').last);
    await tester.pumpAndSettle();
    expect(find.text('720p'), findsOneWidget);
    expect(
      repository.settings.captureResolution,
      domain.CaptureResolution.hd720,
    );

    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(find.text('预览与成片均正常'), findsOneWidget);
    expect(find.text('720p'), findsOneWidget);
  });

  testWidgets('informational settings rows open helpful details', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    // Rows that explain system storage and privacy are still real interaction
    // targets, so a user never taps a feature-looking row and gets silence.
    await tester.ensureVisible(find.text('存储位置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('存储位置').first);
    await tester.pumpAndSettle();
    expect(find.text('知道了'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('语音识别').first);
    await tester.pumpAndSettle();
    expect(find.text('知道了'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('关于镜词').first);
    await tester.pumpAndSettle();
    expect(find.text('知道了'), findsOneWidget);
  });

  testWidgets('new script opens the structured entry workspace', (
    tester,
  ) async {
    await tester.pumpWidget(const ScriptMirrorApp());
    await tester.tap(find.text('新建文稿'));
    await tester.pumpAndSettle();

    expect(find.text('新建文稿'), findsOneWidget);
    expect(find.text('先把想说的话放进来'), findsOneWidget);
    expect(find.text('文稿信息'), findsOneWidget);
    expect(find.text('台词内容'), findsOneWidget);
    expect(find.text('整理台词并继续'), findsOneWidget);
  });

  testWidgets('new script exposes TXT and Markdown import', (tester) async {
    await tester.pumpWidget(const ScriptMirrorApp());
    await tester.tap(find.text('新建文稿'));
    await tester.pumpAndSettle();

    expect(find.text('导入文稿'), findsOneWidget);
    expect(find.byTooltip('导入文稿'), findsOneWidget);
  });

  testWidgets('new script protects an unfinished draft on back', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ScriptEntryPage()));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.last, '这是一段还没有保存的台词。');
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(find.text('放弃这篇文稿？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('整理台词并继续'), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃文稿'));
    await tester.pumpAndSettle();
    expect(find.text('新建文稿'), findsNothing);
  });

  testWidgets('editor can split and merge a script line', (tester) async {
    final now = DateTime(2026, 1, 1);
    final script = domain.Script(
      id: 'editor-actions',
      title: '编辑动作测试',
      createdAt: now,
      updatedAt: now,
      lines: [
        domain.ScriptLine(
          id: 'line-1',
          order: 0,
          text: '第一句。第二句。',
          expectedDurationMs: 4000,
          pauseAfterMs: 400,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(home: ScriptEditorPage(script: script)),
    );
    await tester.pumpAndSettle();

    // The whole line card is an edit target; the trailing icon remains an
    // explicit affordance but users should not have to hit a tiny control.
    await tester.tap(find.byType(ScriptLineCard));
    await tester.pumpAndSettle();
    expect(find.text('拆分这句'), findsOneWidget);
    expect(find.text('合并下一句'), findsOneWidget);

    await tester.tap(find.text('拆分这句'));
    await tester.pumpAndSettle();
    expect(find.text('第一句。'), findsOneWidget);
    expect(find.text('第二句。'), findsOneWidget);

    await tester.tap(find.byTooltip('编辑台词').first);
    await tester.pumpAndSettle();
    expect(find.text('合并下一句'), findsOneWidget);
    await tester.tap(find.text('合并下一句'));
    await tester.pumpAndSettle();
    expect(find.text('第一句。第二句。'), findsOneWidget);
  });

  testWidgets('editor keeps line identity when reordering', (tester) async {
    final now = DateTime(2026, 1, 1);
    final script = domain.Script(
      id: 'editor-reorder-identity',
      title: '重排身份测试',
      createdAt: now,
      updatedAt: now,
      lines: [
        domain.ScriptLine(
          id: 'line-1',
          order: 0,
          text: '第一句。',
          expectedDurationMs: 3000,
          pauseAfterMs: 400,
        ),
        domain.ScriptLine(
          id: 'line-2',
          order: 1,
          text: '第二句。',
          expectedDurationMs: 3000,
          pauseAfterMs: 400,
        ),
      ],
    );
    final repository = InMemoryScriptRepository([script]);
    await tester.pumpWidget(
      MaterialApp(
        home: ScriptEditorPage(script: script, repository: repository),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.byIcon(Icons.drag_indicator).first,
      const Offset(0, 360),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('进入拍摄准备'));
    await tester.pumpAndSettle();

    final saved = await repository.getById(script.id);
    expect(saved, isNotNull);
    expect(saved!.lines.map((line) => line.text), ['第二句。', '第一句。']);
    expect(saved.lines.map((line) => line.id), ['line-2', 'line-1']);
  });

  testWidgets('editor rename saves after the dialog transition', (
    tester,
  ) async {
    final now = DateTime(2026, 1, 1);
    final script = domain.Script(
      id: 'editor-rename',
      title: '旧标题',
      createdAt: now,
      updatedAt: now,
      lines: [
        domain.ScriptLine(
          id: 'rename-line',
          order: 0,
          text: '一段台词。',
          expectedDurationMs: 3000,
          pauseAfterMs: 400,
        ),
      ],
    );
    final repository = InMemoryScriptRepository([script]);
    await tester.pumpWidget(
      MaterialApp(
        home: ScriptEditorPage(script: script, repository: repository),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('重命名文稿'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新标题');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect((await repository.getById(script.id))?.title, '新标题');
    expect(find.text('新标题'), findsWidgets);
  });

  testWidgets('editor locks the continue action while saving', (tester) async {
    final now = DateTime(2026, 1, 1);
    final script = domain.Script(
      id: 'editor-save-lock',
      title: '保存锁测试',
      createdAt: now,
      updatedAt: now,
      lines: [
        domain.ScriptLine(
          id: 'save-lock-line',
          order: 0,
          text: '准备录制。',
          expectedDurationMs: 3000,
          pauseAfterMs: 400,
        ),
      ],
    );
    final repository = _DelayedScriptRepository([script]);
    await tester.pumpWidget(
      MaterialApp(
        home: ScriptEditorPage(script: script, repository: repository),
      ),
    );
    await tester.pumpAndSettle();

    final continueButton = find.widgetWithText(FilledButton, '进入拍摄准备');
    await tester.tap(continueButton);
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('进入拍摄准备'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // The disabled button remains in place, but a second tap cannot enqueue a
    // second preparation route while the first save is still in flight.
    await tester.tap(find.byType(FilledButton).last);
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.byType(PreparePage), findsNothing);

    await tester.pumpAndSettle();
    expect(find.byType(PreparePage), findsOneWidget);
  });

  testWidgets('editor protects unsaved line changes when backing out', (
    tester,
  ) async {
    final now = DateTime(2026, 1, 1);
    final script = domain.Script(
      id: 'editor-back-save',
      title: '返回保存测试',
      createdAt: now,
      updatedAt: now,
      lines: [
        domain.ScriptLine(
          id: 'back-save-line',
          order: 0,
          text: '原始台词。',
          expectedDurationMs: 3000,
          pauseAfterMs: 400,
        ),
      ],
    );
    final repository = InMemoryScriptRepository([script]);
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final navigator = Navigator.of(tester.element(find.byType(Scaffold)));
    navigator.push<void>(
      MaterialPageRoute(
        builder: (_) =>
            ScriptEditorPage(script: script, repository: repository),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ScriptLineCard));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '修改后的台词。');
    await tester.tap(find.text('保存这句'));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('保存这次改动？'), findsOneWidget);

    await tester.tap(find.text('保存并返回'));
    await tester.pumpAndSettle();
    expect(find.byType(ScriptEditorPage), findsNothing);
    expect((await repository.getById(script.id))!.lines.single.text, '修改后的台词。');
  });

  testWidgets('complete page keeps actions reachable in a short viewport', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1200, 500)),
          child: const CompletePage(
            result: CaptureResult(
              saved: true,
              mediaUri: 'content://media/external/video/media/1',
              durationMs: 18_000,
              resolution: '720×1280',
              storageLocation: 'DCIM/ScriptMirror',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Scrollable), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('完成'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('打开已保存视频'), findsOneWidget);
  });

  test(
    'successful explicit capture clears recovery, interruption keeps it',
    () async {
      final repository = _MemoryRecoveryRepository();
      await clearRecoveryAfterSuccessfulCapture(
        repository,
        const CaptureResult(saved: true),
      );
      expect(repository.clearCount, 1);

      await clearRecoveryAfterSuccessfulCapture(
        repository,
        const CaptureResult(saved: true, interrupted: true),
      );
      await clearRecoveryAfterSuccessfulCapture(
        repository,
        const CaptureResult(saved: false),
      );
      expect(repository.clearCount, 1);
    },
  );

  test('capture config forwards the selected resolution and mirror policy', () {
    const base = CaptureConfig(
      frontCamera: true,
      mirrorPreview: true,
      audioEnabled: true,
    );
    final hd = base.forResolution(domain.CaptureResolution.hd720);

    expect(hd.frontCamera, isTrue);
    expect(hd.mirrorPreview, isTrue);
    expect(hd.audioEnabled, isTrue);
    expect(hd.width, 1280);
    expect(hd.height, 720);
  });

  test('native start cancellation forwards interruption intent', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final channel = const MethodChannel('scriptmirror/capture');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    });

    await PlatformCaptureService().cancelStart(preserveRecording: true);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'cancelStart');
    expect(calls.single.arguments, {'preserveRecording': true});
  });

  testWidgets('recording renders the configured third lookahead line', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: RecordingPage(
          autoAdvance: false,
          settings: domain.AppSettings(lookaheadLines: 3),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('今天我想分享一个很好用的拍摄方式。'), findsOneWidget);
    expect(find.text('它能让你不再担心忘词，同时保持自然的眼神表达。'), findsOneWidget);
    expect(find.text('只需要准备好一篇文稿，就能轻松开始录制。'), findsOneWidget);
    expect(find.text('接下来，让我们看看它是如何工作的。'), findsOneWidget);
  });

  testWidgets(
    'manual recording keeps a truthful status when ASR is unavailable',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.pumpWidget(
        const MaterialApp(home: RecordingPage(autoAdvance: false)),
      );
      // The non-Android test platform uses the explicit unavailable provider;
      // after it reports that state, manual mode must not claim timed fallback.
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('手动翻句'), findsOneWidget);
      expect(find.text('按节奏提词'), findsNothing);

      await tester.tap(find.text('取消'));
      await tester.pump(const Duration(seconds: 3));
      debugDefaultTargetPlatformOverride = null;
    },
  );

  test(
    'preview capture does not emit a ghost recording after disposal',
    () async {
      final service = PreviewCaptureService();
      final phases = <CapturePhaseEvent>[];
      final subscription = service.phase.listen(phases.add);

      await service.prepare(const CaptureConfig());
      final start = service.start(countdown: const Duration(milliseconds: 20));
      await service.dispose();
      await start;
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        phases.map((event) => event.phase),
        isNot(contains(domain.CapturePhase.recording)),
      );
      expect(
        await service.stop(),
        const CaptureResult(saved: false, error: '录制服务已关闭'),
      );
      await subscription.cancel();
    },
  );

  testWidgets('recording cancels countdown when the app leaves foreground', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: RecordingPage(autoAdvance: false)),
    );
    await tester.pump();

    // Inactive keeps test frames enabled while exercising the same
    // background/permission interruption branch as a paused activity.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    expect(find.text('暂时无法开始录制'), findsOneWidget);
    expect(find.text('录制准备被中断，请回到拍摄准备后重试'), findsOneWidget);

    // The original three-second future must not start a recording after the
    // page has already entered its lifecycle error state.
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('录制已中断'), findsNothing);
    expect(find.text('录制准备被中断，请回到拍摄准备后重试'), findsOneWidget);
  });

  testWidgets('recording countdown can be cancelled from its stop control', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: RecordingPage(autoAdvance: false)),
    );
    await tester.pump();

    expect(find.text('取消'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();

    expect(find.text('暂时无法开始录制'), findsOneWidget);
    expect(find.text('已取消录制准备，请返回拍摄准备后重试'), findsOneWidget);

    // The delayed countdown must not open the capture service after cancel.
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('录制已中断'), findsNothing);
    expect(find.text('已取消录制准备，请返回拍摄准备后重试'), findsOneWidget);
  });

  testWidgets('recording locks the surface while finalizing', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(
      const MaterialApp(home: RecordingPage(autoAdvance: false)),
    );
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    expect(find.text('停止'), findsOneWidget);
    await tester.tap(find.text('停止'));
    await tester.pump();

    // PreviewCaptureService deliberately waits while it simulates finalizing;
    // the real Android path uses the same state while muxing H.264 + AAC.
    expect(find.text('正在保存录制结果'), findsOneWidget);
    expect(find.text('录制中设置'), findsNothing);

    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
    expect(find.text('录制未保存'), findsOneWidget);
  });

  testWidgets('system back confirms before leaving recording', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: RecordingPage(autoAdvance: false)),
    );
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('离开拍摄准备？'), findsOneWidget);

    await tester.tap(find.text('继续录制'));
    await tester.pumpAndSettle();
    expect(find.text('取消'), findsOneWidget);
  });

  testWidgets('system back while recording routes through completion', (
    tester,
  ) async {
    // Use the deterministic preview capture service so this widget test can
    // advance through the three-second countdown without a native channel.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(
      const MaterialApp(home: RecordingPage(autoAdvance: false)),
    );
    await tester.pump();
    // The prepare/ASR futures schedule one frame before the three-second
    // countdown starts, so allow a small margin for the hand-off.
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    expect(find.text('停止'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('结束这次录制？'), findsOneWidget);

    await tester.tap(find.text('结束并保存'));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
    expect(find.text('录制未保存'), findsOneWidget);
  });
}
