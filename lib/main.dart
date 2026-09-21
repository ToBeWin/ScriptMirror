import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';

import 'data/sqlite_script_repository.dart';
import 'data/script_repository.dart';
import 'data/session_recovery_repository.dart';
import 'data/settings_repository.dart';
import 'domain/alignment_engine.dart';
import 'domain/asr_provider.dart';
import 'domain/script_models.dart' as domain;
import 'domain/script_parser.dart';
import 'i18n/app_strings.dart';
import 'platform/capture_service.dart';
import 'platform/sherpa_asr_provider.dart';

void main() => runApp(const ScriptMirrorApp());

const _ink = Color(0xFF0B0C0E);
const _panel = Color(0xFF1B1E23);
const _border = Color(0xFF31363F);
const _paper = Color(0xFFF5F6F7);
const _muted = Color(0xFFBEC4CC);
const _cyan = Color(0xFF16DDE0);
const _cyanDim = Color(0xFF0C7377);
const _red = Color(0xFFFF4D4F);
const _amber = Color(0xFFFFB454);
const _appVersion = '0.1.3+2010';
const _tabletContentWidth = 760.0;
final RouteObserver<ModalRoute<void>> _routeObserver =
    RouteObserver<ModalRoute<void>>();

String _formatDurationMs(int? durationMs) {
  if (durationMs == null || durationMs <= 0) return '—';
  final totalSeconds = durationMs ~/ 1000;
  return '${(totalSeconds ~/ 60).toString().padLeft(2, '0')}:${(totalSeconds % 60).toString().padLeft(2, '0')}';
}

String _lineCountLabel(int count) {
  if (AppStrings.currentLanguage == AppLanguage.chinese) {
    return '$count 行';
  }
  return '$count ${count == 1 ? 'line' : 'lines'}';
}

String _characterCountLabel(int count) {
  if (AppStrings.currentLanguage == AppLanguage.chinese) {
    return '$count 字';
  }
  return '$count ${count == 1 ? 'character' : 'characters'}';
}

String _lookaheadLabel(int count) {
  if (AppStrings.currentLanguage == AppLanguage.chinese) {
    return '当前及后续 $count 句';
  }
  return 'Current + next $count ${count == 1 ? 'line' : 'lines'}';
}

String _recognitionLanguageLabel(domain.RecognitionLanguage language) =>
    switch (language) {
      domain.RecognitionLanguage.automatic => tr('自动（按文稿）'),
      domain.RecognitionLanguage.chinese => tr('中文'),
      domain.RecognitionLanguage.english => 'English',
    };

String _recognitionHeadline(domain.RecognitionLanguage language) =>
    switch (language) {
      domain.RecognitionLanguage.english => tr('本地离线识别 · 英文模型已内置'),
      domain.RecognitionLanguage.chinese => tr('本地离线识别 · 中文模型已内置'),
      domain.RecognitionLanguage.automatic => tr('本地离线识别 · 按文稿自动选择'),
    };

/// A successful, explicit stop has no unfinished capture to resume. Clear the
/// durable checkpoint before showing the completion page so a process killed
/// from that page cannot resurrect a stale "unfinished recording" banner.
/// Interrupted or unsaved captures deliberately keep their checkpoint for the
/// recovery flow.
Future<void> clearRecoveryAfterSuccessfulCapture(
  SessionRecoveryRepository? repository,
  CaptureResult result,
) async {
  if (!result.saved || result.interrupted) return;
  try {
    await repository?.clearRecovery();
  } catch (_) {
    // Completion remains truthful even if the best-effort cleanup is
    // unavailable; the Finish action retries the same cleanup.
  }
}

Future<domain.CaptureResolution?> _showResolutionPicker(
  BuildContext context,
  domain.CaptureResolution current,
) => showModalBottomSheet<domain.CaptureResolution>(
  context: context,
  backgroundColor: _panel,
  builder: (context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              tr('视频画质'),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(tr('设备不支持时会自动选择更低画质')),
          ),
          for (final resolution in domain.CaptureResolution.values)
            ListTile(
              title: Text(resolution.label),
              subtitle: Text('${resolution.width} × ${resolution.height}'),
              trailing: Icon(
                current == resolution
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: current == resolution ? _cyan : _muted,
              ),
              onTap: () => Navigator.pop(context, resolution),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  ),
);

Future<bool> _showCapturePermissionRationale(BuildContext context) async =>
    await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: _panel,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('准备开始录制'),
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                tr('镜词只在你点击开始后使用相机和麦克风，视频交给系统相册管理。'),
                style: TextStyle(color: _muted),
              ),
              const SizedBox(height: 18),
              _PermissionReasonRow(
                icon: Icons.videocam_outlined,
                title: tr('相机'),
                detail: tr('用于录制自拍视频。'),
              ),
              const SizedBox(height: 12),
              _PermissionReasonRow(
                icon: Icons.mic_none_outlined,
                title: tr('麦克风'),
                detail: tr('用于保存视频声音与智能跟稿。'),
              ),
              const SizedBox(height: 12),
              _PermissionReasonRow(
                icon: Icons.photo_library_outlined,
                title: tr('系统相册'),
                detail: tr('完成后写入系统媒体库，便于在照片中找到视频。'),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(tr('稍后')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(tr('继续并授权')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ) ??
    false;

class _PermissionReasonRow extends StatelessWidget {
  const _PermissionReasonRow({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: _cyanDim.withValues(alpha: .35),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: _cyan),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(detail, style: const TextStyle(color: _muted)),
          ],
        ),
      ),
    ],
  );
}

class ScriptMirrorApp extends StatelessWidget {
  const ScriptMirrorApp({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppLanguage>(
    valueListenable: AppStrings.language,
    builder: (context, language, child) => MaterialApp(
      title: tr('镜词'),
      locale: Locale(language == AppLanguage.chinese ? 'zh' : 'en'),
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _ink,
        colorScheme: const ColorScheme.dark(
          primary: _cyan,
          surface: _panel,
          onSurface: _paper,
        ),
        useMaterial3: true,
        fontFamily: 'sans-serif',
      ),
      navigatorObservers: [_routeObserver],
      home: const HomePage(),
    ),
  );
}

class ScriptLine {
  ScriptLine(this.text, {this.id, this.seconds = 4, this.pause = 0.4});

  /// Keeps a persisted row attached to its text while the editor reorders,
  /// splits, or merges lines. New editor-only rows leave this null until the
  /// next save allocates an id.
  final String? id;
  String text;
  double seconds;
  double pause;
}

enum _LineEditAction { save, split, merge }

class _LineEditResult {
  const _LineEditResult({
    required this.action,
    required this.text,
    required this.seconds,
    required this.pause,
  });

