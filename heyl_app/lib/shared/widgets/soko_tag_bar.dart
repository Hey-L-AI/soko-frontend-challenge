// Part of the `soko_tag_chip.dart` library, not a file you import: the row and
// the chip communicate through the private `_SokoTagItemStyleScope`, so a Tag
// can read the joined edges and motion treatment of the slot it was placed in
// without every feature having to pass them down by hand. Import
// `soko_tag_chip.dart` to get [SokoTagBar].
//
// **`SokoTagChip` is not `SokoTag`.** `soko_tag.dart` next door holds an
// unrelated Figma primitive — the radius-2 inline pill on detail pages, chat
// cards and the map tooltip. Same word, different component; check which one a
// design means before reaching for either.

part of 'soko_tag_chip.dart';

/// One top-level entry accepted by [SokoTagBar].
@immutable
sealed class SokoTagBarEntry {
  const SokoTagBarEntry();
}

/// An independently moving item in a [SokoTagBar].
///
/// [id] must remain stable while the same conceptual control changes position;
/// the reorder treatment uses it to distinguish travel from removal/insertion.
@immutable
class SokoTagBarItem extends SokoTagBarEntry {
  const SokoTagBarItem({required this.id, required this.child});

  final Object id;
  final Widget child;
}

/// Adjacent Tag items whose touching edges form one compound filter.
///
/// The group owns both the zero-width internal gaps and the squared touching
/// corners. Each segment remains an independent [SokoTagBarItem], so a selected
/// sub-filter can be promoted into or out of the group without losing reorder
/// motion or its stable identity.
@immutable
class SokoTagGroup extends SokoTagBarEntry {
  const SokoTagGroup({required this.segments});

  final List<SokoTagBarItem> segments;
}

/// The shared Tag-row façade used by feed, search, and Library filters.
///
/// Both motion treatments use the same height, spacing, internal page margins,
/// full-bleed escape behavior, and Tag chrome. [SokoTagBarMotion.standard]
/// keeps a lazy [ListView] for stable lists; [SokoTagBarMotion.reorder] keeps
/// every item measured so insertions, removals, and promotion can animate.
class SokoTagBar extends StatelessWidget {
  const SokoTagBar({
    super.key,
    required this.items,
    this.motion = SokoTagBarMotion.standard,
    this.margin,
    this.escapeHorizontalPadding = 0,
    this.controller,
  });

  /// [SokoTagBarItem]s and [SokoTagGroup]s in visual order.
  final List<SokoTagBarEntry> items;

  final SokoTagBarMotion motion;

  /// Where the first Tag starts and the last one stops, inside the scroller.
  ///
  /// When omitted, this follows [escapeHorizontalPadding] if one is supplied;
  /// otherwise it uses [kSokoTagBarMargin]. This keeps a bar aligned to the
  /// ancestor padding it escapes without making every feature repeat the rule.
  final double? margin;

  /// Horizontal ancestor padding to cancel so the scroller itself is full
  /// bleed while its resting content remains aligned to the page.
  ///
  /// ⚠️ **The escaped gutters paint but do not accept taps.** This grows the
  /// row past its constraints with an [OverflowBox], and painting outside a
  /// parent's box does not extend hit testing: every ancestor's `hitTest`
  /// begins with `size.contains(position)`, so a pointer landing in the
  /// escaped strip is rejected by the padded ancestor before it ever reaches a
  /// Tag. A chip scrolled into that strip is therefore visible and inert.
  ///
  /// Prefer mounting the row OUTSIDE the page padding and passing [margin]
  /// instead — that is what `/library` does (see `LibraryScreen`), and it is
  /// the only arrangement where the full-bleed row is fully tappable. This
  /// option remains for hosts that genuinely cannot restructure; the two
  /// search surfaces still use it.
  final double escapeHorizontalPadding;

  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final slots = _flattenItems();
    final effectiveMargin =
        margin ??
        (escapeHorizontalPadding > 0
            ? escapeHorizontalPadding
            : kSokoTagBarMargin);

    final row = motion.isMeasured
        ? _SokoTagAnimatedRow(
            slots: slots,
            margin: effectiveMargin,
            controller: controller,
            motion: motion,
          )
        : _SokoTagLazyRow(
            slots: slots,
            margin: effectiveMargin,
            controller: controller,
          );

