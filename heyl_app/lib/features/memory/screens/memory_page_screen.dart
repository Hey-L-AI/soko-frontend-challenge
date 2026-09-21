import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/soko_back_button.dart';
import '../../discovery/widgets/discovery_shell.dart' show popOrFallback;
import '../../profile/utils/profile_style.dart';
import '../widgets/memory_tab_view.dart';

/// `/memory` — the Memory page.
///
/// A page of its own, not the profile scrolled down: same content as the
/// profile's Memória section (persona, what you like, the composer, and the
/// tunable sections) with nothing of the social profile above it. Every
/// "brain" header button in the app lands here.
class MemoryPageScreen extends StatelessWidget {
  /// Arrive with the "add something to your memories" composer already open.
  final bool openTellUs;
  const MemoryPageScreen({super.key, this.openTellUs = false});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: PageContent(
        child: Material(
          type: MaterialType.transparency,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(15, 12, 15, 4),
                  child: Row(
                    children: [
                      SokoBackButton(
                        variant: SokoBackButtonVariant.shaded,
                        onTap: () => popOrFallback(context),
                      ),
                      Expanded(
                        child: Text(
                          Lt.of(context).profileTabMemory,
                          textAlign: TextAlign.center,
                          style: Pt.b1Bold,
                        ),
                      ),
                      // Balances the back button so the title sits optically
                      // centred rather than pushed right by it.
                      const SizedBox(width: 38),
                    ],
                  ),
                ),
                Expanded(child: MemoryTabView(openTellUs: openTellUs)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
