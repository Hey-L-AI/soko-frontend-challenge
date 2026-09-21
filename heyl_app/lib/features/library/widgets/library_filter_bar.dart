import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/month_abbr.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/search/unified_search_overlay.dart'
    show kLibrarySearchHeroTag, unifiedSearchHeroFlightShuttle;
import '../../../shared/widgets/soko_tag_chip.dart';
import '../models/library_filter.dart';
import '../providers/library_filter_provider.dart';
import 'library_date_menu.dart';

extension on LibraryCategory {
  /// Level-two selection tone. Sítios/Pessoas remain palette stand-ins until a
  /// dedicated frame specifies otherwise, but the allowable palette is owned
  /// by the shared Tag design system.
  SokoTagTone get tagTone => switch (this) {
    LibraryCategory.eventos => SokoTagTone.blue,
    LibraryCategory.sitios => SokoTagTone.green,
    LibraryCategory.zines => SokoTagTone.purple,
    LibraryCategory.pessoas => SokoTagTone.yellow,
  };
}

/// Horizontally scrollable filter row. Search stays on every tab; × peels one layer.
class LibraryFilterBar extends ConsumerWidget {
  const LibraryFilterBar({super.key, this.margin});

  /// Where the first Tag starts and the last one stops, inside the scroller.
  ///
  /// The host mounts this row **unpadded**, so it must be told the page margin
  /// rather than inheriting it: that is what keeps the first chip aligned with
  /// the header above while the scroller itself still runs the full content
  /// width. Deliberately not `escapeHorizontalPadding` — growing back out of a
  /// parent's padding leaves the gutters visible but untappable, because hit
  /// testing stops at the first ancestor whose box excludes the point.
  final double? margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lt = Lt.of(context);
    final filter = ref.watch(libraryTabProvider);
    final notifier = ref.read(libraryTabProvider.notifier);

    String categoryLabel(LibraryCategory c) => switch (c) {
      LibraryCategory.eventos => lt.libraryFilterEvents,
      LibraryCategory.sitios => lt.libraryFilterPlaces,
      LibraryCategory.zines => lt.libraryFilterZines,
      LibraryCategory.pessoas => lt.libraryFilterPeople,
    };

    IconData categoryIcon(LibraryCategory c) => switch (c) {
      LibraryCategory.eventos => LucideIcons.calendar,
      LibraryCategory.sitios => LucideIcons.map_pin,
      LibraryCategory.zines => LucideIcons.book_open,
      LibraryCategory.pessoas => LucideIcons.user,
    };

    String subFilterLabel(LibrarySubFilter s) {
      if (s == LibrarySubFilter.data && filter.selectedDate != null) {
        return _formatLibraryDatePill(context, filter.selectedDate!);
      }
      return switch (s) {
        LibrarySubFilter.futuros => lt.libraryFilterUpcoming,
        LibrarySubFilter.passados => lt.libraryFilterPast,
        LibrarySubFilter.data => lt.libraryFilterDate,
        LibrarySubFilter.tuas => lt.libraryFilterYours,
        LibrarySubFilter.seguidas => lt.libraryFilterFollowed,
        LibrarySubFilter.feitasParaTi => lt.libraryFilterMadeForYou,
      };
    }

    Widget dateTag({SokoTagTone? tone}) {
      final selectedDay = filter.selectedDate;
      return LibraryDateMenu(
        selectedDate: selectedDay,
        // The chip is `provideSemantics: false`, so its visible text — which is
        // the picked date once there is one — is excluded from the tree along
        // with the rest of its subtree. Hand the date to the composite node as
        // its `value` or a screen-reader user hears only "Pick a date" and is
        // never told which one is applied.
        valueLabel: selectedDay == null
            ? null
            : _formatLibraryDatePill(context, selectedDay),
        selected: tone != null,
        onPicked: (picked) {
          final current = filter.selectedDate;
          if (current != null && isSameCalendarDay(picked, current)) {
            notifier.state = filter.withSubFilter(null);
            return;
          }
          notifier.state = filter.withDate(picked);
        },
        child: SokoTagChip(
          label: subFilterLabel(LibrarySubFilter.data),
          selected: tone != null,
          tone: tone ?? SokoTagTone.pink,
          // LibraryDateMenu owns the tap, and announces the composite trigger
          // as one node carrying this label and the picked date as its value.
          provideSemantics: false,
        ),
      );
    }