    return _SokoTagViewport(
      escapeHorizontalPadding: escapeHorizontalPadding,
      child: row,
    );
  }

  List<_SokoTagSlot> _flattenItems() {
    final slots = <_SokoTagSlot>[];
    final ids = <Object>{};

    void add(
      SokoTagBarItem item, {
      required bool joinLeft,
      required bool joinRight,
      required double gapBefore,
    }) {
      // The whole check lives inside the assert — `ids` is only ever read by
      // it, so populating the set as an assert's *condition* would leave it
      // permanently empty in release. Same stripping, without the trap of a
      // collection whose contents depend on the build mode.
      assert(() {
        if (!ids.add(item.id)) {
          throw FlutterError('SokoTagBar item ids must be unique: ${item.id}');
        }
        return true;
      }());
      slots.add(
        _SokoTagSlot(
          id: item.id,
          gapBefore: slots.isEmpty ? 0 : gapBefore,
          child: _SokoTagItemStyleScope(
            joinLeft: joinLeft,
            joinRight: joinRight,
            motion: motion,
            child: item.child,
          ),
        ),
      );
    }

    for (final entry in items) {
      switch (entry) {
        case SokoTagBarItem():
          add(
            entry,
            joinLeft: false,
            joinRight: false,
            gapBefore: kSokoTagChipGap,
          );
        case SokoTagGroup():
          assert(
            entry.segments.length > 1,
            'A joined group needs at least two segments.',
          );
          for (var i = 0; i < entry.segments.length; i++) {
            add(
              entry.segments[i],
              joinLeft: i > 0,
              joinRight: i < entry.segments.length - 1,
              gapBefore: i == 0 ? kSokoTagChipGap : 0,
            );
          }
      }
    }
    return slots;
  }
}

class _SokoTagItemStyleScope extends InheritedWidget {
  const _SokoTagItemStyleScope({
    required this.joinLeft,
    required this.joinRight,
    required this.motion,
    required super.child,
  });

  final bool joinLeft;
  final bool joinRight;
  final SokoTagBarMotion motion;

  static _SokoTagItemStyleScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SokoTagItemStyleScope>();

  @override
  bool updateShouldNotify(_SokoTagItemStyleScope oldWidget) =>
      joinLeft != oldWidget.joinLeft ||
      joinRight != oldWidget.joinRight ||
      motion != oldWidget.motion;
}

class _SokoTagSlot {
  const _SokoTagSlot({
    required this.id,
    required this.gapBefore,
    required this.child,
  });

  final Object id;
  final double gapBefore;
  final Widget child;
}

class _SokoTagLazyRow extends StatelessWidget {
  const _SokoTagLazyRow({
    required this.slots,
    required this.margin,
    this.controller,
  });

  final List<_SokoTagSlot> slots;
  final double margin;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kSokoTagChipHeight,
      child: ListView.builder(
        controller: controller,
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: margin),
        physics: const ClampingScrollPhysics(),
        itemCount: slots.length,
        itemBuilder: (_, i) {
          final slot = slots[i];
          return KeyedSubtree(
            key: ValueKey(slot.id),
            child: Padding(
              padding: EdgeInsets.only(left: slot.gapBefore),
              child: slot.child,
            ),
          );
        },
      ),
    );
  }
}

/// Allows a Tag bar nested in page padding to keep its scroll viewport
/// full-bleed. Pinning the height is load-bearing: [OverflowBox] otherwise sees
/// the Column's unbounded height and attempts to size itself to infinity.
class _SokoTagViewport extends StatelessWidget {
  const _SokoTagViewport({
    required this.escapeHorizontalPadding,
    required this.child,
  });

  final double escapeHorizontalPadding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (escapeHorizontalPadding <= 0) return child;

    return LayoutBuilder(
      builder: (context, constraints) {
        final full = constraints.maxWidth + 2 * escapeHorizontalPadding;
        return SizedBox(
          height: kSokoTagChipHeight,
          child: OverflowBox(
            maxWidth: double.infinity,
            alignment: Alignment.center,
            child: SizedBox(width: full, child: child),
          ),
        );
      },
    );
  }
}

/// Measured layout, used by [SokoTagBarMotion.reveal] and
/// [SokoTagBarMotion.reorder]. A normal Row can animate arrival but cannot move
/// two surviving items that exchange positions, so each measured slot animates
/// its own left coordinate and width.
///
/// **This is also where the reveal on mount comes from**, and it is a property
/// of measuring rather than a separate effect: a slot's width is unknown until
/// [MeasureSize] reports it one frame later, so every slot starts at `left: 0,
/// width: 0` and eases out to its measured geometry. Because left and width
/// share one curve, the row unfolds as a uniform horizontal expansion from its
/// leading edge.
class _SokoTagAnimatedRow extends StatefulWidget {
  const _SokoTagAnimatedRow({
    required this.slots,
    required this.margin,
    required this.motion,
    this.controller,
  });

  final List<_SokoTagSlot> slots;
  final double margin;
  final SokoTagBarMotion motion;
  final ScrollController? controller;

  @override
  State<_SokoTagAnimatedRow> createState() => _SokoTagAnimatedRowState();
}

