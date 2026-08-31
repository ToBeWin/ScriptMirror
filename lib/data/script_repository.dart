import '../domain/script_models.dart';

abstract interface class ScriptRepository {
  Future<List<Script>> list();
  Future<Script?> getById(String id);
  Future<void> save(Script script);
  Future<void> delete(String id);
}

/// Lightweight repository for tests and non-persistent previews. It keeps the
/// same boundary as the SQLite implementation without requiring a platform
/// database plugin.
class InMemoryScriptRepository implements ScriptRepository {
  InMemoryScriptRepository([Iterable<Script>? initial])
    : _scripts = <String, Script>{
        for (final script in initial ?? const <Script>[]) script.id: script,
      };

  final Map<String, Script> _scripts;

  @override
  Future<List<Script>> list() async => _scripts.values.toList(growable: false);

  @override
  Future<Script?> getById(String id) async => _scripts[id];

  @override
  Future<void> save(Script script) async {
    script.updatedAt = DateTime.now();
    _scripts[script.id] = script;
  }

  @override
  Future<void> delete(String id) async => _scripts.remove(id);
}
