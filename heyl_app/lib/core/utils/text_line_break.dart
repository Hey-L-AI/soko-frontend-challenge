/// Restricts where a short string may wrap to a single, balanced break point,
/// so that — when it doesn't fit on one line — it splits into two visually
/// balanced lines instead of dropping one or two trailing words onto line 2
/// (e.g. avoids "…um pouco mais de" / "ti").
///
/// Mechanism: the same non-breaking-space technique as `soko_brand_header`'s
/// `_withPreferredBreaks`, but generic — no comma/semantic assumptions, so it
/// works for any locale. Every inter-word space except the chosen mid-point is
/// replaced with U+00A0 (non-breaking space), leaving exactly ONE ordinary
/// space where the text is allowed to wrap. When the string fits on one line
/// the single breakable space is harmless and it stays on one line; only when
/// the container is too narrow does it wrap — and then it wraps at the balanced
/// mid-point. This keeps the result responsive across viewport widths.
///
/// The break point is the inter-word gap that most evenly balances the two
/// halves by rendered line length (word characters plus the spaces between the
/// words on each line), which reproduces natural "middle of the sentence"
/// splits for Latin locales. Whitespace-free scripts collapse to a single token
/// and are returned unchanged, falling back to the engine's default wrapping.
///
/// Pair with a `maxLines: 2` [Text]/`AutoSizeText`: this picks the break, the
/// widget still handles the (rare) case where two lines don't fit by
/// shrinking/ellipsising.
String balancedTwoLineBreak(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return text;

  final words = trimmed.split(RegExp(r'\s+'));
  if (words.length < 2) return trimmed;

  const nbsp = '\u00A0';

  final wordLen = words.map((w) => w.length).toList(growable: false);
  final totalChars = wordLen.fold<int>(0, (sum, n) => sum + n);
  final wordCount = words.length;

  // Choose the split (between word i and i+1) whose two lines are closest in
  // rendered length. Line length = sum(word chars on the line) + inter-word
  // spaces on that line (= words on the line - 1).
  var bestSplit = 1;
  var bestDelta = 1 << 30;
  var leftChars = 0;
  for (var i = 0; i < wordCount - 1; i++) {
    leftChars += wordLen[i];
    final leftWords = i + 1;
    final rightWords = wordCount - leftWords;
    final leftLen = leftChars + (leftWords - 1);
    final rightLen = (totalChars - leftChars) + (rightWords - 1);
    final delta = (leftLen - rightLen).abs();
    if (delta < bestDelta) {
      bestDelta = delta;
      bestSplit = leftWords;
    }
  }

  final head = words.sublist(0, bestSplit).join(nbsp);
  final tail = words.sublist(bestSplit).join(nbsp);
  return '$head $tail'; // the sole breakable space
}
