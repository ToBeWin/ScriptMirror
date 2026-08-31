import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../domain/script_models.dart';
import 'script_repository.dart';
import 'session_recovery_repository.dart';
import 'settings_repository.dart';

/// SQLite-backed script storage. The schema keeps lines separate so reorder,
/// split and merge operations do not require reparsing the whole document.
class SqliteScriptRepository
    implements ScriptRepository, SettingsRepository, SessionRecoveryRepository {
  SqliteScriptRepository({String databaseName = 'scriptmirror.db'})
    : _databaseName = databaseName;

  final String _databaseName;
  Database? _database;
  Future<Database>? _openingDatabase;

  Future<Database> get database async {
    final existing = _database;
    if (existing != null) return existing;
    final opening = _openingDatabase;
    if (opening != null) return opening;
    final future = _openDatabase();
    _openingDatabase = future;
    try {
      final opened = await future;
      _database = opened;
      return opened;
    } finally {
      if (identical(_openingDatabase, future)) _openingDatabase = null;
    }
  }

  Future<Database> _openDatabase() async {
    final root = await getDatabasesPath();
    final opened = await openDatabase(
      p.join(root, _databaseName),
      version: 5,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE scripts (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE script_lines (
            id TEXT NOT NULL,
            script_id TEXT NOT NULL,
            line_order INTEGER NOT NULL,
            text TEXT NOT NULL,
            expected_duration_ms INTEGER NOT NULL,
            pause_after_ms INTEGER NOT NULL,
            keywords TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (script_id, id),
            FOREIGN KEY (script_id) REFERENCES scripts(id) ON DELETE CASCADE
          )
        ''');
        await db.execute(
          'CREATE INDEX script_lines_script_order ON script_lines(script_id, line_order)',
        );
        await _createSettingsTable(db);
        await _createRecoveryTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _createSettingsTable(db);
        if (oldVersion < 3) await _createRecoveryTable(db);
        if (oldVersion < 4) await _ensureKeywordsColumn(db);
        if (oldVersion < 5) await _migrateScriptLinesToCompositeKey(db);
      },
      onOpen: (db) async {
        await _createSettingsTable(db);
        await _createRecoveryTable(db);
        // Keep upgrades resilient if a development build wrote an older
        // schema version before the formal migration was added.
        await _ensureKeywordsColumn(db);
      },
    );
    return opened;
  }

  @override
  Future<List<Script>> list() async {
    final db = await database;
    final rows = await db.query('scripts', orderBy: 'updated_at DESC');
    return Future.wait(rows.map(_readScript));
  }

  @override
  Future<Script?> getById(String id) async {
    final db = await database;
    final rows = await db.query(
      'scripts',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _readScript(rows.first);
  }

  Future<Script> _readScript(Map<String, Object?> row) async {
    final db = await database;
    final lineRows = await db.query(
      'script_lines',
      where: 'script_id = ?',
      whereArgs: [row['id']],
      orderBy: 'line_order ASC',
    );
    return Script(
      id: row['id']! as String,
      title: row['title']! as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at']! as int),
      lines: lineRows
          .map(
            (line) => ScriptLine(
              id: line['id']! as String,
              order: line['line_order']! as int,
              text: line['text']! as String,
              expectedDurationMs: line['expected_duration_ms']! as int,
              pauseAfterMs: line['pause_after_ms']! as int,
              keywords: (line['keywords']! as String)
                  .split('|')
                  .where((keyword) => keyword.isNotEmpty)
                  .toList(growable: false),
            ),
          )
          .toList(),
    );
  }

  @override
  Future<void> save(Script script) async {
    final db = await database;
    final now = DateTime.now();
    script.updatedAt = now;
    await db.transaction((txn) async {
      await txn.insert('scripts', <String, Object?>{
        'id': script.id,
        'title': script.title,
        'created_at': script.createdAt.millisecondsSinceEpoch,
        'updated_at': script.updatedAt.millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete(
        'script_lines',
        where: 'script_id = ?',
        whereArgs: [script.id],
      );
      final batch = txn.batch();
      for (final line in script.lines) {
        batch.insert('script_lines', <String, Object?>{
          'id': line.id,
          'script_id': script.id,
          'line_order': line.order,
          'text': line.text,
          'expected_duration_ms': line.expectedDurationMs,
          'pause_after_ms': line.pauseAfterMs,
          'keywords': line.keywords.join('|'),
        });
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<void> delete(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('script_lines', where: 'script_id = ?', whereArgs: [id]);
      await txn.delete('scripts', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> close() async {
    final db = _database;
    _database = null;
    await db?.close();
  }

  @override
  Future<AppSettings> loadSettings() async {
    final db = await database;
    final rows = await db.query('app_settings');
    final values = <String, String>{
      for (final row in rows) row['key']! as String: row['value']! as String,
    };
    final defaults = const AppSettings();
    return defaults
        .copyWith(
          fontSize: _readDouble(values['fontSize'], defaults.fontSize),
          backgroundOpacity: _readDouble(
            values['backgroundOpacity'],
            defaults.backgroundOpacity,
          ),
          lookaheadLines: _readInt(
            values['lookaheadLines'],
            defaults.lookaheadLines,
          ),
          lineHeight: _readDouble(values['lineHeight'], defaults.lineHeight),
          mirrorPreview: _readBool(
            values['mirrorPreview'],
            defaults.mirrorPreview,
          ),
          captureResolution: CaptureResolution.fromName(
            values['captureResolution'],
          ),
        )
        .normalized();
  }

  @override
  Future<void> saveSettings(AppSettings settings) async {
    final db = await database;
    settings = settings.normalized();
    final batch = db.batch();
    final values = <String, String>{
      'fontSize': settings.fontSize.toString(),
      'backgroundOpacity': settings.backgroundOpacity.toString(),
      'lookaheadLines': settings.lookaheadLines.toString(),
      'lineHeight': settings.lineHeight.toString(),
      'mirrorPreview': settings.mirrorPreview.toString(),
      'captureResolution': settings.captureResolution.name,
    };
    for (final entry in values.entries) {
      batch.insert('app_settings', <String, Object?>{
        'key': entry.key,
        'value': entry.value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<CaptureRecovery?> loadActiveRecovery() async {
    final db = await database;
    final rows = await db.query('capture_recovery', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return CaptureRecovery(
      scriptId: row['script_id']! as String,
      currentLineIndex: row['current_line_index']! as int,
      startedAtMs: row['started_at_ms']! as int,
      mediaUri: row['media_uri'] as String?,
      state: row['state'] == RecoveryState.stopping.name
          ? RecoveryState.stopping
          : RecoveryState.recording,
    );
  }

  @override
  Future<void> saveRecovery(CaptureRecovery recovery) async {
    final db = await database;
    await db.insert('capture_recovery', <String, Object?>{
      'id': 1,
      'script_id': recovery.scriptId,
      'current_line_index': recovery.currentLineIndex,
      'started_at_ms': recovery.startedAtMs,
      'media_uri': recovery.mediaUri,
      'state': recovery.state.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> clearRecovery() async {
    final db = await database;
    await db.delete('capture_recovery', where: 'id = 1');
  }

  static Future<void> _createSettingsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _createRecoveryTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS capture_recovery (
        id INTEGER PRIMARY KEY,
        script_id TEXT NOT NULL,
        current_line_index INTEGER NOT NULL,
        started_at_ms INTEGER NOT NULL,
        media_uri TEXT,
        state TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _ensureKeywordsColumn(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(script_lines)');
    final hasKeywords = columns.any((column) => column['name'] == 'keywords');
    if (hasKeywords) return;
    await db.execute(
      "ALTER TABLE script_lines ADD COLUMN keywords TEXT NOT NULL DEFAULT ''",
    );
  }

  /// Older builds made `script_lines.id` a global primary key even though a
  /// line id is only meaningful inside its parent script. The parser starts
  /// each document at `line-1`, so that schema rejected a second newly-created
  /// script. Rebuild the small table with a composite key while preserving all
  /// existing rows and their logical ids.
  static Future<void> _migrateScriptLinesToCompositeKey(Database db) async {
    await db.execute('''
      CREATE TABLE script_lines_v5 (
        id TEXT NOT NULL,
        script_id TEXT NOT NULL,
        line_order INTEGER NOT NULL,
        text TEXT NOT NULL,
        expected_duration_ms INTEGER NOT NULL,
        pause_after_ms INTEGER NOT NULL,
        keywords TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (script_id, id),
        FOREIGN KEY (script_id) REFERENCES scripts(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      INSERT INTO script_lines_v5 (
        id,
        script_id,
        line_order,
        text,
        expected_duration_ms,
        pause_after_ms,
        keywords
      )
      SELECT
        id,
        script_id,
        line_order,
        text,
        expected_duration_ms,
        pause_after_ms,
        COALESCE(keywords, '')
      FROM script_lines
    ''');
    await db.execute('DROP TABLE script_lines');
    await db.execute('ALTER TABLE script_lines_v5 RENAME TO script_lines');
    await db.execute(
      'CREATE INDEX script_lines_script_order ON script_lines(script_id, line_order)',
    );
  }

  static double _readDouble(String? value, double fallback) {
    final parsed = double.tryParse(value ?? '');
    return parsed == null || !parsed.isFinite ? fallback : parsed;
  }

  static int _readInt(String? value, int fallback) {
    final parsed = int.tryParse(value ?? '');
    return parsed ?? fallback;
  }

  static bool _readBool(String? value, bool fallback) {
    if (value == 'true') return true;
    if (value == 'false') return false;
    return fallback;
  }
}
