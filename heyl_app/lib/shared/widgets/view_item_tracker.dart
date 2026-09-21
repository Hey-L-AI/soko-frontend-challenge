import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/backend_analytics_service.dart' show OriginSource;
import '../../core/services/unified_analytics_service.dart';

/// Fires a single `view_item` analytics event when the wrapped item-detail
/// content is shown, then renders [child] unchanged.
///
/// Place this **inside the detail body** (the widget mounted only when the
/// user sees an item's full detail) so the event travels with the content to
/// every host — the full-screen detail route, the in-list detail screen, and
/// the map pin-tap sheet — without each host re-implementing tracking. It
/// must NOT wrap list cards / shelf tiles: a `view_item` is a detail view, not
/// an impression.
///
/// Fires once on mount, and again if [itemId] changes in place (e.g.
/// sibling-swipe reusing the same element).
class ViewItemTracker extends ConsumerStatefulWidget {
  /// The item's id.
  final String itemId;

  /// `'place'` or `'event'` — matches the analytics contract's `item_type`.
  final String itemType;

  /// Where the view originated (an `OriginSource` string constant). Detail
  /// surfaces use [OriginSource.detailView].
  final String source;

  final Widget child;

  const ViewItemTracker({
    super.key,
    required this.itemId,
    required this.itemType,
    this.source = OriginSource.detailView,
    required this.child,
  });

  @override
  ConsumerState<ViewItemTracker> createState() => _ViewItemTrackerState();
}

class _ViewItemTrackerState extends ConsumerState<ViewItemTracker> {
  @override
  void initState() {
    super.initState();
    _track();
  }

  @override
  void didUpdateWidget(ViewItemTracker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-fire when the same tracker element is reused for a different item
    // (e.g. horizontal sibling swipe on the full-screen detail).
    if (oldWidget.itemId != widget.itemId) _track();
  }

  void _track() {
    final itemId = widget.itemId;
    if (itemId.isEmpty) return;
    // Post-frame so tracking never runs during the first build pass.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(unifiedAnalyticsProvider)
          .trackViewItem(
            itemId: itemId,
            itemType: widget.itemType,
            source: widget.source,
          );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
