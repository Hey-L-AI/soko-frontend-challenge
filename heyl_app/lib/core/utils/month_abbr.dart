import 'package:intl/intl.dart';

/// Returns a locale-aware short month abbreviation, **capitalised** and with
/// no trailing period — `Jan`, `Mar`, `Mai`.
///
/// Two normalisations, both there because `intl`'s `MMM` skeleton varies by
/// locale in ways the designs do not:
///
/// 1. **No trailing period.** `en` → `Jan`, `pt_BR` → `jan`, `pt_PT` → `jan.`.
///    In space-constrained slots (event date badges, compact calendars) that
///    extra dot is what overflows the box and shows as truncated text like
///    `Mai..` — Figma sizes those boxes for 3 glyphs, not 4.
/// 2. **Capitalised initial.** Portuguese and Spanish write month names
///    lowercase in prose (`19 de março`), so `intl` correctly returns `mar`
///    for them and `Mar` for `en`. Every Soko design capitalises the month
///    regardless of locale, so the casing is normalised here rather than at
///    each call site — it previously was not, and three call sites had grown
///    their own private `_titleCase` while two others silently rendered
///    lowercase in pt/es.
///
/// Use this anywhere a month label has limited horizontal space. For full
/// dates that read as a sentence, keep `DateFormat('d MMM', locale)` — there
/// the trailing dot is the locale's normal abbreviation marker, and the
/// lowercase initial is orthographically correct.
String formatMonthAbbr(DateTime date, [String? locale]) {
  final String raw = DateFormat('MMM', locale).format(date).replaceAll('.', '');
  if (raw.isEmpty) return raw;
  return '${raw[0].toUpperCase()}${raw.substring(1).toLowerCase()}';
}