  final _LineEditAction action;
  final String text;
  final double seconds;
  final double pause;
}

final demoLines = <ScriptLine>[
  ScriptLine('今天我想分享一个很好用的拍摄方式。', seconds: 4),
  ScriptLine('它能让你不再担心忘词，同时保持自然的眼神表达。', seconds: 5),
  ScriptLine('只需要准备好一篇文稿，就能轻松开始录制。', seconds: 4),
  ScriptLine('接下来，让我们看看它是如何工作的。', seconds: 4),
];

final _englishDemoLines = <ScriptLine>[
  ScriptLine(
    'Today I want to share a simple way to feel natural on camera.',
    seconds: 5,
  ),
  ScriptLine(
    'Keep your eyes on the lens without losing your next line.',
    seconds: 4,
  ),
  ScriptLine(
    'Bring in a script, set your pace, and start recording with confidence.',
    seconds: 5,
  ),
  ScriptLine('Let’s see how ScriptMirror keeps the flow moving.', seconds: 4),
];

List<ScriptLine> _demoLinesForLanguage() =>
    AppStrings.currentLanguage == AppLanguage.chinese
    ? demoLines
    : _englishDemoLines;

// Demo scripts are intentionally not written to the user's library, but a
// capture checkpoint still needs a stable identity so an interrupted demo
// take can be restored after the process is killed. Avoid title.hashCode:
// Dart's hash values are not a durable storage contract across runtimes.
const _demoScriptTitles = <String, String>{
  'demo-summer-sunscreen': '夏季防晒分享',
  'demo-course-opening': '课程开场',
  'demo-product-intro': '产品介绍短视频',
};

domain.Script? _demoScriptForId(String id) {
  final title = _demoScriptTitles[id];
  if (title == null) return null;
  final now = DateTime.now();
  return domain.Script(
    id: id,
    title: title,
    createdAt: now,
    updatedAt: now,
    lines: _demoLinesForLanguage()
        .asMap()
        .entries
        .map(
          (entry) => domain.ScriptLine(
            id: '$id-line-${entry.key}',
            order: entry.key,
            text: entry.value.text,
            expectedDurationMs: (entry.value.seconds * 1000).round(),
            pauseAfterMs: (entry.value.pause * 1000).round(),
          ),
        )
        .toList(),
  );
}

domain.Script? _demoScriptForTitle(String title) {
  for (final entry in _demoScriptTitles.entries) {
    if (entry.value == title) return _demoScriptForId(entry.key);
  }
  return null;
}

int get _demoDurationMs => _demoLinesForLanguage().fold<int>(
  0,
  (total, line) =>
      total + (line.seconds * 1000).round() + (line.pause * 1000).round(),
);

String _displayScriptTitle(domain.Script? script) {
  if (script == null) return tr('示例文稿');
  // Demo titles are product copy and can follow the selected UI language.
  // User-authored titles must remain exactly as entered.
  return _demoScriptTitles.containsKey(script.id)
      ? tr(script.title)
      : script.title;
}

class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    required this.child,
    this.title,
    this.onBack,
    this.actions,
  });
  final Widget child;
  final String? title;
  final VoidCallback? onBack;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: title == null
        ? null
        : AppBar(
            backgroundColor: _ink,
            foregroundColor: _paper,
            elevation: 0,
            toolbarHeight: 62,
            titleSpacing: 0,
            leading: onBack == null
                ? null
                : IconButton(
                    tooltip: tr('返回'),
                    icon: const Icon(Icons.arrow_back),
                    onPressed: onBack,
                  ),
            title: Text(
              title!,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            centerTitle: false,
            actions: actions,
          ),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Keep editing and settings surfaces comfortably readable on iPad
          // and Android tablets without shrinking the recording surface. The
          // camera page uses its own full-screen Scaffold and is intentionally
          // not routed through AppScaffold.
          final contentWidth = constraints.maxWidth > _tabletContentWidth
              ? _tabletContentWidth
              : constraints.maxWidth;
          return Center(
            child: SizedBox(
              width: contentWidth,
              height: constraints.maxHeight,
              child: child,
            ),
          );
        },
      ),
    ),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with RouteAware {
  final SqliteScriptRepository _repository = SqliteScriptRepository();
  List<domain.Script> _savedScripts = <domain.Script>[];
  domain.CaptureRecovery? _recovery;
  domain.Script? _recoveryScript;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadSavedScripts();
    _loadRecovery();
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await _repository.loadSettings();
      if (!AppStrings.explicitlySet) AppStrings.setLanguage(settings.language);
    } catch (_) {
      // English remains the safe first-run default when local settings are
      // unavailable on desktop or during a cold database migration.
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      _routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    _routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
    // CompletePage and the editor can pop multiple routes back to HomePage.
    // Refresh both lists so a cleared or deleted recovery checkpoint cannot
    // remain visible only because the old widget state stayed mounted.
    _loadSavedScripts();
    _loadRecovery();
  }

  Future<void> _loadRecovery() async {
    try {
      final recovery = await _repository.loadActiveRecovery();
      if (recovery == null) {
        if (mounted && (_recovery != null || _recoveryScript != null)) {
          setState(() {
            _recovery = null;
            _recoveryScript = null;
          });
        }
        return;
      }
      // User-created scripts are loaded from SQLite. Demo scripts stay
      // ephemeral, so reconstruct a known demo from its stable id instead of
      // deleting a valid checkpoint after a process restart.
      final script =
          await _repository.getById(recovery.scriptId) ??
          _demoScriptForId(recovery.scriptId);
      if (script == null) {
        await _repository.clearRecovery();
        if (mounted) {
          setState(() {
            _recovery = null;
            _recoveryScript = null;
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _recovery = recovery;
          _recoveryScript = script;
        });
      }
    } catch (_) {
      // Recovery is best effort; it must never block the normal capture path.
    }
  }

  Future<void> _loadSavedScripts() async {
    try {
      final scripts = await _repository.list();
      if (mounted) setState(() => _savedScripts = scripts);
    } catch (_) {
      // The visual demo remains available if a desktop/test platform has no
      // SQLite plugin. Android uses the repository for durable CRUD.
    }
  }

  Future<void> _openEditor({domain.Script? script}) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ScriptEditorPage(
          script: script,
          repository: _repository,
          settingsRepository: _repository,
          recoveryRepository: _repository,
        ),
      ),
    );
    _loadSavedScripts();
  }

  Future<void> _createScript() async {
    final values = await Navigator.of(context).push<Map<String, String>>(
      MaterialPageRoute(builder: (_) => const ScriptEntryPage()),
    );
    if (!mounted || values == null) return;
    final lines = const ScriptParser().split(values['body'] ?? '');
    if (lines.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('请先粘贴一段文稿'))));
      return;
    }
    final now = DateTime.now();
    final script = domain.Script(
      id: 'script-${now.microsecondsSinceEpoch}',
      title: (values['title'] ?? '').trim().isEmpty
          ? tr('未命名文稿')
          : values['title']!.trim(),
      createdAt: now,
      updatedAt: now,
      lines: lines,
    );
    try {
      await _repository.save(script);
      if (mounted) await _openEditor(script: script);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('文稿暂时无法保存，请稍后重试'))));
      }
    }
  }

  Future<void> _openLibrary() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ScriptLibraryPage(repository: _repository),
      ),
    );
    _loadSavedScripts();
  }

  Future<void> _openDemoScript(String title) async {
    final script = _demoScriptForTitle(title);
    if (script == null) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PreparePage(
          script: script,
          settingsRepository: _repository,
          recoveryRepository: _repository,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Image.asset(
                      'assets/branding/scriptmirror-logo-v2.png',
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr('镜词'),
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  tooltip: tr('设置'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SettingsPage(repository: _repository),
                    ),
                  ),
                  icon: const Icon(Icons.tune, size: 23),
                ),
              ],
            ),
            Expanded(
              child: ListView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.only(top: 22),
                children: [
                  Text(
                    tr('SCRIPT MIRROR  /  CREATOR TOOL'),
                    style: TextStyle(
                      color: _cyan,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.3,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    tr('看着镜头，\n也不用忘记下一句。'),
                    style: TextStyle(
                      fontSize: 30,
                      height: 1.12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    tr('把注意力留给镜头，把节奏交给镜词。'),
                    style: TextStyle(color: _muted, fontSize: 14, height: 1.35),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PreparePage(
                            // The primary CTA starts with a real, stable demo
                            // script so an interrupted first take can also be
                            // recovered after process death.
                            script: _demoScriptForId('demo-summer-sunscreen'),
                            settingsRepository: _repository,
                            recoveryRepository: _repository,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.videocam_outlined, size: 21),
                      label: Text(
                        tr('开始拍摄'),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: _cyan,
                        foregroundColor: _ink,
                        minimumSize: const Size.fromHeight(60),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _createScript,
                          icon: const Icon(Icons.add, size: 17),
                          label: Text(tr('新建文稿')),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _paper,
                            side: const BorderSide(color: _border),
                            minimumSize: const Size.fromHeight(44),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _openLibrary,
                          icon: const Icon(
                            Icons.library_books_outlined,
                            size: 17,
                          ),
                          label: Text(tr('全部文稿')),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _muted,
                            side: const BorderSide(color: _border),
                            minimumSize: const Size.fromHeight(44),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_recovery != null && _recoveryScript != null) ...[
                    const SizedBox(height: 18),
                    _RecoveryBanner(
                      script: _recoveryScript!,
                      lineIndex: _recovery!.currentLineIndex,
                      onResume: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PreparePage(
                            script: _recoveryScript,
                            initialLineIndex: _recovery!.currentLineIndex,
                            settingsRepository: _repository,
                            recoveryRepository: _repository,
                          ),
                        ),
                      ),
                      onDismiss: () async {
                        try {
                          await _repository.clearRecovery();
                          if (mounted) {
                            setState(() {
                              _recovery = null;
                              _recoveryScript = null;
                            });
                          }
                        } catch (_) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(tr('暂时无法丢弃这条恢复记录，请稍后重试'))),
                          );
                        }
                      },
                    ),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          tr('最近文稿'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _openLibrary,
                        style: TextButton.styleFrom(
                          foregroundColor: _cyan,
                          padding: EdgeInsets.zero,
                        ),
                        child: Text(tr('全部  ›')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ...(_savedScripts.isEmpty
                      ? [
                          ScriptCard(
                            badge: '01',
                            title: tr('夏季防晒分享'),
                            lines: _lineCountLabel(4),
                            duration: _formatDurationMs(_demoDurationMs),
                            updated: tr('示例文稿'),
                            onTap: () => _openDemoScript('夏季防晒分享'),
                          ),
                          ScriptCard(
                            badge: '02',
                            title: tr('课程开场'),
                            lines: _lineCountLabel(4),
                            duration: _formatDurationMs(_demoDurationMs),
                            updated: tr('示例文稿'),
                            onTap: () => _openDemoScript('课程开场'),
                          ),
                          ScriptCard(
                            badge: '03',
                            title: tr('产品介绍短视频'),
                            lines: _lineCountLabel(4),
                            duration: _formatDurationMs(_demoDurationMs),
                            updated: tr('示例文稿'),
                            onTap: () => _openDemoScript('产品介绍短视频'),
                          ),
                        ]
                      : _savedScripts
                            .take(3)
                            .map(
                              (script) => ScriptCard(
                                badge: '${_savedScripts.indexOf(script) + 1}'
                                    .padLeft(2, '0'),
                                title: script.title,
                                lines: _lineCountLabel(script.lines.length),
                                duration: _formatDurationMs(
                                  script.estimatedDurationMs,
                                ),
                                updated: tr('已保存到本机'),
                                onTap: () => _openEditor(script: script),
                              ),
                            )),
                  const SizedBox(height: 4),
                  Text(
                    tr('离线优先  ·  文稿与视频只保存在本机'),
                    style: TextStyle(color: _muted, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class ScriptCard extends StatelessWidget {
  const ScriptCard({
    super.key,
    this.badge = '01',
    required this.title,
    required this.lines,
    required this.duration,
    required this.updated,
    this.onTap,
  });
  final String badge;
  final String title, lines, duration, updated;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    label: '$title, $lines, $duration, $updated',
    child: Card(
      color: const Color(0xFF14171B),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: _border),
      ),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        leading: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: badge == '01' ? _cyan : _surfaceTint(badge),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Text(
            badge,
            style: TextStyle(
              color: badge == '01' ? _ink : _paper,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        title: Text(title, style: const TextStyle(fontSize: 18)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '$lines  ·  $duration  ·  $updated',
            style: const TextStyle(color: _muted),
          ),
        ),
        trailing: onTap == null
            ? null
            : const Icon(Icons.chevron_right, color: _muted),
      ),
    ),
  );
}

Color _surfaceTint(String badge) => switch (badge) {
  '02' => _amber.withValues(alpha: .9),
  '03' => _cyanDim,
  _ => _border,
};

class ScriptLibraryPage extends StatefulWidget {
  const ScriptLibraryPage({super.key, required this.repository});

  final SqliteScriptRepository repository;

  @override
  State<ScriptLibraryPage> createState() => _ScriptLibraryPageState();
}

class _ScriptLibraryPageState extends State<ScriptLibraryPage> {
  List<domain.Script> scripts = <domain.Script>[];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final loaded = await widget.repository.list();
      if (mounted) {
        setState(() {
          scripts = loaded;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _openScript(domain.Script script) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ScriptEditorPage(
          script: script,
          repository: widget.repository,
          settingsRepository: widget.repository,
          recoveryRepository: widget.repository,
        ),
      ),
    );
    _load();
  }

  Future<void> _createScript() async {
    final values = await Navigator.of(context).push<Map<String, String>>(
      MaterialPageRoute(builder: (_) => const ScriptEntryPage()),
    );
    if (!mounted || values == null) return;
    final lines = const ScriptParser().split(values['body'] ?? '');
    if (lines.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('请先粘贴一段文稿'))));
      return;
    }
    final now = DateTime.now();
    final script = domain.Script(
      id: 'script-${now.microsecondsSinceEpoch}',
      title: (values['title'] ?? '').trim().isEmpty
          ? tr('未命名文稿')
          : values['title']!.trim(),
      createdAt: now,
      updatedAt: now,
      lines: lines,
    );
    try {
      await widget.repository.save(script);
      if (mounted) await _openScript(script);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('文稿暂时无法保存，请稍后重试'))));
      }
    }
  }

  @override
  Widget build(BuildContext context) => AppScaffold(
    title: tr('全部文稿'),
    onBack: () => Navigator.pop(context),
    child: loading
        ? const Center(child: CircularProgressIndicator(color: _cyan))
        : scripts.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.description_outlined,
                    size: 54,
                    color: _muted,
                  ),
                  const SizedBox(height: 16),
                  Text(tr('还没有保存的文稿')),
                  const SizedBox(height: 8),
                  Text(
                    tr('回到首页粘贴一篇文稿即可开始。'),
                    style: TextStyle(color: _muted),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _createScript,
                    icon: const Icon(Icons.add),
                    label: Text(tr('新建文稿')),
                    style: FilledButton.styleFrom(
                      backgroundColor: _cyan,
                      foregroundColor: _ink,
                    ),
                  ),
                ],
              ),
            ),
          )
        : ListView.builder(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            itemCount: scripts.length,
            itemBuilder: (context, index) {
              final script = scripts[index];
              return ScriptCard(
                title: script.title,
                lines: _lineCountLabel(script.lines.length),
                duration: _formatDurationMs(script.estimatedDurationMs),
                updated: tr('已保存到本机'),
                onTap: () => _openScript(script),
              );
            },
          ),
  );
}

class _RecoveryBanner extends StatelessWidget {
  const _RecoveryBanner({
    required this.script,
    required this.lineIndex,
    required this.onResume,
    required this.onDismiss,
  });