class _SokoTagAnimatedRowState extends State<_SokoTagAnimatedRow>
    with TickerProviderStateMixin {
  final Map<Object, _SokoLiveSlot> _live = {};
  List<Object> _order = const [];

  /// Created only when the host supplies no controller of its own.
  ScrollController? _ownedScroll;

  ScrollController get _scroll =>
      widget.controller ?? (_ownedScroll ??= ScrollController());

  @override
  void initState() {
    super.initState();
    for (final slot in widget.slots) {
      _live[slot.id] = _SokoLiveSlot(
        slot: slot,
        controller: _controller(value: 1),
      );
    }
    _order = widget.slots.map((slot) => slot.id).toList();
  }

  AnimationController _controller({required double value}) =>
      AnimationController(
        vsync: this,
        duration: widget.motion.duration,
        value: value,
      );

  @override
  void didUpdateWidget(_SokoTagAnimatedRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_sameOrder(oldWidget.slots, widget.slots)) {
      for (final slot in widget.slots) {
        _live[slot.id]?.slot = slot;
      }
      return;
    }
    _resync();
  }

  bool _sameOrder(List<_SokoTagSlot> a, List<_SokoTagSlot> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  void _resync() {
    final incoming = {for (final slot in widget.slots) slot.id: slot};
    final reduceMotion = MediaQuery.of(context).disableAnimations;

    for (final slot in widget.slots) {
      final existing = _live[slot.id];
      if (existing == null) {
        _live[slot.id] = _SokoLiveSlot(
          slot: slot,
          controller: _controller(value: reduceMotion ? 1 : 0),
        );
        if (!reduceMotion) _live[slot.id]!.controller.forward();
      } else {
        existing.slot = slot;
        if (existing.leaving) {
          existing.leaving = false;
          existing.controller.forward();
        }
      }
    }

    for (final entry in _live.entries.toList()) {
      if (incoming.containsKey(entry.key) || entry.value.leaving) continue;
      entry.value.leaving = true;
      if (reduceMotion) {
        entry.value.controller.value = 0;
        _drop(entry.key);
      } else {
        entry.value.controller.reverse().whenComplete(() => _drop(entry.key));
      }
    }

    // Keep departing ids where they stood so they collapse in place while the
    // incoming order supplies the destinations for all surviving controls.
    final next = widget.slots.map((slot) => slot.id).toList();
    for (var i = 0; i < _order.length; i++) {
      final id = _order[i];
      if (next.contains(id) || !_live.containsKey(id)) continue;
      next.insert(i.clamp(0, next.length), id);
    }
    _order = next;
    setState(() {});
    _settleScroll(reduceMotion);
  }

  void _settleScroll(bool reduceMotion) {
    if (!_scroll.hasClients || _scroll.offset == 0) return;
    if (reduceMotion) {
      _scroll.jumpTo(0);
      return;
    }
    _scroll.animateTo(
      0,
      duration: widget.motion.duration,
      curve: widget.motion.curve,
    );
  }

  void _drop(Object id) {
    if (!mounted) return;
    final slot = _live[id];
    if (slot == null || !slot.leaving) return;
    slot.controller.dispose();
    setState(() {
      _live.remove(id);
      _order = List.of(_order)..remove(id);
    });
  }

  void _measured(Object id, double width) {
    final slot = _live[id];
    if (slot == null || slot.width == width) return;
    setState(() => slot.width = width);
  }

  @override
  void dispose() {
    for (final slot in _live.values) {
      slot.controller.dispose();
    }
    _ownedScroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lefts = <Object, double>{};
    final widths = <Object, double>{};
    var x = 0.0;
    for (final id in _order) {
      final live = _live[id];
      if (live == null) continue;
      final width = live.leaving ? 0.0 : (live.width ?? 0.0);
      lefts[id] = x;
      widths[id] = width;
      x += width;
    }

    final duration = MediaQuery.of(context).disableAnimations
        ? Duration.zero
        : widget.motion.duration;

    return SizedBox(
      height: kSokoTagChipHeight,
      child: SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: widget.margin),
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: x),
            duration: duration,
            curve: widget.motion.curve,
            builder: (context, animatedTotal, child) => SizedBox(
              width: animatedTotal,
              height: kSokoTagChipHeight,
              child: child,
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (final id in _order)
                  if (_live[id] case final live?)
                    _SokoTagSlotView(
                      key: ValueKey(id),
                      live: live,
                      left: lefts[id] ?? 0,
                      width: widths[id] ?? 0,
                      duration: duration,
                      motion: widget.motion,
                      onMeasured: (width) => _measured(id, width),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SokoLiveSlot {
  _SokoLiveSlot({required this.slot, required this.controller});

  _SokoTagSlot slot;
  final AnimationController controller;
  bool leaving = false;
  double? width;
}

class _SokoTagSlotView extends StatelessWidget {
  const _SokoTagSlotView({
    super.key,
    required this.live,
    required this.left,
    required this.width,
    required this.duration,
    required this.motion,
    required this.onMeasured,
  });

  final _SokoLiveSlot live;
  final double left;
  final double width;
  final Duration duration;
  final SokoTagBarMotion motion;
  final ValueChanged<double> onMeasured;

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: live.controller, curve: motion.curve);

    return AnimatedPositioned(
      duration: duration,
      curve: motion.curve,
      left: left,
      top: 0,
      width: width,
      height: kSokoTagChipHeight,
      child: FadeTransition(
        opacity: curve,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: 0,
            maxWidth: double.infinity,
            child: MeasureSize(
              onChange: (size) => onMeasured(size.width),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(width: live.slot.gapBefore),
                  live.slot.child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
