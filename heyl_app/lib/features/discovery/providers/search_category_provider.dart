import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Active category in the Discovery action bar's search panel. Backs the
/// `Bt_Sq_Ico` tab row (Eventos / Sítios / Zines / Leitores).
///
/// PROD-2026 added [all] as an opt-in fourth value used by the
/// `/yours` hub search — it renders zines, events, and places together
/// in stacked sections. Discovery's surfaces do not expose this value
/// (the shared [SearchCategoryTabs] widget gates it via `includeAll`);
/// downstream switches still must remain exhaustive, so they fall
/// back to the zines branch for `all` defensively.
///
/// [leitores] (people/readers) supersedes the previously-skipped Membros
/// tab (D54): Discovery-only, exposed via the overlay's `categoryOrder`.
/// It renders people rows through `ReadersSearchSection`, NOT the 2-up
/// grid — `discoverySearchResultsProvider` treats it as empty, and the
/// `/yours` hub never offers it.
enum DiscoverySearchCategory { all, zines, eventos, sitios, leitores }

// Discovery's "Discover the city" search defaults to Events — it's the
// primary discovery surface and the only category that exposes filters
// (time range + categories). The `/yours` hub forks its own
// `listsSearchCategoryProvider`, so this default doesn't affect Lists.
final searchCategoryProvider = StateProvider<DiscoverySearchCategory>(
  (ref) => DiscoverySearchCategory.eventos,
);
