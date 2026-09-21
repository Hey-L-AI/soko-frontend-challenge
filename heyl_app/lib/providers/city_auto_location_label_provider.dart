import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/lists/models/search_scope.dart';
import 'city_auto_scope_provider.dart';

/// Auto-detected location label for the action bar's location pill
/// (e.g. `"Lisboa, PT"`).
///
/// Derives from [cityAutoScopeProvider] (the single source of truth for
/// auto-resolution). Returns `null` when auto-resolution didn't succeed —
/// the pill falls back to the localized "Location" string.
final cityAutoLocationLabelProvider = FutureProvider<String?>((ref) async {
  final scope = await ref.watch(cityAutoScopeProvider.future);
  if (scope is SearchScopeCountryCity) {
    return '${scope.city.name}, ${scope.iso2}';
  }
  if (scope is SearchScopeCountry) {
    return scope.iso2;
  }
  return null;
});
