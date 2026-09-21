import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../utils/owner_hours.dart';

/// Per-day opening-hours editor (PROD-4040 T2.3) — replaces the raw-JSON
/// textarea. Seven day rows; tapping one opens a sheet to toggle open/closed and
/// pick time ranges (supports past-midnight and split slots). Emits the full
/// `List<DayHours>` on every change; the host serialises it on save.
class OwnerHoursEditor extends ConsumerStatefulWidget {
  const OwnerHoursEditor({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  final List<DayHours> initial;
  final ValueChanged<List<DayHours>> onChanged;

  @override
  ConsumerState<OwnerHoursEditor> createState() => _OwnerHoursEditorState();
}

class _OwnerHoursEditorState extends ConsumerState<OwnerHoursEditor> {
  late List<DayHours> _days = List.of(widget.initial);

  Future<void> _editDay(int index) async {
    final updated = await showBottomSheetWithHiddenNav<DayHours>(
      context: context,
      ref: ref,
      builder: (_) => _DayHoursSheet(day: _days[index]),
    );
    if (updated == null || !mounted) return;
    setState(
      () => _days = [
        for (var i = 0; i < _days.length; i++) i == index ? updated : _days[i],
      ],
    );
    widget.onChanged(_days);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.sokoInk8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < _days.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppColors.sokoInk8),
            _DayRow(day: _days[i], onTap: () => _editDay(i)),
          ],
        ],
      ),
    );
  }
}

String dayHoursSummary(DayHours day, Lt l10n) {
  switch (day.mode) {
    case DayHoursMode.unset:
      return l10n.businessOwnershipHoursAdd;
    case DayHoursMode.closed:
      return l10n.venueHoursClosed;
    case DayHoursMode.raw:
      return day.raw ?? '';
    case DayHoursMode.open:
      return day.slots.map((s) => '${s.open} – ${s.close}').join(', ');
  }
}

String localizedDayName(String key, Lt l10n) {
  switch (key) {
    case 'monday':
      return l10n.dayMonday;
    case 'tuesday':
      return l10n.dayTuesday;
    case 'wednesday':
      return l10n.dayWednesday;
    case 'thursday':
      return l10n.dayThursday;
    case 'friday':
      return l10n.dayFriday;
    case 'saturday':
      return l10n.daySaturday;
    case 'sunday':
      return l10n.daySunday;
    default:
      return key;
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({required this.day, required this.onTap});

  final DayHours day;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isMuted = day.mode == DayHoursMode.unset;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              child: Text(
                localizedDayName(day.key, l10n),
                style: const TextStyle(fontSize: 14, color: AppColors.sokoInk),
              ),
            ),
            Expanded(
              child: Text(
                dayHoursSummary(day, l10n),
                style: TextStyle(
                  fontSize: 14,
                  color: isMuted ? AppColors.sokoShade3 : AppColors.sokoInk,
                ),
              ),
            ),
            const Icon(
              LucideIcons.chevron_right,
              size: 18,
              color: AppColors.sokoShade3,
            ),
          ],
        ),
      ),
    );
  }
}

/// Per-day editor sheet: open/closed toggle + editable time slots.
class _DayHoursSheet extends StatefulWidget {
  const _DayHoursSheet({required this.day});

  final DayHours day;

  @override
  State<_DayHoursSheet> createState() => _DayHoursSheetState();
}

class _DayHoursSheetState extends State<_DayHoursSheet> {
  late bool _open;
  late List<HourSlot> _slots;

  @override
  void initState() {
    super.initState();
    // `raw` days become editable structured slots the moment the owner opens
    // the editor (we don't reverse-parse Google's text — start from a default).
    _open =
        widget.day.mode == DayHoursMode.open ||
        widget.day.mode == DayHoursMode.raw;
    _slots = widget.day.mode == DayHoursMode.open && widget.day.slots.isNotEmpty
        ? List.of(widget.day.slots)
        : const [HourSlot(open: '09:00', close: '17:00')];
  }

  DayHours _result() {
    if (!_open) return DayHours(key: widget.day.key, mode: DayHoursMode.closed);
    return DayHours(
      key: widget.day.key,
      mode: DayHoursMode.open,
      slots: _slots,
    );
  }