  final domain.Script script;
  final int lineIndex;
  final VoidCallback onResume;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final lineNumber = script.lines.isEmpty
        ? 1
        : (lineIndex + 1).clamp(1, script.lines.length);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 12),
      decoration: BoxDecoration(
        color: _amber.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _amber.withValues(alpha: .55)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.history, color: _amber),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('发现未完成录制'),
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_displayScriptTitle(script)} · ${AppStrings.replace('从第 {line} 行继续', {'line': lineNumber})}',
                  style: const TextStyle(color: _muted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton(
                      onPressed: onResume,
                      style: TextButton.styleFrom(
                        foregroundColor: _amber,
                        padding: EdgeInsets.zero,
                      ),
                      child: Text(tr('继续准备')),
                    ),
                    const SizedBox(width: 10),
                    TextButton(
                      onPressed: onDismiss,
                      style: TextButton.styleFrom(
                        foregroundColor: _muted,
                        padding: EdgeInsets.zero,
                      ),
                      child: Text(tr('丢弃记录')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ScriptEntryPage extends StatefulWidget {
  const ScriptEntryPage({super.key});

  @override
  State<ScriptEntryPage> createState() => _ScriptEntryPageState();
}

class _ScriptEntryPageState extends State<ScriptEntryPage> {
  final titleController = TextEditingController(text: tr('未命名文稿'));
  final bodyController = TextEditingController();
  bool _backPromptOpen = false;

  @override
  void initState() {
    super.initState();
    titleController.addListener(_onTitleChanged);
    bodyController.addListener(_onBodyChanged);
  }

  @override
  void dispose() {
    titleController.removeListener(_onTitleChanged);
    bodyController.removeListener(_onBodyChanged);
    titleController.dispose();
    bodyController.dispose();
    super.dispose();
  }

  void _onTitleChanged() => setState(() {});

  void _onBodyChanged() => setState(() {});

  Future<void> _importScript() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Text documents',
            extensions: ['txt', 'md', 'markdown'],
          ),
        ],
      );
      if (!mounted || file == null) return;
      final contents = await file.readAsString();
      if (!mounted) return;
      if (contents.trim().isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('这个文件没有可用的文字内容'))));
        return;
      }
      bodyController.text = contents;
      final currentTitle = titleController.text.trim();
      if (currentTitle.isEmpty || currentTitle == tr('未命名文稿')) {
        final importedTitle = file.name.replaceFirst(
          RegExp(r'\.(?:txt|md|markdown)$', caseSensitive: false),
          '',
        );
        if (importedTitle.trim().isNotEmpty) {
          titleController.text = importedTitle.trim();
        }
      }
      FocusScope.of(context).unfocus();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('文稿已导入'))));
    } on Exception catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('文件读取失败，请重试'))));
    }
  }

  bool get _hasUnsavedDraft {
    final title = titleController.text.trim();
    return bodyController.text.trim().isNotEmpty ||
        (title.isNotEmpty && title != tr('未命名文稿'));
  }

  int get _lineCount {
    final body = bodyController.text.trim();
    if (body.isEmpty) return 0;
    return const ScriptParser().split(body).length;
  }

  void _submit() {
    if (bodyController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('先输入一段台词，镜词才能帮你整理节奏'))));
      return;
    }
    Navigator.pop(context, <String, String>{
      'title': titleController.text,
      'body': bodyController.text,
    });
  }

  Future<void> _handleBack() async {
    if (!mounted || _backPromptOpen) return;
    if (!_hasUnsavedDraft) {
      Navigator.pop(context);
      return;
    }

    _backPromptOpen = true;
    try {
      final shouldDiscard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: _panel,
          title: Text(tr('放弃这篇文稿？')),
          content: Text(tr('已经输入的标题和台词还没有保存，离开后需要重新录入。')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('继续编辑')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('放弃文稿')),
            ),
          ],
        ),
      );
      if (mounted && shouldDiscard == true) Navigator.pop(context);
    } finally {
      _backPromptOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !_hasUnsavedDraft,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_handleBack());
    },
    child: AppScaffold(
      title: tr('新建文稿'),
      onBack: () => unawaited(_handleBack()),
      actions: [
        IconButton(
          tooltip: tr('导入文稿'),
          onPressed: _importScript,
          icon: const Icon(Icons.file_open_outlined),
        ),
      ],
      child: Column(
        children: [
          Expanded(
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1E2A2D), _panel],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _cyanDim.withValues(alpha: .7)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.auto_awesome, color: _cyan, size: 22),
                      SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tr('先把想说的话放进来'),
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              tr('镜词会按中英文标点自动拆成可提词的台词行。'),
                              style: TextStyle(color: _muted, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      _EntryBadge(),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                _EntrySectionLabel(label: tr('文稿信息')),
                const SizedBox(height: 10),
                TextField(
                  controller: titleController,
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: InputDecoration(
                    labelText: tr('文稿标题'),
                    hintText: tr('例如：夏季防晒分享'),
                    prefixIcon: const Icon(Icons.title_outlined, color: _muted),
                    filled: true,
                    fillColor: _panel,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                      borderSide: const BorderSide(color: _border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                      borderSide: const BorderSide(color: _border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                      borderSide: const BorderSide(color: _cyan, width: 1.4),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(child: _EntrySectionLabel(label: tr('台词内容'))),
                    TextButton.icon(
                      onPressed: _importScript,
                      style: TextButton.styleFrom(
                        foregroundColor: _cyan,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                      icon: const Icon(Icons.file_open_outlined, size: 17),
                      label: Text(tr('导入文稿')),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    bodyController.text.isEmpty
                        ? tr('等待输入')
                        : '${_characterCountLabel(bodyController.text.trim().length)}  ·  ${_lineCountLabel(_lineCount)}',
                    style: const TextStyle(color: _cyan, fontSize: 12),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: _panel,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: bodyController.text.isEmpty ? _border : _cyanDim,
                      width: bodyController.text.isEmpty ? 1 : 1.3,
                    ),
                  ),
                  child: TextField(
                    controller: bodyController,
                    autofocus: true,
                    minLines: 10,
                    maxLines: 15,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(fontSize: 16, height: 1.5),
                    decoration: InputDecoration(
                      hintText: tr('输入或粘贴整篇台词……\n\n每个句号、问号或换行都会成为自然的提词停顿。'),
                      hintStyle: TextStyle(color: _muted, height: 1.5),
                      contentPadding: EdgeInsets.fromLTRB(16, 16, 16, 18),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.offline_bolt_outlined, color: _cyan, size: 16),
                    SizedBox(width: 6),
                    Text(
                      tr('离线处理 · 文稿不会上传'),
                      style: TextStyle(color: _muted, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                label: Text(
                  tr('整理台词并继续'),
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: _cyan,
                  foregroundColor: _ink,
                  padding: const EdgeInsets.symmetric(vertical: 17),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(17),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _EntryBadge extends StatelessWidget {
  const _EntryBadge();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: _cyanDim.withValues(alpha: .35),
      borderRadius: BorderRadius.circular(9),
    ),
    child: Text(
      tr('本机'),
      style: TextStyle(color: _cyan, fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );
}

class _EntrySectionLabel extends StatelessWidget {
  const _EntrySectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
  );
}

class ScriptEditorPage extends StatefulWidget {
  const ScriptEditorPage({
    super.key,
    this.script,
    this.repository,
    this.settingsRepository,
    this.recoveryRepository,
  });
  final domain.Script? script;
  final ScriptRepository? repository;
  final SettingsRepository? settingsRepository;
  final SessionRecoveryRepository? recoveryRepository;

  @override
  State<ScriptEditorPage> createState() => _ScriptEditorPageState();
}

class _ScriptEditorPageState extends State<ScriptEditorPage> {
  late String title = widget.script?.title ?? tr('夏季防晒分享');
  bool _savingAndContinue = false;
  bool _dirty = false;
  bool _backPromptOpen = false;
  late final lines =
      (widget.script?.lines ?? const <domain.ScriptLine>[])
          .map(
            (line) => ScriptLine(
              line.text,
              id: line.id,
              seconds: line.expectedDurationMs / 1000,
              pause: line.pauseAfterMs / 1000,
            ),
          )
          .toList()
        ..addAll(
          widget.script == null
              ? _demoLinesForLanguage()
                    .map((line) => ScriptLine(line.text, seconds: line.seconds))
                    .toList()
              : <ScriptLine>[],
        );

  String get _estimatedDuration {
    final seconds = lines.fold<double>(
      0,
      (total, line) => total + line.seconds + line.pause,
    );
    return _formatDurationMs((seconds * 1000).floor());
  }

  domain.Script _buildPersistedScript(DateTime now) => domain.Script(
    id: widget.script?.id ?? 'script-${now.microsecondsSinceEpoch}',
    title: title.trim().isEmpty ? tr('未命名文稿') : title.trim(),
    createdAt: widget.script?.createdAt ?? now,
    updatedAt: now,
    lines: List<domain.ScriptLine>.generate(
      lines.length,
      (index) => domain.ScriptLine(
        id: lines[index].id ?? 'line-${now.microsecondsSinceEpoch}-$index',
        order: index,
        text: lines[index].text,
        expectedDurationMs: (lines[index].seconds * 1000).round(),
        pauseAfterMs: (lines[index].pause * 1000).round(),
      ),
    ),
  );

  Future<void> _saveAndContinue() async {
    if (_savingAndContinue) return;
    setState(() => _savingAndContinue = true);
    try {
      final now = DateTime.now();
      final script = _buildPersistedScript(now);
      await widget.repository?.save(script);
      if (mounted) setState(() => _dirty = false);
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => PreparePage(
            script: script,
            settingsRepository: widget.settingsRepository,
            recoveryRepository: widget.recoveryRepository,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('文稿暂时无法保存，请稍后重试'))));
      }
    } finally {
      if (mounted) setState(() => _savingAndContinue = false);
    }
  }

  bool get _hasUnsavedChanges => _dirty && widget.repository != null;

  Future<void> _handleBack() async {
    if (!mounted || _savingAndContinue || _backPromptOpen) return;
    if (!_hasUnsavedChanges) {
      Navigator.pop(context);
      return;
    }

    _backPromptOpen = true;
    try {
      final shouldSave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: _panel,
          title: Text(tr('保存这次改动？')),
          content: Text(tr('你修改了台词内容或节奏，保存后下次拍摄会使用最新版本。')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('继续编辑')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('放弃改动')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('保存并返回')),
            ),
          ],
        ),
      );
      if (!mounted || shouldSave == null) return;
      if (!shouldSave) {
        Navigator.pop(context);
        return;
      }

      setState(() => _savingAndContinue = true);
      try {
        await widget.repository!.save(_buildPersistedScript(DateTime.now()));
        if (mounted) Navigator.pop(context);
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('文稿暂时无法保存，请稍后重试'))));
      } finally {
        if (mounted) setState(() => _savingAndContinue = false);
      }
    } finally {
      _backPromptOpen = false;
    }
  }

  void _appendLine() {
    setState(() {
      lines.add(ScriptLine('新的一句台词，从这里开始写。', seconds: 4, pause: .4));
      _dirty = true;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr('已添加台词，可点击右侧按钮编辑内容和时长'))));
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !_hasUnsavedChanges && !_savingAndContinue,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_handleBack());
    },
    child: AppScaffold(
      title: title,
      onBack: () => unawaited(_handleBack()),
      actions: [
        IconButton(
          onPressed: _renameScript,
          tooltip: tr('重命名文稿'),
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          onPressed: widget.script == null ? null : _deleteScript,
          tooltip: tr('删除文稿'),
          icon: const Icon(Icons.delete_outline),
        ),
      ],
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: ScriptOverviewCard(
              title: title,
              lineCount: lines.length,
              duration: _estimatedDuration,
              badge: tr('本机保存'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 2),
            child: Row(
              children: [
                Text(
                  tr('台词内容'),
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _appendLine,
                  style: TextButton.styleFrom(
                    foregroundColor: _cyan,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(tr('添加台词')),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                tr('长按拖动排序 · 点击编辑时长与停顿'),
                style: TextStyle(color: _muted, fontSize: 12),
              ),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
              itemCount: lines.length,
              onReorderItem: (oldIndex, newIndex) => setState(() {
                final item = lines.removeAt(oldIndex);
                lines.insert(newIndex, item);
                _dirty = true;
              }),
              itemBuilder: (context, index) => ScriptLineCard(
                key: ValueKey(lines[index]),
                index: index,
                line: lines[index],
                onEdit: () => _editLine(index),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _savingAndContinue ? null : _saveAndContinue,
                style: FilledButton.styleFrom(
                  backgroundColor: _cyan,
                  foregroundColor: _ink,
                  padding: const EdgeInsets.symmetric(vertical: 17),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: _savingAndContinue
                    ? const SizedBox(
                        height: 24,
                        width: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: _ink,
                        ),
                      )
                    : Text(
                        tr('进入拍摄准备'),
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _editLine(int index) async {
    final controller = TextEditingController(text: lines[index].text);
    final durationController = TextEditingController(
      text: lines[index].seconds.toStringAsFixed(1),
    );
    final pauseController = TextEditingController(
      text: lines[index].pause.toStringAsFixed(1),
    );
    try {
      final result = await showModalBottomSheet<_LineEditResult>(
        context: context,
        backgroundColor: _panel,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        clipBehavior: Clip.antiAlias,
        builder: (context) {
          void submit(_LineEditAction action) {
            final seconds = double.tryParse(durationController.text);
            final pause = double.tryParse(pauseController.text);
            if (controller.text.trim().isEmpty ||
                seconds == null ||
                pause == null ||
                seconds <= 0 ||
                pause < 0) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(tr('请填写有效的台词、时长和停顿'))));
              return;
            }
            Navigator.pop(
              context,
              _LineEditResult(
                action: action,
                text: controller.text.trim(),
                seconds: seconds,
                pause: pause,
              ),
            );
          }

          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              24,
              20,
              24,
              24 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: _border,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _cyan,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${index + 1}'.padLeft(2, '0'),
                        style: const TextStyle(
                          color: _ink,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr('编辑这句台词'),
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            tr('调整内容与镜头前的节奏'),
                            style: TextStyle(color: _muted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.tune_rounded, color: _cyan),
                  ],
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLines: 4,
                  style: const TextStyle(color: _paper),
                  decoration: InputDecoration(
                    labelText: tr('台词内容'),
                    filled: true,
                    fillColor: _ink.withValues(alpha: .45),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: _border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: _border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: _cyan, width: 1.3),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  tr('节奏设置'),
                  style: TextStyle(color: _muted, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: durationController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: tr('预计时长（秒）'),
                          suffixText: 's',
                          filled: true,
                          fillColor: _ink.withValues(alpha: .45),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: _border),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: pauseController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: tr('句后停顿（秒）'),
                          suffixText: 's',
                          filled: true,
                          fillColor: _ink.withValues(alpha: .45),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: _border),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => submit(_LineEditAction.save),
                    child: Text(tr('保存这句')),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => submit(_LineEditAction.split),
                        icon: const Icon(Icons.call_split_rounded, size: 18),
                        label: Text(tr('拆分这句')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: index + 1 < lines.length
                            ? () => submit(_LineEditAction.merge)
                            : null,
                        icon: const Icon(Icons.merge_type_rounded, size: 18),
                        label: Text(tr('合并下一句')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
      if (!mounted || result == null) return;
      switch (result.action) {
        case _LineEditAction.save:
          setState(() {
            lines[index].text = result.text;
            lines[index].seconds = result.seconds;
            lines[index].pause = result.pause;
            _dirty = true;
          });
          break;
        case _LineEditAction.split:
          _splitLine(index, result);
          break;
        case _LineEditAction.merge:
          _mergeLine(index, result);
          break;
      }
    } finally {
      // Navigator.pop completes the modal future before the bottom-sheet
      // reverse animation has removed its TextFields from the tree. Defer
      // disposal until that short transition is over, otherwise Flutter can
      // rebuild a TextField with an already-disposed controller.
      await Future<void>.delayed(const Duration(milliseconds: 260));
      controller.dispose();
      durationController.dispose();
      pauseController.dispose();
    }
  }

  void _splitLine(int index, _LineEditResult draft) {
    final chunks = _splitTextForEditor(draft.text);
    if (chunks.length < 2) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('这句暂时找不到合适的拆分位置，请先加入标点或空格'))));
      return;
    }
    final totalUnits = chunks.fold<int>(
      0,
      (total, chunk) => total + chunk.runes.length,
    );
    final splitLines = <ScriptLine>[];
    var allocatedSeconds = 0.0;
    for (var i = 0; i < chunks.length; i++) {
      final seconds = i == chunks.length - 1
          ? (draft.seconds - allocatedSeconds).clamp(.1, 120).toDouble()
          : (draft.seconds * chunks[i].runes.length / totalUnits)
                .clamp(.1, 120)
                .toDouble();
      allocatedSeconds += seconds;
      splitLines.add(
        ScriptLine(
          chunks[i],
          id: i == 0 ? lines[index].id : null,
          seconds: seconds,
          pause: i == chunks.length - 1
              ? draft.pause
              : (draft.pause * .35).clamp(0, 2).toDouble(),
        ),
      );
    }
    setState(() {
      lines[index] = splitLines.first;
      lines.insertAll(index + 1, splitLines.skip(1));
      _dirty = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${tr('已拆分为')} ${splitLines.length} ${tr('句台词')}'),
      ),
    );
  }

  void _mergeLine(int index, _LineEditResult draft) {
    if (index >= lines.length - 1) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('最后一句没有可合并的下一句'))));
      return;
    }
    final next = lines[index + 1];
    setState(() {
      lines[index] = ScriptLine(
        _joinEditorLines(draft.text, next.text),
        id: lines[index].id,
        seconds: draft.seconds + next.seconds,
        pause: next.pause,
      );
      lines.removeAt(index + 1);
      _dirty = true;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr('已与下一句合并'))));
  }

  List<String> _splitTextForEditor(String value) {
    final text = value.trim();
    if (text.isEmpty) return const <String>[];
    final sentenceChunks = const ScriptParser()
        .split(text)
        .map((line) => line.text.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (sentenceChunks.length > 1) return sentenceChunks;

    final midpoint = text.length ~/ 2;
    var boundary = -1;
    var distance = text.length;
    for (final match in RegExp(r'[，,、:：；;\s]+').allMatches(text)) {
      if (match.end <= 0 || match.end >= text.length) continue;
      final nextDistance = (match.end - midpoint).abs();
      if (nextDistance < distance) {
        boundary = match.end;
        distance = nextDistance;
      }
    }
    if (boundary < 0) {
      boundary = midpoint;
      // Avoid cutting between the two UTF-16 code units of an emoji.
      while (boundary > 0 &&
          boundary < text.length &&
          _isLowSurrogate(text.codeUnitAt(boundary))) {
        boundary--;
      }
    }
    if (boundary <= 0 || boundary >= text.length) {
      return <String>[text];
    }
    final first = text.substring(0, boundary).trim();
    final second = text.substring(boundary).trim();
    if (first.isEmpty || second.isEmpty) return <String>[text];
    return <String>[first, second];
  }

  String _joinEditorLines(String first, String second) {
    final left = first.trimRight();
    final right = second.trimLeft();
    if (left.isEmpty) return right;
    if (right.isEmpty) return left;
    final needsSpace =
        RegExp(r'[A-Za-z0-9]$').hasMatch(left) ||
        RegExp(r'^[A-Za-z0-9]').hasMatch(right);
    return needsSpace ? '$left $right' : '$left$right';
  }

  bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  Future<void> _deleteScript() async {
    final script = widget.script;
    final repository = widget.repository;
    if (script == null || repository == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _panel,
        title: Text(tr('删除这篇文稿？')),
        content: Text(
          AppStrings.replace('“{title}”以及它的台词行会从本机移除。', {
            'title': script.title,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _red),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('删除')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await repository.delete(script.id);
      // A deleted script cannot be resumed. Clear only a checkpoint pointing
      // at this script; an unrelated in-progress take must remain intact.
      try {
        final recovery = await widget.recoveryRepository?.loadActiveRecovery();
        if (recovery?.scriptId == script.id) {
          await widget.recoveryRepository?.clearRecovery();
        }
      } catch (_) {
        // Script deletion itself succeeded; a later Home refresh will remove
        // any orphaned checkpoint whose script no longer exists.
      }
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('文稿暂时无法删除，请稍后重试'))));
      }
    }
  }

  Future<void> _renameScript() async {
    final controller = TextEditingController(text: title);
    String? nextTitle;
    try {
      nextTitle = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: _panel,
          title: Text(tr('重命名文稿')),
          content: TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(labelText: tr('文稿标题')),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text(tr('保存')),
            ),
          ],
        ),
      );
    } finally {
      // The dialog future completes when Navigator.pop is called, before the
      // reverse animation has fully removed its TextField. Keep the controller
      // alive through that short transition, just like the line editor does.
      await Future<void>.delayed(const Duration(milliseconds: 260));
      controller.dispose();
    }
    final titleDraft = nextTitle;
    if (!mounted || titleDraft == null || titleDraft.trim().isEmpty) return;
    final previousTitle = title;
    final previousDirty = _dirty;
    setState(() {
      title = titleDraft.trim();
      _dirty = true;
    });
    final repository = widget.repository;
    if (repository == null || widget.script == null) return;
    try {
      await repository.save(_buildPersistedScript(DateTime.now()));
      if (mounted) setState(() => _dirty = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        title = previousTitle;
        _dirty = previousDirty;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('标题暂时无法保存，请稍后重试'))));
    }
  }
}

