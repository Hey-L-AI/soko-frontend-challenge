import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../../../core/theme/app_colors.dart';
import '../../../data/models/area_prediction.dart';
import '../../../l10n/generated/l10n.dart';
import 'area_search_controller.dart';

/// Browser-native implementation used on Flutter Web.
///
/// Mapbox is itself an [HtmlElementView]. Keeping the options in the same DOM
/// composition layer avoids Flutter's platform-view overlay hit-test bug and
/// gives the list native focus, arrow-key, and activation behavior.
class AreaSearchDropdownPlatform extends StatefulWidget {
  const AreaSearchDropdownPlatform({
    super.key,
    required this.controller,
    required this.onSelect,
    this.onFocusChanged,
    this.searchFocusNode,
    this.onLoadMore,
    this.debugRoot,
  });

  final AreaSearchController controller;
  final ValueChanged<AreaPrediction> onSelect;
  final ValueChanged<bool>? onFocusChanged;
  final FocusNode? searchFocusNode;

  /// Runs the deeper `POST /geo/search` tier — the same thing the keyboard's
  /// Search key does. Null hides the row entirely.
  final VoidCallback? onLoadMore;

  /// Lets browser widget tests exercise the DOM bridge even though Flutter's
  /// test binding does not attach platform-view elements.
  @visibleForTesting
  final web.HTMLDivElement? debugRoot;

  @override
  State<AreaSearchDropdownPlatform> createState() =>
      _AreaSearchDropdownPlatformState();
}

