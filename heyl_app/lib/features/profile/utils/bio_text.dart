import 'package:flutter/services.dart';

/// Max paragraphs a bio may have. Enforced live in the editor
/// ([BioParagraphLimiter]) and again on save/display ([collapseBioWhitespace]).
const int kBioMaxParagraphs = 4;

/// Normalizes a user-entered bio so a string typed with many Return presses
/// doesn't render as a tall column of empty space on the profile.
///
/// - Any whitespace run that contains a line break collapses to a single `\n`,
///   so intentional single-line paragraph breaks survive but blank lines don't.
/// - Repeated spaces/tabs within a line collapse to one space.
/// - Capped at [maxParagraphs] paragraphs: any overflow is merged into the last
///   allowed paragraph rather than dropped, so no text is lost.
/// - Leading/trailing whitespace is trimmed.
///
/// Applied on **save** (edit profile) so new bios stay tidy, and on **display**
/// (public profile) so bios already stored with the extra breaks render tidily
/// without a data migration.
String collapseBioWhitespace(
  String bio, {
  int maxParagraphs = kBioMaxParagraphs,
}) {
  final collapsed = bio
      .replaceAll(RegExp(r'\s*\n\s*'), '\n')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .trim();
  if (collapsed.isEmpty) return collapsed;

  final paras = collapsed.split('\n');
  if (paras.length <= maxParagraphs) return collapsed;

  // Keep the first (maxParagraphs - 1) breaks, then fold the overflow into the
  // last allowed paragraph (joined by spaces) so the cap never drops content.
  final head = paras.take(maxParagraphs - 1);
  final tail = paras.skip(maxParagraphs - 1).join(' ');
  return [...head, tail].join('\n');
}

/// Live editor guard: rejects an edit that would give the bio a blank line or
/// push it past [maxParagraphs] paragraphs. The offending keystroke (usually a
/// second Return, or a Return on the last allowed line) simply does nothing, so
/// the field can never grow into the tall empty-space state and the user feels
/// the limit as they type. Pair with `maxLength` (which shows the char counter)
/// so both bio dimensions — length and paragraphs — are enforced in the editor.
class BioParagraphLimiter extends TextInputFormatter {
  const BioParagraphLimiter({this.maxParagraphs = kBioMaxParagraphs});

  final int maxParagraphs;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    // Two newlines separated by only spaces/tabs = a blank line.
    final hasBlankLine = RegExp(r'\n[^\S\n]*\n').hasMatch(text);
    final tooManyParagraphs = '\n'.allMatches(text).length > maxParagraphs - 1;
    if (hasBlankLine || tooManyParagraphs) return oldValue;
    return newValue;
  }
}
