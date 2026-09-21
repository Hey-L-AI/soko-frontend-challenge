import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'klaviyo_service_stub.dart'
    if (dart.library.io) 'klaviyo_service_mobile.dart';

export 'klaviyo_service_stub.dart'
    if (dart.library.io) 'klaviyo_service_mobile.dart';

final KlaviyoService _klaviyoService = KlaviyoService();

final klaviyoServiceProvider = Provider<KlaviyoService>((ref) {
  return _klaviyoService;
});

Future<void> initializeKlaviyo() => _klaviyoService.initialize();
