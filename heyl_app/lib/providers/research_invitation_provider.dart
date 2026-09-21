import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/datasources/api/research_invitations_api.dart';
import 'api_provider.dart';
import 'auth_provider.dart';

/// Keep writes alive when the feed unmounts, but never across account changes.
/// No status cache: each new invitation visit reads fresh server authority.
final researchInvitationsApiProvider = Provider<ResearchInvitationsApi>((ref) {
  final api = ResearchInvitationsApi(
    dio: ref.watch(apiClientProvider).dio,
    currentAccountId: () => ref.read(currentUserProvider)?.id,
  );
  ref.listen(currentUserProvider.select((user) => user?.id), (previous, next) {
    if (previous != next) api.cancelPending();
  });
  ref.onDispose(api.cancelPending);
  return api;
});
