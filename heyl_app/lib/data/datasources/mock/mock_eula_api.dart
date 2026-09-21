import '../../../core/constants/eula_version.dart';
import '../../models/eula.dart';
import '../interfaces/eula_api.dart';

/// In-memory mock of [IEulaApi] for offline/test runs.
class MockEulaApi implements IEulaApi {
  EulaAcceptance? _acceptance;

  @override
  Future<EulaAcceptance> accept(EulaAcceptRequest request) async {
    _acceptance = EulaAcceptance(
      id: 'mock-eula-acceptance-id',
      userId: 'mock-user-id',
      eulaVersion: request.eulaVersion,
      acceptedAt: DateTime.now().toUtc(),
      locale: request.locale,
      source: EulaAcceptanceSource.signup,
    );
    return _acceptance!;
  }

  @override
  Future<EulaStatus> status() async {
    return EulaStatus(
      currentVersion: kCurrentEulaVersion,
      acceptedVersion: _acceptance?.eulaVersion,
      acceptedAt: _acceptance?.acceptedAt,
      needsAcceptance:
          _acceptance == null ||
          _acceptance!.eulaVersion != kCurrentEulaVersion,
    );
  }
}