  Future<void> _pickTime(int slotIndex, {required bool isOpen}) async {
    final current = isOpen ? _slots[slotIndex].open : _slots[slotIndex].close;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _TimeWheelSheet(initial: current),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _slots = [
        for (var i = 0; i < _slots.length; i++)
          if (i == slotIndex)
            isOpen
                ? _slots[i].copyWith(open: picked)
                : _slots[i].copyWith(close: picked)
          else
            _slots[i],
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return DSSheetShell(
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              localizedDayName(widget.day.key, l10n),
              style: const TextStyle(
                fontFamily: 'UnJamoBatang',
                fontSize: 24,
                height: .96,
                letterSpacing: -1,
                color: AppColors.sokoInk,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _Segment(
                    label: l10n.businessOwnershipHoursOpen,
                    selected: _open,
                    onTap: () => setState(() => _open = true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Segment(
                    label: l10n.venueHoursClosed,
                    selected: !_open,
                    onTap: () => setState(() => _open = false),
                  ),
                ),
              ],
            ),
            if (_open) ...[
              const SizedBox(height: 16),
              for (var i = 0; i < _slots.length; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                _SlotRow(
                  slot: _slots[i],
                  canRemove: _slots.length > 1,
                  onPickOpen: () => _pickTime(i, isOpen: true),
                  onPickClose: () => _pickTime(i, isOpen: false),
                  onRemove: () =>
                      setState(() => _slots = [..._slots]..removeAt(i)),
                  removeLabel: l10n.businessOwnershipHoursRemove,
                ),
              ],
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(
                    () => _slots = [
                      ..._slots,
                      const HourSlot(open: '09:00', close: '17:00'),
                    ],
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.sokoInk,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  icon: const Icon(LucideIcons.plus, size: 16),
                  label: Text(l10n.businessOwnershipHoursAddSlot),
                ),
              ),
            ],
            const SizedBox(height: 20),
            SokoCtaButton(
              label: l10n.businessOwnershipHoursDone,
              onPressed: () => Navigator.of(context).pop(_result()),
            ),
          ],
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.sokoInk : AppColors.sokoPaper,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.sokoInk : AppColors.sokoInk8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: selected ? AppColors.sokoPaper : AppColors.sokoInk,
          ),
        ),
      ),
    );
  }
}

class _SlotRow extends StatelessWidget {
  const _SlotRow({
    required this.slot,
    required this.canRemove,
    required this.onPickOpen,
    required this.onPickClose,
    required this.onRemove,
    required this.removeLabel,
  });

  final HourSlot slot;
  final bool canRemove;
  final VoidCallback onPickOpen;
  final VoidCallback onPickClose;
  final VoidCallback onRemove;
  final String removeLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _TimeButton(value: slot.open, onTap: onPickOpen),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text('–', style: TextStyle(color: AppColors.sokoShade3)),
        ),
        Expanded(
          child: _TimeButton(value: slot.close, onTap: onPickClose),
        ),
        if (canRemove)
          IconButton(
            onPressed: onRemove,
            tooltip: removeLabel,
            icon: const Icon(
              LucideIcons.circle_minus,
              size: 20,
              color: AppColors.sokoShade3,
            ),
          ),
      ],
    );
  }
}

class _TimeButton extends StatelessWidget {
  const _TimeButton({required this.value, required this.onTap});

  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.sokoPaper,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.sokoInk8),
        ),
        child: Text(
          value,
          style: const TextStyle(fontSize: 15, color: AppColors.sokoInk),
        ),
      ),
    );
  }
}

/// Two-wheel (hour / 15-min) time picker, returns `HH:MM`.
class _TimeWheelSheet extends StatefulWidget {
  const _TimeWheelSheet({required this.initial});

  final String initial;

  @override
  State<_TimeWheelSheet> createState() => _TimeWheelSheetState();
}

class _TimeWheelSheetState extends State<_TimeWheelSheet> {
  static const _minutes = [0, 15, 30, 45];
  late int _hour;
  late int _minuteIndex;

  @override
  void initState() {
    super.initState();
    final parts = widget.initial.split(':');
    _hour = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 9;
    final minute = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
    // Snap to the nearest 15.
    _minuteIndex = (minute / 15).round().clamp(0, 3);
    _hour = _hour.clamp(0, 23);
  }

  String get _value =>
      '${_hour.toString().padLeft(2, '0')}:'
      '${_minutes[_minuteIndex].toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return DSSheetShell(
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 180,
              child: Row(
                children: [
                  Expanded(
                    child: CupertinoPicker(
                      scrollController: FixedExtentScrollController(
                        initialItem: _hour,
                      ),
                      itemExtent: 36,
                      onSelectedItemChanged: (i) => setState(() => _hour = i),
                      children: [
                        for (var h = 0; h < 24; h++)
                          Center(child: Text(h.toString().padLeft(2, '0'))),
                      ],
                    ),
                  ),
                  const Text(':'),
                  Expanded(
                    child: CupertinoPicker(
                      scrollController: FixedExtentScrollController(
                        initialItem: _minuteIndex,
                      ),
                      itemExtent: 36,
                      onSelectedItemChanged: (i) =>
                          setState(() => _minuteIndex = i),
                      children: [
                        for (final m in _minutes)
                          Center(child: Text(m.toString().padLeft(2, '0'))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SokoCtaButton(
              label: Lt.of(context).businessOwnershipHoursDone,
              onPressed: () => Navigator.of(context).pop(_value),
            ),
          ],
        ),
      ),
    );
  }
}