class ScriptOverviewCard extends StatelessWidget {
  const ScriptOverviewCard({
    super.key,
    required this.title,
    required this.lineCount,
    required this.duration,
    this.badge = '本机文稿',
  });

  final String title;
  final int lineCount;
  final String duration;
  final String badge;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xFF1E2A2D), _panel],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _cyanDim.withValues(alpha: .7)),
    ),
    child: Column(
      children: [
        Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: _cyan,
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(Icons.notes_rounded, color: _ink, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: _cyanDim.withValues(alpha: .35),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                badge,
                style: const TextStyle(
                  color: _cyan,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _OverviewMetric(label: tr('台词'), value: _lineCountLabel(lineCount)),
            const _OverviewDivider(),
            _OverviewMetric(label: tr('预计时长'), value: duration),
            const _OverviewDivider(),
            _OverviewMetric(label: tr('模式'), value: tr('离线优先')),
          ],
        ),
      ],
    ),
  );
}

class _OverviewMetric extends StatelessWidget {
  const _OverviewMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: _muted, fontSize: 11)),
        const SizedBox(height: 3),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

class _OverviewDivider extends StatelessWidget {
  const _OverviewDivider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 28,
    margin: const EdgeInsets.symmetric(horizontal: 10),
    color: _border,
  );
}

