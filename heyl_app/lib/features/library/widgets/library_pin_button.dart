import 'package:flutter/material.dart';

import '../../../l10n/generated/l10n.dart';
import 'library_glyph.dart';

/// Display-only thumbtack on a pinned row.
class LibraryPinMark extends StatelessWidget {
  const LibraryPinMark({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: Lt.of(context).libraryPinnedSemantic,
      child: LibraryGlyph.pin(),
    );
  }
}
