import 'package:flutter/material.dart';

import '../../../data/models/area_prediction.dart';
import 'area_search_controller.dart';
import 'area_search_dropdown_flutter.dart'
    if (dart.library.js_interop) 'area_search_dropdown_web.dart';

/// Cross-platform search results for the map location picker.
///
/// Native targets use Flutter widgets. Web uses a real DOM listbox so the
/// options share the browser's platform-view layer with Mapbox instead of
/// relying on CanvasKit hit testing across an [HtmlElementView] boundary.
class AreaSearchDropdown extends StatelessWidget {
  const AreaSearchDropdown({
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
  /// Search key does. Null hides the "Load more results" row entirely.
  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context) => AreaSearchDropdownPlatform(
    controller: controller,
    onSelect: onSelect,
    onFocusChanged: onFocusChanged,
    searchFocusNode: searchFocusNode,
    onLoadMore: onLoadMore,
  );
}