class ScriptLineCard extends StatelessWidget {
  const ScriptLineCard({
    super.key,
    required this.index,
    required this.line,
    required this.onEdit,
  });
  final int index;
  final ScriptLine line;
  final VoidCallback onEdit;
  @override
  Widget build(BuildContext context) => Card(
    color: index == 0 ? const Color(0xFF152A2C) : _panel,
    margin: const EdgeInsets.only(bottom: 12),
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(
        color: index == 0 ? _cyanDim : _border,
        width: index == 0 ? 1.3 : 1,
      ),
    ),
    child: InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 10, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.only(top: 5, right: 7),
                child: Icon(Icons.drag_indicator, color: _muted, size: 20),
              ),
            ),
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: index == 0 ? _cyan : _border,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${index + 1}'.padLeft(2, '0'),
                style: TextStyle(
                  color: index == 0 ? _ink : _paper,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    line.text,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      height: 1.38,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _LineMetaChip(
                        icon: Icons.timer_outlined,
                        label: '${line.seconds.toStringAsFixed(1)} ${tr('秒')}',
                        highlighted: index == 0,
                      ),
                      _LineMetaChip(
                        icon: Icons.pause_circle_outline,
                        label:
                            '${tr('停')} ${line.pause.toStringAsFixed(1)} ${tr('秒')}',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: tr('编辑台词'),
              onPressed: onEdit,
              icon: Icon(
                Icons.tune_rounded,
                color: index == 0 ? _cyan : _muted,
                size: 20,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _LineMetaChip extends StatelessWidget {
  const _LineMetaChip({
    required this.icon,
    required this.label,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: highlighted ? _cyanDim.withValues(alpha: .38) : _border,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: highlighted ? _cyan : _muted),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: highlighted ? _cyan : _muted,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class PreparePage extends StatefulWidget {
  const PreparePage({
    super.key,
    this.script,
    this.settingsRepository,
    this.recoveryRepository,
    this.initialLineIndex = 0,
  });
  final domain.Script? script;
  final SettingsRepository? settingsRepository;
  final SessionRecoveryRepository? recoveryRepository;
  final int initialLineIndex;
  @override
  State<PreparePage> createState() => _PreparePageState();
}

class _PreparePageState extends State<PreparePage> {
  bool front = true;
  bool autoAdvance = true;
  bool _startingRecording = false;
  String promptSpeed = '中速';
  domain.AppSettings settings = const domain.AppSettings();

  List<String> get _previewLines {
    final scriptLines = widget.script?.lines
        .map((line) => line.text.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (scriptLines == null || scriptLines.isEmpty) {
      return _demoLinesForLanguage().map((line) => line.text).toList();
    }
    return scriptLines;
  }

  int get _previewIndex =>
      widget.initialLineIndex.clamp(0, _previewLines.length - 1).toInt();

  domain.RecognitionLanguage get _recognitionLanguage {
    final requested = settings.recognitionLanguage;
    if (requested != domain.RecognitionLanguage.automatic) return requested;
    return domain.detectRecognitionLanguage(_previewLines);
  }

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final repository = widget.settingsRepository;
    if (repository == null) return;
    try {
      final loaded = await repository.loadSettings();
      if (!AppStrings.explicitlySet) AppStrings.setLanguage(loaded.language);
      if (mounted) setState(() => settings = loaded);
    } catch (_) {
      // Defaults keep the capture path available on platforms without SQLite.
    }
  }

  Future<void> _saveSettings(domain.AppSettings next) async {
    final normalized = next.normalized();
    if (mounted) setState(() => settings = normalized);
    try {
      await widget.settingsRepository?.saveSettings(normalized);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('画质设置暂时无法保存，将继续使用当前值'))));
    }
  }

  Future<void> _editResolution() async {
    final value = await _showResolutionPicker(
      context,
      settings.captureResolution,
    );
    if (value != null) {
      await _saveSettings(settings.copyWith(captureResolution: value));
    }
  }

  Future<void> _editPromptSpeed() async {
    final value = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _panel,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(tr('提词速度')),
              subtitle: Text(tr('控制自动推进每句台词的等待时间')),
            ),
            for (final option in const [
              ('慢速', '给停顿和思考留出更多时间'),
              ('中速', '适合大多数自拍视频'),
              ('快速', '更紧凑地推进台词'),
            ])
              ListTile(
                title: Text(tr(option.$1)),
                subtitle: Text(tr(option.$2)),
                trailing: Icon(
                  option.$1 == promptSpeed
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: option.$1 == promptSpeed ? _cyan : _muted,
                ),
                onTap: () => Navigator.pop(context, option.$1),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (value != null && mounted) setState(() => promptSpeed = value);
  }

  Future<void> _beginRecording() async {
    if (_startingRecording) return;
    setState(() => _startingRecording = true);
    try {
      final permissionsReady =
          await PlatformCaptureService.permissionsGranted();
      if (!mounted) return;
      if (!permissionsReady) {
        final understood = await _showCapturePermissionRationale(context);
        if (!understood || !mounted) return;
      }
      final granted = await PlatformCaptureService.requestPermissions();
      if (!mounted) return;
      if (!granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('权限未开启，无法开始录制；请在系统设置重新允许相机和麦克风')),
            action: SnackBarAction(
              label: tr('打开设置'),
              onPressed: () {
                unawaited(PlatformCaptureService.openAppSettings());
              },
            ),
          ),
        );
        return;
      }
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => RecordingPage(
            autoAdvance: autoAdvance,
            promptSpeed: promptSpeed,
            frontCamera: front,
            script: widget.script,
            settings: settings,
            settingsRepository: widget.settingsRepository,
            recoveryRepository: widget.recoveryRepository,
            initialLineIndex: widget.initialLineIndex,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _startingRecording = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final previewLines = _previewLines;
    final previewIndex = _previewIndex;
    return AppScaffold(
      title: tr('拍摄准备'),
      onBack: () => Navigator.pop(context),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.offline_bolt_outlined, color: _cyan, size: 18),
                  SizedBox(width: 8),
                  Text(
                    _recognitionHeadline(_recognitionLanguage),
                    style: TextStyle(color: _cyan, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              ScriptOverviewCard(
                title: _displayScriptTitle(widget.script),
                lineCount: previewLines.length,
                duration:
                    _formatDurationMs(widget.script?.estimatedDurationMs) == '—'
                    ? _formatDurationMs(_demoDurationMs)
                    : _formatDurationMs(widget.script?.estimatedDurationMs),
                badge: tr('拍摄草稿'),
              ),
              const SizedBox(height: 14),
              PromptPreviewCard(
                currentLine: previewLines[previewIndex],
                nextLine: previewIndex + 1 < previewLines.length
                    ? previewLines[previewIndex + 1]
                    : null,
                lineNumber: previewIndex + 1,
                totalLines: previewLines.length,
              ),
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  tr('镜头选择'),
                  style: TextStyle(
                    color: _muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: CameraChoice(
                      label: tr('前置镜头'),
                      icon: Icons.camera_front_outlined,
                      selected: front,
                      onTap: () => setState(() => front = true),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: CameraChoice(
                      label: tr('后置镜头'),
                      icon: Icons.camera_rear_outlined,
                      selected: !front,
                      onTap: () => setState(() => front = false),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  tr('录制设置'),
                  style: TextStyle(
                    color: _muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SettingTile(
                icon: Icons.high_quality_outlined,
                label: tr('视频画质'),
                value: settings.captureResolution.label,
                onTap: _editResolution,
              ),
              const SizedBox(height: 12),
              SettingTile(
                icon: Icons.speed_outlined,
                label: tr('提词速度'),
                value: tr(promptSpeed),
                slider: true,
                progress: switch (promptSpeed) {
                  '慢速' => .3,
                  '快速' => .85,
                  _ => .58,
                },
                onTap: _editPromptSpeed,
              ),
              const SizedBox(height: 12),
              SettingTile(
                icon: Icons.graphic_eq,
                label: tr('自动推进'),
                value: autoAdvance ? tr('按预设时长自动滚动') : tr('手动翻句'),
                toggle: autoAdvance,
                onToggle: (value) => setState(() => autoAdvance = value),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _startingRecording ? null : _beginRecording,
                  style: FilledButton.styleFrom(
                    backgroundColor: _red,
                    foregroundColor: _paper,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                  icon: _startingRecording
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _paper,
                          ),
                        )
                      : const Icon(Icons.fiber_manual_record, size: 18),
                  label: Text(
                    _startingRecording ? tr('正在准备…') : tr('开始录制'),
                    style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CameraChoice extends StatelessWidget {
  const CameraChoice({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: label,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Ink(
        height: 128,
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? _cyan : _border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 40, color: selected ? _cyan : _muted),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    ),
  );
}

class PromptPreviewCard extends StatelessWidget {
  const PromptPreviewCard({
    super.key,
    required this.currentLine,
    required this.nextLine,
    required this.lineNumber,
    required this.totalLines,
  });

  final String currentLine;
  final String? nextLine;
  final int lineNumber;
  final int totalLines;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
    decoration: BoxDecoration(
      color: const Color(0xFF101A1C),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _cyanDim.withValues(alpha: .75)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.visibility_outlined, color: _cyan, size: 18),
            const SizedBox(width: 8),
            Text(
              tr('提词预览'),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const Spacer(),
            Text(
              '$lineNumber / $totalLines',
              style: const TextStyle(color: _muted, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          currentLine,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _paper,
            fontSize: 20,
            height: 1.35,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (nextLine != null) ...[
          const SizedBox(height: 8),
          Text(
            nextLine!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _muted, fontSize: 12, height: 1.35),
          ),
        ],
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            minHeight: 4,
            value: totalLines == 0 ? 0 : lineNumber / totalLines,
            color: _cyan,
            backgroundColor: _border,
          ),
        ),
      ],
    ),
  );
}

class SettingTile extends StatelessWidget {
  const SettingTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.slider = false,
    this.progress,
    this.toggle,
    this.onToggle,
    this.onTap,
  });
  final IconData icon;
  final String label, value;
  final bool slider;
  final double? progress;
  final bool? toggle;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final tileAction =
        onTap ??
        (toggle != null && onToggle != null ? () => onToggle!(!toggle!) : null);
    return InkWell(
      onTap: tileAction,
      borderRadius: BorderRadius.circular(14),
      child: Ink(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _border),
        ),
        child: Row(
          children: [
            Icon(icon, color: _muted),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(value, style: TextStyle(color: slider ? _muted : _cyan)),
                ],
              ),
            ),
            if (slider)
              SizedBox(
                width: 60,
                child: LinearProgressIndicator(
                  value: progress ?? .55,
                  color: _cyan,
                  backgroundColor: _border,
                ),
              ),
            if (toggle != null)
              Switch(
                value: toggle!,
                onChanged: onToggle,
                activeThumbColor: _cyan,
              ),
            if (!slider && toggle == null)
              const Icon(Icons.chevron_right, color: _muted),
          ],
        ),
      ),
    );
  }
}

enum RecognitionVisual { listening, confirming, degraded }

class RecordingPage extends StatefulWidget {
  const RecordingPage({
    super.key,
    required this.autoAdvance,
    this.promptSpeed = '中速',
    this.frontCamera = true,
    this.script,
    this.settings = const domain.AppSettings(),
    this.settingsRepository,
    this.recoveryRepository,
    this.initialLineIndex = 0,
  });
  final bool autoAdvance;
  final String promptSpeed;
  final bool frontCamera;
  final domain.Script? script;
  final domain.AppSettings settings;
  final SettingsRepository? settingsRepository;
  final SessionRecoveryRepository? recoveryRepository;
  final int initialLineIndex;
  @override
  State<RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends State<RecordingPage>
    with WidgetsBindingObserver {
  int current = 0;
  int seconds = 0;
  int countdownRemaining = 3;
  RecognitionVisual state = RecognitionVisual.listening;
  bool isStopping = false;
  bool captureReady = false;
  bool captureStartPending = false;
  int captureAttempt = 0;
  bool thermalWarning = false;
  String? captureError;
  int lineElapsedMs = 0;
  int lastTickMs = 0;
  int sessionStartedAtMs = 0;
  Timer? timer;
  final Stopwatch sessionStopwatch = Stopwatch();
  bool hostResumed = true;
  bool lifecycleInterruptionPending = false;
  bool captureFinalizing = false;
  bool checkingInterruptedResult = false;
  bool _backPromptOpen = false;
  late final CaptureService captureService;
  late final AsrProvider asrProvider;
  late final AlignmentEngine alignmentEngine;
  StreamSubscription<AsrStatusEvent>? asrStatusSubscription;
  StreamSubscription<AsrPartial>? asrPartialSubscription;
  StreamSubscription<CapturePhaseEvent>? capturePhaseSubscription;
  domain.CapturePhase capturePhase = domain.CapturePhase.idle;
  bool captureErrorDuringSession = false;
  late final List<ScriptLine> lines;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    captureService = PlatformCaptureService.isSupported
        ? PlatformCaptureService()
        : PreviewCaptureService();
    // Construct the ASR owner before subscribing to native capture events.
    // EventChannel can deliver the controller's current/failed phase during
    // listen(), and the failure path must never touch an uninitialized late
    // field while the page is still being mounted.
    asrProvider = asrProviderForCurrentPlatform(
      language: widget.settings.recognitionLanguage,
      scriptLines:
          widget.script?.lines.map((line) => line.text) ?? const <String>[],
    );
    capturePhaseSubscription = captureService.phase.listen((event) {
      final wasRecording =
          captureReady || capturePhase == domain.CapturePhase.recording;
      capturePhase = event.phase;
      if (event.reason == 'thermal_warning' && mounted) {
        if (!thermalWarning) setState(() => thermalWarning = true);
      } else if (event.reason == 'thermal_recovered' && mounted) {
        if (thermalWarning) setState(() => thermalWarning = false);
      }
      if (event.phase == domain.CapturePhase.stopping &&
          event.reason == 'app_interrupted') {
        lifecycleInterruptionPending = true;
        captureFinalizing = true;
        if (mounted && !isStopping && captureError == null) {
          setState(() => state = RecognitionVisual.degraded);
        }
      }
      if (event.phase == domain.CapturePhase.completed &&
          hostResumed &&
          lifecycleInterruptionPending &&
          !checkingInterruptedResult) {
        unawaited(_resolveInterruptedCapture());
      }
      if (!mounted || event.phase != domain.CapturePhase.failed) return;
      captureReady = false;
      captureFinalizing = false;
      timer?.cancel();
      sessionStopwatch.stop();
      final message = switch (event.reason) {
        'camera_unavailable' => tr('相机没有准备好，请返回后重试'),
        'audio_unavailable' => tr('麦克风无法启动，请检查权限后重试'),
        'storage_low' => tr('可用存储空间不足，请清理后重试'),
        'capture_busy' => tr('上一段录制正在保存，请稍候再试'),
        'capture_cancelled' => tr('已取消录制准备，请返回拍摄准备后重试'),
        'recording_failed' => tr('相机编码器未能生成视频，请返回后重试'),
        'capture_disposed' => tr('录制已被中断，视频未保存'),
        _ => tr('录制过程中出现问题，视频未保存，请返回后重试'),
      };
      setState(() {
        state = RecognitionVisual.degraded;
        captureErrorDuringSession = wasRecording;
        captureError = message;
      });
      unawaited(asrProvider.stop());
    });
    asrPartialSubscription = asrProvider.partials.listen(_handleAsrPartial);
    asrStatusSubscription = asrProvider.status.listen((event) {
      if (!mounted) return;
      final next = switch (event.status) {
        AsrStatus.listening => RecognitionVisual.listening,
        AsrStatus.initializing => RecognitionVisual.confirming,
        AsrStatus.unavailable ||
        AsrStatus.degraded ||
        AsrStatus.stopped => RecognitionVisual.degraded,
      };
      setState(() => state = next);
    });
    final configuredLines = widget.script?.lines
        .map(
          (line) => ScriptLine(
            line.text,
            seconds: line.expectedDurationMs / 1000,
            pause: line.pauseAfterMs / 1000,
          ),
        )
        .toList();
    lines = configuredLines == null || configuredLines.isEmpty
        ? _demoLinesForLanguage()
        : configuredLines;
    current = widget.initialLineIndex.clamp(0, lines.length - 1).toInt();
    alignmentEngine = AlignmentEngine(
      lines: List<domain.ScriptLine>.generate(
        lines.length,
        (index) => domain.ScriptLine(
          id: 'recording-line-$index',
          order: index,
          text: lines[index].text,
          expectedDurationMs: (lines[index].seconds * 1000).round(),
          pauseAfterMs: (lines[index].pause * 1000).round(),
        ),
      ),
      autoAdvance: widget.autoAdvance,
    );
    alignmentEngine.currentLineIndex = current;
    // The capture page starts in a preparation state. Only a provider or
    // capture failure should claim that recognition has degraded; showing the
    // fallback label while the bundled model is still warming up is misleading
    // and makes the first-run experience feel broken.
    state = RecognitionVisual.confirming;
    _startCaptureSession();
  }

