import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/scallop_divider.dart';

/// Empty-state welcome view for the chat screen.
///
/// Per the PROD-1804 redesign (Figma `6353:29568`), the empty state is
/// stripped down to three elements: a character illustration, a CTA
/// headline, and the chat input passed in by [chat_screen.dart]. The
/// input keeps its [Hero] tag from there so cross-route animation still
/// works.
class WelcomeView extends StatelessWidget {
  final Widget inputWidget;

  const WelcomeView({super.key, required this.inputWidget});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    // Wrap in a scrollable so drag-down dismisses the keyboard the same
    // way it does in the conversation state's message list
    // (`ScrollViewKeyboardDismissBehavior.onDrag`). `AlwaysScrollable`
    // physics is required since the welcome content fits on-screen and
    // would otherwise be non-scrollable, suppressing the drag hook.
    //
    // The inner `SizedBox(height: constraints.maxHeight)` is load-bearing:
    // `SingleChildScrollView` hands its child an unbounded `maxHeight`,
    // and the `Column` below uses `Spacer`s, which throw
    // "RenderFlex children have non-zero flex but incoming height
    // constraints are unbounded" when the parent vertical constraint is
    // infinite. Tightening the height to the viewport bounds the flex
    // arithmetic without giving up the scroll gesture.
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: SizedBox(
            height: constraints.maxHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const Spacer(),

                  // Character illustration. Asset ships with a transparent
                  // background, so it renders directly against the page
                  // colour without any blend trick.
                  Image.asset(
                    'assets/images/illustrations/soko-seating-and-reading.webp',
                    width: 115,
                    height: 115,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 10),

                  // CTA headline — Mobile/H1: Season Mix Light 42 px,
                  // lh 0.94, tracking -2% (-0.84 px). Soko/Ink.
                  Text(
                    l10n.chatEmptyCta,
                    style: const TextStyle(
                      fontFamily: 'SeasonMix',
                      fontWeight: FontWeight.w300,
                      fontSize: 42,
                      height: 0.94,
                      letterSpacing: -0.84,
                      color: AppColors.sokoInk,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const Spacer(),

                  // Soko-Ink scallop motif rendered immediately above
                  // the chat composer. Matches the conversation-state
                  // input on `/chat` so both visual states share the
                  // same Soko vocabulary.
                  const ScallopDivider(),
                  const SizedBox(height: 8),

                  // The chat input lives at the bottom of the available
                  // area. The keyboard inset is owned by Scaffold's
                  // `resizeToAvoidBottomInset`, so this widget doesn't
                  // reserve keyboard clearance itself.
                  inputWidget,

                  // 8pt gap below the chat bar — same value used below
                  // the conversation-state MessageInput, so the
                  // bar-to-nav (and bar-to-keyboard) gap stays consistent
                  // across welcome and conversation states.
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
