import '../domain/script_models.dart';

abstract interface class SessionRecoveryRepository {
  Future<CaptureRecovery?> loadActiveRecovery();
  Future<void> saveRecovery(CaptureRecovery recovery);
  Future<void> clearRecovery();
}
