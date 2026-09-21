// PROD unified-search — the feed's Procura results: the shared grouped list,
// narrowed by the toggle chips.
//
// The input + chips live in the morphing `FeedProcuraRow`; this widget is only
// the results. It reads the feed's query + (nullable) category filter and hands
// them to the shared [UnifiedContentResultsView] — so the feed, library and
// onboarding render byte-for-byte the same grouped results. Guest wall on.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/widgets/search/unified_content_results_view.dart';
import '../../../../shared/widgets/search/unified_search_models.dart';
import '../../providers/search_category_provider.dart';
import '../providers/procura_search_providers.dart';

/// The unified [SokoSearchCategory] a feed chip maps to, or null for the unused
/// `all`.
SokoSearchCategory? sokoCategoryForFeedFilter(DiscoverySearchCategory? c) =>
    switch (c) {
      DiscoverySearchCategory.eventos => SokoSearchCategory.events,
      DiscoverySearchCategory.sitios => SokoSearchCategory.venues,
      DiscoverySearchCategory.zines => SokoSearchCategory.zines,
      DiscoverySearchCategory.leitores => SokoSearchCategory.people,
      DiscoverySearchCategory.all || null => null,
    };

class FeedProcuraResults extends ConsumerWidget {
  const FeedProcuraResults({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final category = ref.watch(procuraSearchCategoryProvider);
    final query = ref.watch(procuraSearchQueryProvider).trim();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: UnifiedContentResultsView(
        query: query,
        selectedCategory: sokoCategoryForFeedFilter(category),
        guestWall: true,
      ),
    );
  }
}
