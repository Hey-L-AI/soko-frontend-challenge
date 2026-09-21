import 'package:flutter/material.dart';

import '../../../data/models/area_prediction.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/soko_load_more_row.dart';
import 'area_search_controller.dart';

/// Flutter implementation used by iOS, Android, and widget tests.
class AreaSearchDropdownPlatform extends StatelessWidget {
  const AreaSearchDropdownPlatform({
    super.key,
    required this.controller,
    required this.onSelect,
    this.onFocusChanged,
    this.searchFocusNode,
    this.onLoadMore,
  });

  final AreaSearchController controller;
  final ValueChanged<AreaPrediction> onSelect;
  final ValueChanged<bool>? onFocusChanged;
  final FocusNode? searchFocusNode;

  /// Runs the deeper `POST /geo/search` tier — the same thing the keyboard's
  /// Search key does. Null hides the row entirely.
  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (controller.loading) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        if (controller.error != null) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l10n.mapLocationSearchError),
          );
        }
        final showLoadMore = onLoadMore != null && controller.canLoadMore;
        if (controller.results.isEmpty) {
          // No local matches is precisely when the deep tier is worth offering
          // — a city absent from our DB is what it exists to find. The
          // no-matches message is only the truth once that tier is spent.
          if (showLoadMore) {
            return SokoLoadMoreRow(
              label: l10n.mapLocationSearchLoadMore,
              onTap: onLoadMore!,
            );
          }
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l10n.mapLocationSearchNoMatches),
          );
        }
        final itemCount = controller.results.length + (showLoadMore ? 1 : 0);
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: ListView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: itemCount,
            itemBuilder: (context, index) {
              if (showLoadMore && index == controller.results.length) {
                return SokoLoadMoreRow(
                  label: l10n.mapLocationSearchLoadMore,
                  onTap: onLoadMore!,
                );
              }
              final prediction = controller.results[index];
              return ListTile(
                title: Text(
                  prediction.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: prediction.secondaryText.isEmpty
                    ? null
                    : Text(
                        prediction.secondaryText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                onTap: () => onSelect(prediction),
              );
            },
          ),
        );
      },
    );
  }
}