    void tapSubFilter(LibrarySubFilter s) {
      notifier.state = filter.withSubFilter(s);
    }

    IconData? subFilterIcon(LibrarySubFilter s) => switch (s) {
      LibrarySubFilter.seguidas => LucideIcons.user_check,
      _ => null,
    };

    final items = <SokoTagBarEntry>[];
    void add(Object id, Widget child) {
      items.add(SokoTagBarItem(id: id, child: child));
    }

    add(
      'search',
      // Unified-search: the icon flies into the overlay's input pill.
      Hero(
        tag: kLibrarySearchHeroTag,
        flightShuttleBuilder: unifiedSearchHeroFlightShuttle,
        child: SokoTagIconChip(
          icon: LucideIcons.search,
          semanticsLabel: lt.librarySearchSemantic,
          onTap: () {
            final open = ref.read(librarySearchOpenProvider);
            ref.read(librarySearchOpenProvider.notifier).state = !open;
            if (open) resetLibrarySearch(ref);
          },
        ),
      ),
    );

    final selectedSub = filter.subFilter;
    final selectedCategory = filter.category;

    if (selectedCategory == null) {
      for (final c in LibraryCategory.values) {
        add(
          c,
          SokoTagChip(
            label: categoryLabel(c),
            icon: categoryIcon(c),
            onTap: () => notifier.state = filter.toggleCategory(c),
          ),
        );
      }
    } else {
      final joined = selectedSub != null;
      final categoryItem = SokoTagBarItem(
        id: selectedCategory,
        child: SokoTagChip(
          label: categoryLabel(selectedCategory),
          icon: categoryIcon(selectedCategory),
          selected: true,
          onTap: () => notifier.state = LibraryFilter.initial,
        ),
      );
      if (joined) {
        items.add(
          SokoTagGroup(
            segments: [
              categoryItem,
              SokoTagBarItem(
                id: selectedSub,
                child: selectedSub == LibrarySubFilter.data
                    ? dateTag(tone: selectedCategory.tagTone)
                    : SokoTagChip(
                        label: subFilterLabel(selectedSub),
                        icon: subFilterIcon(selectedSub),
                        selected: true,
                        tone: selectedCategory.tagTone,
                        onTap: () => notifier.state = filter.withSubFilter(
                          LibrarySubFilter.defaultFor(selectedCategory),
                        ),
                      ),
              ),
            ],
          ),
        );
      } else {
        items.add(categoryItem);
      }
      for (final s in LibrarySubFilter.forCategory(selectedCategory)) {
        if (s == selectedSub) continue;
        add(
          s,
          s == LibrarySubFilter.data
              ? dateTag()
              : SokoTagChip(
                  label: subFilterLabel(s),
                  icon: subFilterIcon(s),
                  onTap: () => tapSubFilter(s),
                ),
        );
      }
    }

    if (!filter.isInitial) {
      add(
        'clear',
        SokoTagIconChip(
          icon: LucideIcons.x,
          semanticsLabel: lt.libraryFilterClearSemantic,
          onTap: () => notifier.state = filter.withoutAppliedFilter(),
        ),
      );
    }

    return SokoTagBar(
      items: items,
      motion: SokoTagBarMotion.reorder,
      margin: margin,
    );
  }
}

/// Compact day label for the joined Date pill — `14 Ago` / `Aug 14`.
String _formatLibraryDatePill(BuildContext context, DateTime day) {
  final locale = Localizations.localeOf(context).toString();
  final month = formatMonthAbbr(day, locale);
  return locale.startsWith('pt') || locale.startsWith('es')
      ? '${day.day} $month'
      : '$month ${day.day}';
}
