import '../../models/eula.dart';

/// EULA acceptance API (PROD-2264).
abstract class IEulaApi {
  /// Record an EULA acceptance for the current user. Idempotent — re-accepting
  /// the same version returns the existing row instead of creating a duplicate.
  Future<EulaAcceptance> accept(EulaAcceptRequest request);

  /// Return the server's authoritative current EULA version, the version (if
  /// any) the user has previously accepted, and a `needsAcceptance` flag the
  /// client uses to decide whether to (re-)prompt.
  Future<EulaStatus> status();
}
