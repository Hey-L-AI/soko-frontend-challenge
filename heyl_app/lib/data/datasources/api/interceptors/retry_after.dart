import 'package:dio/dio.dart';

/// Parses the `Retry-After` **delta-seconds** header off a Dio [Response].
///
/// Shared by [RetryInterceptor] (which must NOT hammer the server when it has
/// asked for a wait — PROD-4369 / PROD-4321) and [ErrorInterceptor] (which
/// surfaces the value on typed exceptions so the UI can gate its manual Retry).
///
/// Returns `null` when the header is absent or not a plain integer. The backend
/// only ever sends the delta-seconds form here (`Retry-After: 5` on the pool
/// shed, `2` on the admission bound — see the `PoolSaturated` response in
/// `heyl-webapp-v1.openapi.yaml`), so the HTTP-date form is intentionally not
/// parsed: treating an unparseable value as "no wait" is safe (the caller falls
/// back to its own floor), whereas guessing a date would be worse than nothing.
///
/// A negative value is clamped to `null` — a past "wait until" is not a wait.
int? retryAfterSeconds(Response? response) {
  final raw = response?.headers.value('retry-after');
  if (raw == null) return null;
  final seconds = int.tryParse(raw.trim());
  if (seconds == null || seconds < 0) return null;
  return seconds;
}