  Future<void> _startCaptureSession() async {
    final attempt = ++captureAttempt;
    try {
      final resolution = widget.settings.captureResolution;
      await captureService.prepare(
        CaptureConfig(
          frontCamera: widget.frontCamera,
          width: resolution.width,
          height: resolution.height,
          mirrorPreview: widget.frontCamera && widget.settings.mirrorPreview,
        ),
      );
    } catch (_) {
      if (mounted && attempt == captureAttempt) {
        setState(() {
          state = RecognitionVisual.degraded;
          countdownRemaining = 0;
          captureError = tr('相机初始化失败，请返回准备页检查权限或更换镜头');
        });
      }
      return;
    }
    if (!mounted ||
        attempt != captureAttempt ||
        !hostResumed ||
        captureError != null ||
        capturePhase == domain.CapturePhase.failed) {
      return;
    }

    // Warm up the local recognizer before the countdown starts. The native
    // capture owner has not opened the microphone yet, so subscribing here
    // is safe and guarantees that the first spoken words are not lost while
    // a bundled model is copied/initialized for the first time.
    try {
      final available = await asrProvider.start(
        audioFeed: captureService.audioFeed,
      );
      if (mounted && attempt == captureAttempt && !available) {
        setState(() => state = RecognitionVisual.degraded);
      }
    } catch (_) {
      if (mounted && attempt == captureAttempt) {
        setState(() => state = RecognitionVisual.degraded);
      }
    }
    if (!mounted ||
        attempt != captureAttempt ||
        !hostResumed ||
        captureError != null ||
        capturePhase == domain.CapturePhase.failed) {
      return;
    }
    for (var remaining = 3; remaining > 0; remaining--) {
      if (!mounted ||
          attempt != captureAttempt ||
          !hostResumed ||
          captureError != null ||
          capturePhase == domain.CapturePhase.failed) {
        return;
      }
      setState(() => countdownRemaining = remaining);
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (!mounted ||
        attempt != captureAttempt ||
        !hostResumed ||
        captureError != null ||
        capturePhase == domain.CapturePhase.failed) {
      return;
    }
    setState(() => countdownRemaining = 0);
    // Record the session boundary before crossing into the asynchronous
    // native start hand-off. CameraX can create a Recording just before its
    // platform result reaches Flutter; an immediate lifecycle interruption in
    // that window still needs a durable checkpoint with a real start time.
    sessionStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    captureStartPending = true;
    try {
      await captureService.start(countdown: Duration.zero);
    } on PlatformException catch (error) {
      if (attempt != captureAttempt) return;
      try {
        await asrProvider.stop();
      } catch (_) {
        // ASR cleanup is best effort; the capture error remains the primary
        // failure shown to the user.
      }
      if (mounted) {
        setState(() {
          captureReady = false;
          captureErrorDuringSession = false;
          timer?.cancel();
          sessionStopwatch.stop();
          state = RecognitionVisual.degraded;
          countdownRemaining = 0;
          captureError = switch (error.code) {
            'capture_busy' => tr('上一段录制正在保存，请稍候再试'),
            'capture_cancelled' => tr('已取消录制准备，请返回拍摄准备后重试'),
            'camera_unavailable' => tr('相机初始化失败，请返回后重试'),
            'audio_unavailable' => tr('麦克风无法启动，请检查权限后重试'),
            _ => tr('录制启动失败，视频未保存，请返回后重试'),
          };
        });
      }
      return;
    } catch (_) {
      if (attempt != captureAttempt) return;
      try {
        await asrProvider.stop();
      } catch (_) {
        // ASR cleanup is best effort; the capture error remains the primary
        // failure shown to the user.
      }
      if (mounted) {
        setState(() {
          captureReady = false;
          captureErrorDuringSession = false;
          timer?.cancel();
          sessionStopwatch.stop();
          state = RecognitionVisual.degraded;
          countdownRemaining = 0;
          captureError = tr('录制启动失败，视频未保存，请返回后重试');
        });
      }
      return;
    } finally {
      if (attempt == captureAttempt) captureStartPending = false;
    }
    if (!mounted || attempt != captureAttempt || captureError != null) return;
    captureReady = true;
    await _persistRecovery();
    if (!mounted) return;
    sessionStopwatch.start();
    lastTickMs = 0;
    timer = Timer.periodic(const Duration(milliseconds: 250), _onTimerTick);
  }

  void _onTimerTick(Timer _) {
    if (!mounted || isStopping) return;
    final elapsedMs = sessionStopwatch.elapsedMilliseconds;
    final deltaMs = (elapsedMs - lastTickMs).clamp(0, 2000).toInt();
    lastTickMs = elapsedMs;
    setState(() {
      seconds = elapsedMs ~/ 1000;
      lineElapsedMs += deltaMs;
      if (!widget.autoAdvance || current >= lines.length - 1) return;
      final thresholdMs =
          (((lines[current].seconds + lines[current].pause) * 1000) /
                  _promptSpeedMultiplier)
              .round()
              .clamp(1000, 120000)
              .toInt();
      if (lineElapsedMs < thresholdMs) return;
      final decision = alignmentEngine.timedFallback(timestampMs: elapsedMs);
      if (decision.shouldAdvance) {
        current = decision.currentLineIndex;
        lineElapsedMs = 0;
        unawaited(_persistRecovery());
      }
    });
  }

  double get _promptSpeedMultiplier => switch (widget.promptSpeed) {
    '慢速' => .82,
    '快速' => 1.22,
    _ => 1.0,
  };

  void _handleAsrPartial(AsrPartial partial) {
    if (!mounted || isStopping) return;
    final decision = alignmentEngine.evaluate(partial);
    if (!decision.shouldAdvance || decision.currentLineIndex == current) return;
    setState(() {
      current = decision.currentLineIndex;
      lineElapsedMs = 0;
    });
    unawaited(_persistRecovery());
  }

  @override
  void dispose() {
    captureAttempt++;
    captureStartPending = false;
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    sessionStopwatch.stop();
    asrStatusSubscription?.cancel();
    asrPartialSubscription?.cancel();
    capturePhaseSubscription?.cancel();
    unawaited(asrProvider.dispose());
    unawaited(captureService.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    hostResumed = lifecycleState == AppLifecycleState.resumed;
    if (lifecycleState == AppLifecycleState.inactive ||
        lifecycleState == AppLifecycleState.paused ||
        lifecycleState == AppLifecycleState.hidden) {
      // Before CameraX has started, there is no recording to finalize. Abort
      // the countdown instead of allowing a delayed future to open the
      // camera while the app is in the background.
      if (!captureReady &&
          (countdownRemaining > 0 || captureStartPending) &&
          captureError == null &&
          !captureFinalizing) {
        captureAttempt++;
        captureStartPending = false;
        setState(() {
          countdownRemaining = 0;
          captureErrorDuringSession = false;
          captureError = tr('录制准备被中断，请回到拍摄准备后重试');
          state = RecognitionVisual.degraded;
        });
        // If CameraX crossed the start hand-off boundary just before the
        // lifecycle callback, preserve that take instead of treating it as a
        // user cancellation. The native owner will finalize it and the normal
        // interrupted-capture recovery path will consume the result on resume.
        unawaited(captureService.cancelStart(preserveRecording: true));
        unawaited(asrProvider.stop());
      }
      return;
    }
    if (lifecycleState == AppLifecycleState.resumed &&
        lifecycleInterruptionPending) {
      unawaited(_resolveInterruptedCapture());
    }
  }

  Future<void> _resolveInterruptedCapture() async {
    // Normally an interruption arrives after captureReady is true. The
    // native start hand-off has one small exception: CameraX may have created
    // its Recording just before Flutter processed the lifecycle callback, so
    // the page still reports captureReady=false while a finalized result is
    // already on its way. The native app_interrupted event is the authority
    // for allowing that recovery path.
    if ((!captureReady && !lifecycleInterruptionPending) ||
        isStopping ||
        checkingInterruptedResult) {
      return;
    }
    checkingInterruptedResult = true;
    try {
      // Finalization is asynchronous in CameraX. A short retry window covers
      // the common case where onResume arrives before the Finalize callback;
      // audio muxing can take several seconds for a longer clip, so do not
      // leave the page in a recording state after a transient early null.
      CaptureResult? result;
      for (var attempt = 0; attempt < 40 && result == null; attempt++) {
        result = await captureService.takeFinalizedResult();
        if (result == null) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      if (result == null) {
        isStopping = true;
        captureReady = false;
        timer?.cancel();
        sessionStopwatch.stop();
        await _persistRecovery(state: domain.RecoveryState.stopping);
        try {
          await asrProvider.stop();
        } catch (_) {
          // The native owner has already stopped; ASR cleanup is best effort.
        }
        if (mounted) {
          setState(() {
            captureFinalizing = false;
            captureErrorDuringSession = true;
            captureError = tr('录制已中断，保存结果暂未返回，请稍后到系统相册查看');
          });
        }
        return;
      }
      if (!mounted || isStopping) return;
      isStopping = true;
      captureReady = false;
      timer?.cancel();
      sessionStopwatch.stop();
      await _persistRecovery(state: domain.RecoveryState.stopping);
      try {
        await asrProvider.stop();
      } catch (_) {
        // The capture owner has already finalized; ASR cleanup is best effort.
      }
      await _presentComplete(result);
    } finally {
      lifecycleInterruptionPending = false;
      checkingInterruptedResult = false;
      captureFinalizing = false;
    }
  }

  Future<void> _stopRecording() async {
    if (isStopping || captureFinalizing) return;
    if (!captureReady) {
      // The countdown is a real, visible control state. Tapping its stop
      // affordance must cancel both the visible countdown and the narrower
      // CameraX bind/start window after the countdown has reached zero. The
      // native owner completes a pending start Future with capture_cancelled;
      // the attempt generation below ignores that expected late result.
      if ((countdownRemaining > 0 || captureStartPending) &&
          captureError == null) {
        captureAttempt++;
        captureStartPending = false;
        setState(() {
          countdownRemaining = 0;
          captureErrorDuringSession = false;
          captureError = tr('已取消录制准备，请返回拍摄准备后重试');
          state = RecognitionVisual.degraded;
        });
        // A user tapping Cancel owns the just-started hand-off window. If the
        // native Recording already exists, the platform owner stops and
        // discards that partial take so it cannot become a ghost gallery item.
        await captureService.cancelStart();
        await asrProvider.stop();
      }
      return;
    }
    isStopping = true;
    if (mounted) {
      // Audio is finalized and muxed after CameraX stops. Lock the recording
      // surface immediately so a user cannot change the resume line or open
      // settings while the result that is about to be shown is being built.
      setState(() => captureFinalizing = true);
    }
    timer?.cancel();
    await _persistRecovery(state: domain.RecoveryState.stopping);
    try {
      await asrProvider.stop();
    } catch (_) {
      // ASR failure must not prevent the capture owner from finalizing video.
    }
    CaptureResult result;
    try {
      result = await captureService.stop();
    } catch (_) {
      result = CaptureResult(saved: false, error: tr('录制服务暂时不可用，视频未保存'));
    }
    if (!mounted) return;
    await _presentComplete(result);
  }

  Future<void> _presentComplete(CaptureResult result) async {
    if (!mounted) return;
    await clearRecoveryAfterSuccessfulCapture(
      widget.recoveryRepository,
      result,
    );
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => CompletePage(
          result: result,
          script: widget.script,
          resumeLineIndex: current,
          settingsRepository: widget.settingsRepository,
          recoveryRepository: widget.recoveryRepository,
        ),
      ),
    );
  }

  Future<void> _handleSystemBack() async {
    if (!mounted || _backPromptOpen) return;
    // Error states already expose an explicit "返回拍摄准备" action. Let the
    // platform back gesture work naturally there instead of trapping the user
    // behind a second confirmation dialog.
    if (captureError != null && !captureFinalizing) {
      Navigator.pop(context);
      return;
    }
    if (isStopping || captureFinalizing || checkingInterruptedResult) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('正在保存录制结果，请稍候'))));
      return;
    }

    _backPromptOpen = true;
    try {
      final shouldLeave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: _panel,
          title: Text(tr(captureReady ? '结束这次录制？' : '离开拍摄准备？')),
          content: Text(
            captureReady ? tr('确认后会结束并保存当前视频。') : tr('确认后会取消本次录制准备，不会生成视频。'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('继续录制')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(captureReady ? '结束并保存' : '离开')),
            ),
          ],
        ),
      );
      if (!mounted || shouldLeave != true) return;

      if (captureReady) {
        // _stopRecording owns the completion-page transition. The PopScope
        // callback never performs a second pop while that replacement runs.
        await _stopRecording();
        return;
      }

      // Cancel countdown/native start first, then leave the page. This also
      // covers the tiny CameraX hand-off window where a native Recording may
      // already exist.
      await _stopRecording();
      if (mounted) Navigator.pop(context);
    } finally {
      _backPromptOpen = false;
    }
  }

  Widget _cameraSurface() {
    if (PlatformCaptureService.isSupported) {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        return const UiKitView(viewType: 'scriptmirror.camera_preview');
      }
      return const AndroidView(viewType: 'scriptmirror.camera_preview');
    }
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF242A2B), Color(0xFF081113), _ink],
        ),
      ),
      child: const Center(
        child: Icon(Icons.person_outline, size: 180, color: Color(0x334F6063)),
      ),
    );
  }

  void _move(int delta) {
    final target = (current + delta).clamp(0, lines.length - 1).toInt();
    final decision = alignmentEngine.manualMove(
      target,
      timestampMs: sessionStopwatch.elapsedMilliseconds,
    );
    setState(() {
      current = decision.currentLineIndex;
      lineElapsedMs = 0;
    });
    unawaited(_persistRecovery());
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panel,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('录制中设置'),
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                tr('本次录制的镜头、画质和镜像状态已锁定，下一次录制前可在设置中调整。'),
                style: TextStyle(color: _muted, height: 1.45),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr('知道了')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _persistRecovery({
    domain.RecoveryState state = domain.RecoveryState.recording,
  }) async {
    final repository = widget.recoveryRepository;
    final script = widget.script;
    if (repository == null || script == null || sessionStartedAtMs == 0) return;
    try {
      await repository.saveRecovery(
        domain.CaptureRecovery(
          scriptId: script.id,
          currentLineIndex: current,
          startedAtMs: sessionStartedAtMs,
          state: state,
        ),
      );
    } catch (_) {
      // Recovery is best effort and must not interrupt an active recording.
    }
  }

  String get elapsed =>
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  @override
  Widget build(BuildContext context) {
    final status = switch (state) {
      RecognitionVisual.listening when widget.autoAdvance => (tr('跟稿中'), _cyan),
      RecognitionVisual.listening => (tr('手动翻句'), _muted),
      RecognitionVisual.confirming => (tr('准备本地识别'), _amber),
      // With automatic advancement disabled there is no timed fallback either;
      // an unavailable recognizer leaves the user in the explicit manual mode.
      RecognitionVisual.degraded when widget.autoAdvance => (
        tr('按节奏提词'),
        _amber,
      ),
      RecognitionVisual.degraded => (tr('手动翻句'), _muted),
    };
    return PopScope<void>(
      canPop: captureError != null && !captureFinalizing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleSystemBack());
      },
      child: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: _cameraSurface()),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        _ink.withValues(alpha: .2),
                        Colors.transparent,
                        _ink.withValues(alpha: .55),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (thermalWarning && captureError == null)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 66,
                left: 22,
                right: 22,
                child: IgnorePointer(
                  child: Semantics(
                    liveRegion: true,
                    label: tr('设备温度较高，建议录制完成后切换到 720p'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: _ink.withValues(alpha: .86),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _amber.withValues(alpha: .8)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.thermostat_outlined,
                            color: _amber,
                            size: 18,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              tr('设备温度较高 · 本次录制不会中断，下一次可切换 720p'),
                              style: TextStyle(color: _paper, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (countdownRemaining > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      width: 112,
                      height: 112,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _ink.withValues(alpha: .78),
                        shape: BoxShape.circle,
                        border: Border.all(color: _cyan, width: 2),
                      ),
                      child: Text(
                        '$countdownRemaining',
                        style: const TextStyle(
                          fontSize: 56,
                          fontWeight: FontWeight.w800,
                          color: _cyan,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ExcludeSemantics(
              excluding: captureError != null,
              child: AbsorbPointer(
                absorbing:
                    captureError != null ||
                    isStopping ||
                    captureFinalizing ||
                    checkingInterruptedResult,
                child: SafeArea(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(22, 16, 22, 12),
                        child: Row(
                          children: [
                            Row(
                              children: [
                                Icon(Icons.circle, color: status.$2, size: 12),
                                const SizedBox(width: 7),
                                Text(
                                  status.$1,
                                  style: TextStyle(
                                    color: status.$2,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 15,
                                vertical: 9,
                              ),
                              decoration: BoxDecoration(
                                color: _panel.withValues(alpha: .95),
                                borderRadius: BorderRadius.circular(28),
                                border: Border.all(color: _border),
                              ),
                              child: Text(
                                '●  $elapsed',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.5,
                                ),
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              tooltip: tr('录制设置'),
                              onPressed: _openSettings,
                              icon: const Icon(Icons.tune),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        margin: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                        padding: const EdgeInsets.all(28),
                        height: MediaQuery.sizeOf(context).height * .42,
                        decoration: BoxDecoration(
                          color: _ink.withValues(
                            alpha: widget.settings.backgroundOpacity.clamp(
                              0.2,
                              0.9,
                            ),
                          ),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: _border),
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) => FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: constraints.maxWidth,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Semantics(
                                    liveRegion: true,
                                    label: lines[current].text,
                                    child: AnimatedSwitcher(
                                      duration: const Duration(
                                        milliseconds: 260,
                                      ),
                                      child: Text(
                                        lines[current].text,
                                        key: ValueKey(current),
                                        style:
                                            const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              color: _paper,
                                            ).copyWith(
                                              fontSize:
                                                  widget.settings.fontSize,
                                              height:
                                                  widget.settings.lineHeight,
                                            ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 24),
                                  if (widget.settings.lookaheadLines >= 1 &&
                                      current + 1 < lines.length)
                                    Text(
                                      lines[current + 1].text,
                                      style: TextStyle(
                                        fontSize:
                                            widget.settings.fontSize * .72,
                                        height: widget.settings.lineHeight,
                                        color: _muted,
                                      ),
                                    ),
                                  if (widget.settings.lookaheadLines >= 2 &&
                                      current + 2 < lines.length)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: Text(
                                        lines[current + 2].text,
                                        style: TextStyle(
                                          fontSize:
                                              widget.settings.fontSize * .66,
                                          height: widget.settings.lineHeight,
                                          color: _muted.withValues(alpha: .75),
                                        ),
                                      ),
                                    ),
                                  if (widget.settings.lookaheadLines >= 3 &&
                                      current + 3 < lines.length)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 10),
                                      child: Text(
                                        lines[current + 3].text,
                                        style: TextStyle(
                                          fontSize:
                                              widget.settings.fontSize * .60,
                                          height: widget.settings.lineHeight,
                                          color: _muted.withValues(alpha: .55),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(28, 12, 28, 30),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            RecordingControl(
                              icon: Icons.skip_previous,
                              label: tr('上一句'),
                              enabled: current > 0,
                              onTap: current > 0 ? () => _move(-1) : null,
                            ),
                            RecordingControl(
                              icon: captureReady ? Icons.stop : Icons.close,
                              label: tr(captureReady ? '停止' : '取消'),
                              critical: true,
                              onTap: _stopRecording,
                            ),
                            RecordingControl(
                              icon: Icons.skip_next,
                              label: tr('下一句'),
                              enabled: current < lines.length - 1,
                              onTap: current < lines.length - 1
                                  ? () => _move(1)
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (captureError != null)
              Positioned.fill(
                child: Container(
                  color: _ink.withValues(alpha: .9),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.videocam_off_outlined,
                        color: _amber,
                        size: 48,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        tr(captureErrorDuringSession ? '录制已中断' : '暂时无法开始录制'),
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        captureError!,
                        style: const TextStyle(color: _muted, height: 1.45),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 22),
                      FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(tr('返回拍摄准备')),
                      ),
                    ],
                  ),
                ),
              ),
            if (captureError == null &&
                (captureFinalizing || checkingInterruptedResult))
              Positioned.fill(
                child: Container(
                  color: _ink.withValues(alpha: .84),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: _cyan),
                      const SizedBox(height: 18),
                      Text(
                        tr('正在保存录制结果'),
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tr('请稍候，音视频正在完成合并。'),
                        style: TextStyle(color: _muted),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class RecordingControl extends StatelessWidget {
  const RecordingControl({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.enabled = true,
    this.critical = false,
  });
  final IconData icon;
  final String label;
  final bool critical;
  final VoidCallback? onTap;
  final bool enabled;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: enabled ? onTap : null,
    borderRadius: BorderRadius.circular(44),
    child: Column(
      children: [
        Container(
          width: critical ? 76 : 60,
          height: critical ? 76 : 60,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: !enabled
                ? _panel.withValues(alpha: .45)
                : (critical ? _red : _panel),
            border: Border.all(
              color: !enabled
                  ? _border.withValues(alpha: .45)
                  : (critical ? _red : _border),
            ),
          ),
          child: Icon(
            icon,
            color: enabled ? _paper : _muted.withValues(alpha: .45),
            size: critical ? 34 : 29,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          label,
          style: TextStyle(
            color: enabled ? _paper : _muted.withValues(alpha: .45),
          ),
        ),
      ],
    ),
  );
}

class CompletePage extends StatelessWidget {
  const CompletePage({
    super.key,
    this.result = const CaptureResult(
      saved: false,
      error: 'No recording result',
    ),
    this.script,
    this.resumeLineIndex,
    this.settingsRepository,
    this.recoveryRepository,
  });
  final CaptureResult result;
  final domain.Script? script;
  final int? resumeLineIndex;
  final SettingsRepository? settingsRepository;
  final SessionRecoveryRepository? recoveryRepository;

  Future<void> _finish(BuildContext context) async {
    try {
      await recoveryRepository?.clearRecovery();
    } catch (_) {
      // Finishing the page remains possible even if the cleanup is unavailable.
    }
    if (context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(24),
            sliver: SliverFillRemaining(
              hasScrollBody: false,
              child: Column(
                children: [
                  const Spacer(),
                  Container(
                    width: 112,
                    height: 112,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: result.saved ? _cyan : _amber,
                        width: 3,
                      ),
                    ),
                    child: Icon(
                      result.saved ? Icons.check : Icons.error_outline,
                      color: result.saved ? _cyan : _amber,
                      size: 60,
                    ),
                  ),
                  const SizedBox(height: 26),
                  Text(
                    tr(result.saved ? '录制完成' : '录制未保存'),
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    result.interrupted
                        ? tr(result.saved ? '录制被中断，但视频已保存' : '录制被中断，视频未保存')
                        : tr(result.saved ? '视频已保存到相册' : '视频文件没有写入相册'),
                    style: const TextStyle(fontSize: 16, color: _muted),
                  ),
                  if (result.interrupted && resumeLineIndex != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      AppStrings.replace('已保留到第 {line} 行，可从这里继续', {
                        'line': resumeLineIndex! + 1,
                      }),
                      style: const TextStyle(color: _cyan),
                    ),
                  ],
                  if (result.error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      tr(result.error!),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: _amber),
                    ),
                  ],
                  const SizedBox(height: 28),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _panel,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _border),
                    ),
                    child: Column(
                      children: [
                        InfoRow(
                          tr('分辨率'),
                          result.resolution ??
                              (result.saved ? tr('未读取') : tr('未生成')),
                        ),
                        Divider(color: _border),
                        InfoRow(tr('时长'), _formatDurationMs(result.durationMs)),
                        Divider(color: _border),
                        InfoRow(tr('文件大小'), result.saved ? tr('由系统相册管理') : '—'),
                        if (result.saved) ...[
                          Divider(color: _border),
                          InfoRow(
                            tr('保存位置'),
                            tr(result.storageLocation ?? '系统相册'),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Spacer(),
                  if (result.saved && result.mediaUri != null) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final opened = await PlatformCaptureService.openMedia(
                            result.mediaUri!,
                          );
                          if (!opened && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(tr('系统没有可打开此视频的相册或播放器'))),
                            );
                          }
                        },
                        icon: const Icon(Icons.play_circle_outline),
                        label: Text(tr('打开已保存视频')),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _cyan,
                          side: const BorderSide(color: _cyanDim),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => _finish(context),
                      style: FilledButton.styleFrom(
                        backgroundColor: _cyan,
                        foregroundColor: _ink,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: Text(
                        tr('完成'),
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PreparePage(
                            script: script,
                            initialLineIndex: result.interrupted
                                ? (resumeLineIndex ?? 0)
                                : 0,
                            settingsRepository: settingsRepository,
                            recoveryRepository: recoveryRepository,
                          ),
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _paper,
                        side: const BorderSide(color: _muted),
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: Text(
                        result.interrupted && resumeLineIndex != null
                            ? AppStrings.replace('从第 {line} 行继续', {
                                'line': resumeLineIndex! + 1,
                              })
                            : tr('再录一次'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PreparePage(
                          script: script,
                          initialLineIndex: result.interrupted
                              ? (resumeLineIndex ?? 0)
                              : 0,
                          settingsRepository: settingsRepository,
                          recoveryRepository: recoveryRepository,
                        ),
                      ),
                    ),
                    child: Text(tr('继续拍同一文稿'), style: TextStyle(color: _muted)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _muted, fontSize: 18),
          ),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.repository});
  final SettingsRepository? repository;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  domain.AppSettings settings = const domain.AppSettings();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final repository = widget.repository;
    if (repository == null) return;
    try {
      final loaded = await repository.loadSettings();
      if (mounted) setState(() => settings = loaded);
    } catch (_) {
      // Defaults are a valid fallback on desktop and widget-test platforms.
    }
  }

  Future<void> _saveSettings(domain.AppSettings next) async {
    if (!mounted) return;
    final normalized = next.normalized();
    AppStrings.setLanguage(normalized.language);
    setState(() => settings = normalized);
    try {
      await widget.repository?.saveSettings(normalized);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('设置暂时无法保存，将继续使用当前值'))));
      }
    }
  }

  Future<void> _editFontSize() async {
    final value = await _showSlider(
      title: tr('默认字号'),
      initial: settings.fontSize,
      min: 18,
      max: 42,
      divisions: 24,
      suffix: 'sp',
    );
    if (value != null) _saveSettings(settings.copyWith(fontSize: value));
  }

  Future<void> _editOpacity() async {
    final value = await _showSlider(
      title: tr('背景透明度'),
      initial: settings.backgroundOpacity,
      min: .2,
      max: .9,
      divisions: 14,
      suffix: '%',
      displayMultiplier: 100,
    );
    if (value != null) {
      _saveSettings(settings.copyWith(backgroundOpacity: value));
    }
  }

  Future<void> _editLineHeight() async {
    final value = await _showSlider(
      title: tr('行距'),
      initial: settings.lineHeight,
      min: 1.15,
      max: 1.8,
      divisions: 13,
      suffix: 'x',
    );
    if (value != null) _saveSettings(settings.copyWith(lineHeight: value));
  }

  Future<void> _editLookahead() async {
    final value = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: _panel,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(tr('前瞻行数'))),
            for (var count = 1; count <= 3; count++)
              ListTile(
                title: Text(_lookaheadLabel(count)),
                trailing: Icon(
                  count == settings.lookaheadLines
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: count == settings.lookaheadLines ? _cyan : _muted,
                ),
                onTap: () => Navigator.pop(context, count),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (value != null) _saveSettings(settings.copyWith(lookaheadLines: value));
  }

  Future<void> _editMirror() async {
    final value = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: _panel,
      builder: (context) => SafeArea(
        child: SwitchListTile(
          title: Text(tr('自拍镜像')),
          subtitle: Text(tr('前置预览和保存视频保持一致的镜像效果')),
          value: settings.mirrorPreview,
          activeThumbColor: _cyan,
          onChanged: (value) => Navigator.pop(context, value),
        ),
      ),
    );
    if (value != null) _saveSettings(settings.copyWith(mirrorPreview: value));
  }

  Future<void> _editRecognitionLanguage() async {
    final value = await showModalBottomSheet<domain.RecognitionLanguage>(
      context: context,
      backgroundColor: _panel,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(tr('识别语言')),
              subtitle: Text(tr('自动按文稿选择，也可以手动指定')),
            ),
            for (final option in domain.RecognitionLanguage.values)
              ListTile(
                title: Text(_recognitionLanguageLabel(option)),
                subtitle: Text(
                  tr(switch (option) {
                    domain.RecognitionLanguage.automatic => '根据文稿中英文字符自动选择模型',
                    domain.RecognitionLanguage.chinese => '使用中文离线模型',
                    domain.RecognitionLanguage.english => '使用英文离线模型',
                  }),
                ),
                trailing: Icon(
                  option == settings.recognitionLanguage
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: option == settings.recognitionLanguage
                      ? _cyan
                      : _muted,
                ),
                onTap: () => Navigator.pop(context, option),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (value != null) {
      await _saveSettings(settings.copyWith(recognitionLanguage: value));
    }
  }

  Future<void> _editLanguage() async {
    final value = await showModalBottomSheet<AppLanguage>(
      context: context,
      backgroundColor: _panel,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(tr('语言'))),
            ListTile(
              title: const Text('English'),
              subtitle: Text(tr('默认语言，适合国际版发布')),
              trailing: Icon(
                settings.language == AppLanguage.english
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: settings.language == AppLanguage.english
                    ? _cyan
                    : _muted,
              ),
              onTap: () => Navigator.pop(context, AppLanguage.english),
            ),
            ListTile(
              title: const Text('简体中文'),
              subtitle: Text(tr('中文界面与本地离线识别')),
              trailing: Icon(
                settings.language == AppLanguage.chinese
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: settings.language == AppLanguage.chinese
                    ? _cyan
                    : _muted,
              ),
              onTap: () => Navigator.pop(context, AppLanguage.chinese),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (value != null) {
      await _saveSettings(settings.copyWith(language: value));
    }
  }

  Future<void> _editResolution() async {
    final value = await _showResolutionPicker(
      context,
      settings.captureResolution,
    );
    if (value != null) {
      await _saveSettings(settings.copyWith(captureResolution: value));
    }
  }

  Future<void> _resetSettings() async {
    await _saveSettings(const domain.AppSettings());
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr('已恢复默认设置'))));
  }

  Future<void> _showInfoSheet({
    required IconData icon,
    required String title,
    required String body,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _cyanDim.withValues(alpha: .35),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(icon, color: _cyan),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(body, style: const TextStyle(color: _muted, height: 1.55)),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr('知道了')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showStorageInfo() => _showInfoSheet(
    icon: Icons.photo_library_outlined,
    title: tr('存储位置'),
    body: tr(
      '录制完成后，视频会交给系统相册管理，优先保存到 DCIM/ScriptMirror。\n\nAndroid 8/9 如果设备不允许创建自定义目录，会自动回退到系统共享视频位置；应用不会清理其他相册内容。',
    ),
  );

  Future<void> _showAsrInfo() => _showInfoSheet(
    icon: Icons.offline_bolt_outlined,
    title: tr('语音识别'),
    body: tr(
      '镜词内置 sherpa-onnx 中英文流式识别模型，识别在本机 CPU 完成，不需要网络，也不会上传录音。\n\n默认会根据文稿中的中英文字符自动选择模型，也可以在“识别语言”中手动指定。\n\n如果设备无法初始化模型，录制仍会继续，并自动切换为按节奏或手动提词。',
    ),
  );

  Future<void> _showAbout() => _showInfoSheet(
    icon: Icons.info_outline,
    title: tr('关于镜词'),
    body:
        '${tr('镜词是一款本地优先的自拍视频提词器：让你看着镜头，也不用忘记下一句。\n\n版本')} $_appVersion · ${tr('文稿、录音和视频默认只保存在本机。')}',
  );

  Future<double?> _showSlider({
    required String title,
    required double initial,
    required double min,
    required double max,
    required int divisions,
    required String suffix,
    double displayMultiplier = 1,
  }) async {
    var value = initial;
    return showModalBottomSheet<double>(
      context: context,
      backgroundColor: _panel,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(title),
                  trailing: Text(
                    '${(value * displayMultiplier).toStringAsFixed(displayMultiplier == 1 ? 2 : 0)}$suffix',
                    style: const TextStyle(color: _cyan),
                  ),
                ),
                Slider(
                  value: value,
                  min: min,
                  max: max,
                  divisions: divisions,
                  label:
                      '${(value * displayMultiplier).toStringAsFixed(displayMultiplier == 1 ? 2 : 0)}$suffix',
                  onChanged: (next) => setModalState(() => value = next),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, value),
                    child: Text(tr('保存')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AppScaffold(
    title: tr('设置'),
    onBack: () => Navigator.pop(context),
    child: ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        SettingsSection(
          title: tr('提词器偏好'),
          children: [
            SettingsItem(
              Icons.format_size,
              tr('默认字号'),
              '${settings.fontSize.round()}sp',
              onTap: _editFontSize,
            ),
            SettingsItem(
              Icons.opacity,
              tr('背景透明度'),
              '${(settings.backgroundOpacity * 100).round()}%',
              onTap: _editOpacity,
            ),
            SettingsItem(
              Icons.visibility_outlined,
              tr('前瞻行数'),
              _lookaheadLabel(settings.lookaheadLines),
              onTap: _editLookahead,
            ),
            SettingsItem(
              Icons.format_line_spacing,
              tr('行距'),
              '${settings.lineHeight.toStringAsFixed(2)}x',
              onTap: _editLineHeight,
            ),
          ],
        ),
        SettingsSection(
          title: tr('录制与行为'),
          children: [
            SettingsItem(
              Icons.flip,
              tr('自拍镜像'),
              tr(settings.mirrorPreview ? '预览与成片均镜像' : '预览与成片均正常'),
              onTap: _editMirror,
            ),
            SettingsItem(
              Icons.high_quality_outlined,
              tr('默认画质'),
              settings.captureResolution.label,
              onTap: _editResolution,
            ),
            SettingsItem(
              Icons.photo_library_outlined,
              tr('存储位置'),
              tr('系统相册'),
              onTap: _showStorageInfo,
            ),
          ],
        ),
        SettingsSection(
          title: tr('隐私与识别'),
          children: [
            SettingsItem(
              Icons.offline_bolt_outlined,
              tr('语音识别'),
              tr('本地离线处理 · 中英文模型'),
              onTap: _showAsrInfo,
            ),
            SettingsItem(
              Icons.translate_outlined,
              tr('识别语言'),
              _recognitionLanguageLabel(settings.recognitionLanguage),
              onTap: _editRecognitionLanguage,
            ),
          ],
        ),
        SettingsSection(
          title: tr('关于'),
          children: [
            SettingsItem(
              Icons.info_outline,
              tr('关于镜词'),
              tr('本地优先的自拍视频提词器'),
              onTap: _showAbout,
            ),
          ],
        ),
        SettingsSection(
          title: tr('语言'),
          children: [
            SettingsItem(
              Icons.language_outlined,
              tr('语言'),
              settings.language == AppLanguage.english ? 'English' : '简体中文',
              onTap: _editLanguage,
            ),
          ],
        ),
        TextButton.icon(
          onPressed: _resetSettings,
          icon: const Icon(Icons.restore, size: 17),
          label: Text(tr('恢复默认设置')),
          style: TextButton.styleFrom(foregroundColor: _muted),
        ),
      ],
    ),
  );
}

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
  });
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(color: _muted, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Material(
          color: _panel,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ],
    ),
  );
}

class SettingsItem extends StatelessWidget {
  const SettingsItem(
    this.icon,
    this.label,
    this.value, {
    super.key,
    this.onTap,
  });
  final IconData icon;
  final String label, value;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    leading: Icon(icon, color: _cyan),
    title: Text(label),
    subtitle: Text(value, style: const TextStyle(color: _muted)),
    trailing: onTap == null
        ? null
        : const Icon(Icons.chevron_right, color: _muted),
  );
}
