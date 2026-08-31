import '../domain/script_models.dart';

abstract interface class SettingsRepository {
  Future<AppSettings> loadSettings();
  Future<void> saveSettings(AppSettings settings);
}
