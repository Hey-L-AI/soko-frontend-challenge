import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/resolved_search_location_provider.dart';

/// Powers the Discovery "Highlighted" shelf (PT-PT: "Em destaque") at the
/// top of the page (PROD-1554 → PROD-1986 → PROD-1999).
///
/// BE returns a marketing-curated ordered selection (1–10 cards) resolved
/// server-side via `city → country → hide`: it tries the per-city scope
/// first, falls back to the user's country scope if empty, otherwise
/// returns an empty array and the shelf hides itself. The FE slices to
/// the first 2 here so downstream consumers always get a uniform max-2
/// list. Order is preserved as returned.
///
/// Refetches automatically when the user's city changes — keyed on
/// `resolvedSearchLocationProvider`. Hides the shelf (empty list) when the city
/// can't be resolved. `location_source=picker` is sent for analytics; the
/// shelf is always driven by the picker.
final highlightedShelfProvider =
    FutureProvider.autoDispose<List<HighlightedCard>>((ref) async {
      final cityId = (await ref.watch(
        resolvedSearchLocationProvider.future,
      )).cityId;
      if (cityId == null) return const <HighlightedCard>[];

      try {
        final response = await ref
            .read(feedApiProvider)
            .getHighlightedFeed(cityId: cityId, locationSource: 'picker');
        return response.cards.take(2).toList();
      } on DioException catch (e) {
        final code = e.response?.statusCode;
        // 400 (Google-sourced city not yet supported) and 404 (unknown city)
        // both mean "no shelf for this user". Soft-fail to keep the rest of
        // the Discovery page rendering.
        if (code == 400 || code == 404) {
          debugPrint(
            '[Highlighted] cityId=$cityId returned $code — hiding shelf',
          );
          return const <HighlightedCard>[];
        }
        rethrow;
      }
    });
