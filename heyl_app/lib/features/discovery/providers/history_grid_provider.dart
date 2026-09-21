import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/entity_ref.dart';
import '../../../providers/api_provider.dart';

/// Powers the Discovery History grid — a 2×3 compact grid of recent
/// activity items (PROD-1521 / PROD-1514). The endpoint caps at 20 server
/// side; the grid only renders 6 cells, so we fetch exactly that.
///
/// Server-side hydration filters out deleted/inactive entities, so the
/// returned list may be shorter than 6. An empty list (HTTP 200) means
/// "no recent activity" — render nothing.
final historyGridProvider = FutureProvider.autoDispose<List<EntityRef>>((
  ref,
) async {
  final api = ref.watch(userActivityApiProvider);
  final response = await api.getMyActivity(limit: 6);
  return response.items;
});