class _AreaSearchDropdownPlatformState
    extends State<AreaSearchDropdownPlatform> {
  static const double _maxHeight = 280;
  static const double _messageHeight = 56;
  static const double _singleLineRowHeight = 56;
  static const double _twoLineRowHeight = 72;
  static const double _loadMoreRowHeight = 48;
  static const String _focusRequestEvent = 'heyl-area-search-focus-request';

  final Key _platformViewKey = UniqueKey();
  late final JSFunction _nativeFocusRequestListener;
  web.HTMLDivElement? _root;
  List<web.HTMLButtonElement> _buttons = const [];
  int _activeIndex = 0;

  @override
  void initState() {
    super.initState();
    _nativeFocusRequestListener =
        ((web.Event event) => _handleNativeFocusRequest(event)).toJS;
    widget.controller.addListener(_handleControllerChanged);
    _root = widget.debugRoot;
    if (_root != null) _configureRoot(_root!);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _renderDom();
  }

  @override
  void didUpdateWidget(AreaSearchDropdownPlatform oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Do not recreate the buttons for callback/focus-state-only parent
    // rebuilds. Replacing the focused DOM node immediately blurs it, which
    // collapses the dropdown during Tab or arrow-key traversal.
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
      _activeIndex = 0;
      _renderDom();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _root?.removeEventListener(_focusRequestEvent, _nativeFocusRequestListener);
    _root?.replaceChildren(<JSAny>[].toJS);
    _buttons = const [];
    _root = null;
    super.dispose();
  }

  /// Whether the "Load more results" row is part of the current render. Read
  /// by height, DOM build, and keyboard bounds so those three can never
  /// disagree about how many rows exist.
  bool get _showLoadMore =>
      widget.onLoadMore != null &&
      widget.controller.error == null &&
      !widget.controller.loading &&
      widget.controller.canLoadMore;

  /// Total focusable rows — results plus the optional load-more row.
  int get _rowCount =>
      widget.controller.results.length + (_showLoadMore ? 1 : 0);

  void _handleControllerChanged() {
    if (!mounted) return;
    final lastIndex = _rowCount - 1;
    if (lastIndex < 0) {
      _activeIndex = 0;
    } else {
      _activeIndex = _activeIndex.clamp(0, lastIndex);
    }
    setState(() {});
    _renderDom();
  }

  void _handleNativeFocusRequest(web.Event _) {
    if (!mounted || _buttons.isEmpty) return;
    final requestedIndex = int.tryParse(
      _root?.getAttribute('data-native-focus-index') ?? '',
    );
    if (requestedIndex == null ||
        requestedIndex < 0 ||
        requestedIndex >= _buttons.length) {
      return;
    }

    // The DOM button cannot take focus while Flutter still considers the
    // TextField its primary focus. Keep the dropdown mounted and release the
    // Flutter focus node. The pre-boot browser handler focuses the option on
    // the next animation frame, after this focus-tree update has been applied.
    widget.onFocusChanged?.call(true);
    widget.searchFocusNode?.unfocus();
  }

  double get _height {
    final controller = widget.controller;
    if (controller.loading || controller.error != null) return _messageHeight;
    if (controller.results.isEmpty) {
      // Either the load-more row stands alone in place of the no-matches
      // message, or the message does.
      return _showLoadMore ? _loadMoreRowHeight : _messageHeight;
    }
    final contentHeight = controller.results.fold<double>(0, (height, result) {
      return height +
          (result.secondaryText.isEmpty
              ? _singleLineRowHeight
              : _twoLineRowHeight);
    });
    return math.min(
      _maxHeight,
      contentHeight + (_showLoadMore ? _loadMoreRowHeight : 0),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _height,
      width: double.infinity,
      child: HtmlElementView.fromTagName(
        key: _platformViewKey,
        tagName: 'div',
        onElementCreated: (element) {
          _root = element as web.HTMLDivElement;
          _configureRoot(_root!);
          _renderDom();
        },
      ),
    );
  }

  void _configureRoot(web.HTMLDivElement root) {
    root
      ..className = 'heyl-area-search-results'
      ..setAttribute('data-testid', 'area-search-results');
    root.style
      ..width = '100%'
      ..height = '100%'
      ..boxSizing = 'border-box'
      ..overflowX = 'hidden'
      ..overflowY = 'auto'
      ..borderRadius = '0 0 12px 12px'
      ..fontFamily = 'ZalandoSans, Arial, sans-serif'
      ..pointerEvents = 'auto';
    // iOS Safari treats a tap inside a scrollable/composited container as a
    // possible scroll and can swallow the option's activation. Declaring the
    // container tap-first stops that disambiguation from eating the tap.
    root.style.setProperty('touch-action', 'manipulation');
    root.addEventListener(_focusRequestEvent, _nativeFocusRequestListener);
  }

  void _renderDom() {
    final root = _root;
    if (root == null || !mounted) return;

    final theme = Theme.of(context);
    final l10n = Lt.of(context);
    final surface = _cssColor(theme.colorScheme.surface);
    final foreground = _cssColor(theme.colorScheme.onSurface);
    final muted = _cssColor(
      theme.textTheme.bodySmall?.color ??
          theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    final focus = _cssColor(theme.colorScheme.primary.withValues(alpha: 0.12));
    final divider = _cssColor(theme.dividerColor.withValues(alpha: 0.45));

    root.style
      ..backgroundColor = surface
      ..color = foreground;
    root.replaceChildren(<JSAny>[].toJS);
    _buttons = const [];

    final style = web.HTMLStyleElement()
      ..textContent =
          '''
        /* Heights are EXPLICIT, not min-height, and are interpolated from the
           same constants `_height` reserves. The platform view is sized by
           Flutter from those constants, so any row whose CSS renders shorter
           leaves the root's surface showing as a white strip under the last
           row. A two-line row is 20+3+18 content + 20 padding = 61px, which is
           11px under the 72 reserved — that gap was the bug. Both spans are
           `nowrap` + ellipsis, so a fixed height can never clip wrapped text. */
        .heyl-area-option {
          appearance: none;
          width: 100%;
          height: ${_singleLineRowHeight.toInt()}px;
          box-sizing: border-box;
          display: flex;
          flex-direction: column;
          justify-content: center;
          align-items: stretch;
          gap: 3px;
          padding: 10px 16px;
          border: 0;
          border-bottom: 1px solid $divider;
          background: $surface;
          color: $foreground;
          font: inherit;
          text-align: left;
          cursor: pointer;
          /* iOS Safari: treat the row as a tap target (no double-tap zoom /
             scroll disambiguation delay) and drop the grey flash. */
          touch-action: manipulation;
          -webkit-tap-highlight-color: transparent;
        }
        .heyl-area-option--two-line {
          height: ${_twoLineRowHeight.toInt()}px;
        }
        .heyl-area-option:last-child { border-bottom: 0; }
        .heyl-area-option:hover,
        .heyl-area-option:focus-visible {
          background: $focus;
          outline: 2px solid ${_cssColor(theme.colorScheme.primary)};
          outline-offset: -2px;
        }
        .heyl-area-option-name {
          overflow: hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
          font-size: 16px;
          line-height: 20px;
          font-weight: 400;
        }
        .heyl-area-option-secondary {
          overflow: hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
          color: $muted;
          font-size: 14px;
          line-height: 18px;
          font-weight: 400;
        }
        .heyl-area-load-more {
          background: ${_cssColor(AppColors.sokoShade5)};
          color: ${_cssColor(AppColors.sokoInk)};
          height: ${_loadMoreRowHeight.toInt()}px;
          flex-direction: row;
          align-items: center;
          font-size: 15px;
          font-weight: 600;
          border-bottom: 0;
        }
        .heyl-area-load-more:hover,
        .heyl-area-load-more:focus-visible {
          background: ${_cssColor(AppColors.sokoShade45)};
        }
        .heyl-area-message {
          height: ${_messageHeight.toInt()}px;
          box-sizing: border-box;
          display: flex;
          align-items: center;
          justify-content: center;
          padding: 16px;
          color: $foreground;
          font-size: 14px;
          line-height: 20px;
        }
        .heyl-area-spinner {
          width: 20px;
          height: 20px;
          box-sizing: border-box;
          border: 2px solid $divider;
          border-top-color: ${_cssColor(theme.colorScheme.primary)};
          border-radius: 50%;
          animation: heyl-area-spin 0.8s linear infinite;
        }
        @keyframes heyl-area-spin { to { transform: rotate(360deg); } }
        @media (prefers-reduced-motion: reduce) {
          .heyl-area-spinner { animation: none; }
        }
      ''';
    root.append(style);

    final controller = widget.controller;
    if (controller.loading) {
      root
        ..setAttribute('role', 'status')
        ..setAttribute('aria-label', l10n.mapLocationSearchHint);
      final message = web.HTMLDivElement()..className = 'heyl-area-message';
      message.append(web.HTMLDivElement()..className = 'heyl-area-spinner');
      root.append(message);
      return;
    }

    if (controller.error == null && controller.results.isEmpty) {
      // No local matches is precisely when the deep tier is worth offering —
      // a city absent from our DB is what it exists to find. The no-matches
      // message is only the truth once that tier is spent.
      if (_showLoadMore) {
        root
          ..setAttribute('role', 'listbox')
          ..setAttribute('aria-label', l10n.mapLocationSearchHint);
        final only = _buildLoadMoreButton(l10n, 0);
        _buttons = [only];
        root.append(only);
        return;
      }
    }

    if (controller.error != null || controller.results.isEmpty) {
      root.setAttribute('role', 'status');
      final message = web.HTMLDivElement()
        ..className = 'heyl-area-message'
        ..textContent = controller.error != null
            ? l10n.mapLocationSearchError
            : l10n.mapLocationSearchNoMatches;
      root.append(message);
      return;
    }

    root
      ..setAttribute('role', 'listbox')
      ..setAttribute('aria-label', l10n.mapLocationSearchHint);

    final buttons = <web.HTMLButtonElement>[];
    _buttons = buttons;
    for (var index = 0; index < controller.results.length; index++) {
      final prediction = controller.results[index];
      final button = web.HTMLButtonElement()
        ..type = 'button'
        ..className = prediction.secondaryText.isEmpty
            ? 'heyl-area-option'
            : 'heyl-area-option heyl-area-option--two-line'
        ..tabIndex = index == _activeIndex ? 0 : -1
        ..setAttribute('role', 'option')
        ..setAttribute('aria-selected', '${index == _activeIndex}')
        ..setAttribute('data-area-index', '$index')
        ..setAttribute('data-area-id', prediction.id);

      button.append(
        web.HTMLSpanElement()
          ..className = 'heyl-area-option-name'
          ..textContent = prediction.name,
      );
      if (prediction.secondaryText.isNotEmpty) {
        button.append(
          web.HTMLSpanElement()
            ..className = 'heyl-area-option-secondary'
            ..textContent = prediction.secondaryText,
        );
      }

      // First event to arrive wins; the rest are no-ops. This lets the fastest
      // available signal select the row without ever double-firing onSelect.
      var activated = false;
      void activate(web.Event event) {
        if (activated) return;
        activated = true;
        event.preventDefault();
        event.stopPropagation();
        // A tap selects on pointerdown/touchend, which unmounts this dropdown
        // before iOS Safari dispatches its delayed synthetic `click`. With the
        // row gone, Safari retargets that click to whatever is now topmost at
        // the point — the Mapbox canvas underneath — registering a stray map
        // tap. Neutralize that one orphaned click. A real `click` activation
        // (keyboard/AT) has no such follow-up, so skip it there.
        if (event.type != 'click') _swallowStrayMapClick();
        if (mounted) widget.onSelect(prediction);
      }

      // Desktop/mouse: pointerdown fires first, before Flutter can unmount this
      // platform view on the TextField blur.
      button.addEventListener(
        'pointerdown',
        ((web.Event event) => activate(event)).toJS,
      );
      // iOS Safari: inside a scrollable/composited container the browser can
      // withhold pointerdown/click while it disambiguates tap-vs-scroll, but
      // touchend still fires on a clean tap — so it's the reliable path there.
      button.addEventListener(
        'touchend',
        ((web.Event event) => activate(event)).toJS,
      );
      // Keyboard/AT/programmatic activation fallback.
      button.addEventListener(
        'click',
        ((web.Event event) => activate(event)).toJS,
      );
      button.addEventListener(
        'focus',
        ((web.Event _) {
          widget.onFocusChanged?.call(true);
          _setActiveOption(index, buttons);
        }).toJS,
      );
      button.addEventListener(
        'blur',
        ((web.Event _) {
          Future<void>.delayed(Duration.zero, () {
            if (!mounted) return;
            final active = web.document.activeElement;
            if (active == null || !root.contains(active)) {
              widget.onFocusChanged?.call(false);
            }
          });
        }).toJS,
      );
      button.addEventListener(
        'keydown',
        ((web.KeyboardEvent event) {
          if (event.key == 'Enter' || event.key == ' ') {
            event.preventDefault();
            event.stopPropagation();
            if (mounted) widget.onSelect(prediction);
            return;
          }
          final targetIndex = switch (event.key) {
            'ArrowDown' => math.min(index + 1, _rowCount - 1),
            'ArrowUp' => math.max(index - 1, 0),
            'Home' => 0,
            'End' => _rowCount - 1,
            _ => null,
          };
          if (targetIndex == null) return;
          event.preventDefault();
          event.stopPropagation();
          _setActiveOption(targetIndex, buttons, requestFocus: true);
        }).toJS,
      );
      buttons.add(button);
      root.append(button);
    }

    if (_showLoadMore) {
      final loadMore = _buildLoadMoreButton(l10n, buttons.length);
      buttons.add(loadMore);
      root.append(loadMore);
    }
  }

  /// The "Load more results" row: a real option button so keyboard and AT
  /// traversal reach it like any other row, but wired to [widget.onLoadMore]
  /// instead of a selection. [index] is its position in the listbox.
  web.HTMLButtonElement _buildLoadMoreButton(Lt l10n, int index) {
    final button = web.HTMLButtonElement()
      ..type = 'button'
      ..className = 'heyl-area-option heyl-area-load-more'
      ..tabIndex = index == _activeIndex ? 0 : -1
      ..setAttribute('role', 'option')
      ..setAttribute('aria-selected', '${index == _activeIndex}')
      ..setAttribute('data-area-index', '$index')
      ..setAttribute('data-testid', 'area-search-load-more');

    button.append(
      web.HTMLSpanElement()
        ..className = 'heyl-area-option-name'
        ..textContent = l10n.mapLocationSearchLoadMore,
    );

    // Same first-event-wins activation as a result row: the tap must survive
    // iOS Safari withholding pointerdown/click inside a composited scroller.
    var activated = false;
    void activate(web.Event event) {
      if (activated) return;
      activated = true;
      event.preventDefault();
      event.stopPropagation();
      // Submitting swaps this row for the spinner, so the row is torn out of
      // the DOM before Safari's delayed synthetic click lands — same orphaned
      // click as a selection, same neutralization.
      if (event.type != 'click') _swallowStrayMapClick();
      if (mounted) widget.onLoadMore?.call();
    }

    button.addEventListener(
      'pointerdown',
      ((web.Event event) => activate(event)).toJS,
    );
    button.addEventListener(
      'touchend',
      ((web.Event event) => activate(event)).toJS,
    );
    button.addEventListener(
      'click',
      ((web.Event event) => activate(event)).toJS,
    );
    button.addEventListener(
      'focus',
      ((web.Event _) {
        widget.onFocusChanged?.call(true);
        _setActiveOption(index, _buttons);
      }).toJS,
    );
    button.addEventListener(
      'keydown',
      ((web.KeyboardEvent event) {
        if (event.key == 'Enter' || event.key == ' ') {
          event.preventDefault();
          event.stopPropagation();
          if (mounted) widget.onLoadMore?.call();
          return;
        }
        final targetIndex = switch (event.key) {
          'ArrowUp' => math.max(index - 1, 0),
          'Home' => 0,
          'End' => _rowCount - 1,
          _ => null,
        };
        if (targetIndex == null) return;
        event.preventDefault();
        event.stopPropagation();
        _setActiveOption(targetIndex, _buttons, requestFocus: true);
      }).toJS,
    );
    return button;
  }

  /// Eats the single stray `click` iOS Safari emits after a tap that already
  /// selected a row. Selection tears the row out of the DOM, so that click
  /// falls through to the Mapbox canvas below and fires a map tap unless we
  /// stop it here at the window capture phase (before Mapbox's listeners).
  /// Self-clears on the swallowed click, or after a short timeout when no click
  /// arrives, so it never eats an unrelated later click.
  void _swallowStrayMapClick() {
    late final JSFunction listener;
    Timer? timeout;
    void remove() {
      timeout?.cancel();
      web.window.removeEventListener('click', listener, true.toJS);
    }

    listener = ((web.Event event) {
      event.stopPropagation();
      event.preventDefault();
      remove();
    }).toJS;
    web.window.addEventListener('click', listener, true.toJS);
    timeout = Timer(const Duration(milliseconds: 700), remove);
  }

  void _setActiveOption(
    int index,
    List<web.HTMLButtonElement> buttons, {
    bool requestFocus = false,
  }) {
    if (buttons.isEmpty || index < 0 || index >= buttons.length) return;
    _activeIndex = index;
    for (var buttonIndex = 0; buttonIndex < buttons.length; buttonIndex++) {
      final active = buttonIndex == index;
      buttons[buttonIndex]
        ..tabIndex = active ? 0 : -1
        ..setAttribute('aria-selected', '$active');
    }
    if (requestFocus) {
      buttons[index]
        ..focus()
        ..scrollIntoView();
    }
  }

  String _cssColor(Color color) {
    final argb = color.toARGB32().toRadixString(16).padLeft(8, '0');
    final alpha = int.parse(argb.substring(0, 2), radix: 16) / 255;
    final red = int.parse(argb.substring(2, 4), radix: 16);
    final green = int.parse(argb.substring(4, 6), radix: 16);
    final blue = int.parse(argb.substring(6, 8), radix: 16);
    return 'rgba($red, $green, $blue, ${alpha.toStringAsFixed(3)})';
  }
}
