import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/page_layout.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../shared/widgets/soko_back_button.dart';
import '../../providers/unified_list_provider.dart';
import 'list_zine_view.dart';

/// Full-screen, read-only ("sandbox") reader for an arbitrary zine (list) —
/// the real production [ListZineView] with `sandbox: true`, hydrated from
/// [unifiedListProvider].
///
/// Mirrors `OnboardingDetailPage` / `OnboardingZinePage`: pushed on the ROOT
/// navigator so it presents as a normal page whose back button pops straight
/// back to wherever it was opened from (e.g. a sandboxed profile → onboarding),
/// while the sandbox body suppresses every external link / cross-screen nav.
/// Unlike `OnboardingZinePage` it carries no Save CTA / onboarding coupling —
/// it's a neutral, generic sandbox reader for any list id. Zine items are
/// view-only (no `onSandboxItemTap`), so nothing inside can navigate away.
class SandboxZinePage extends ConsumerWidget {
  const SandboxZinePage({super.key, required this.listId});

  final String listId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listState = ref.watch(unifiedListProvider(listId));

    final Widget body;
    if (listState.isNotFound || listState.error != null) {
      body = _Message(text: Lt.of(context).publicListNotFound);
    } else if (listState.list == null ||
        (listState.isLoadingItems && listState.items.isEmpty)) {
      body = const _Loading();
    } else if (listState.items.isEmpty) {
      body = _Message(text: Lt.of(context).publicListNotFound);
    } else {
      body = SingleChildScrollView(
        child: ListZineView(listId: listId, state: listState, sandbox: true),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.sokoPaper,
      body: SafeArea(
        child: PageContent(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
                child: Row(
                  children: [
                    SokoBackButton(
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 80),
    child: Center(child: CircularProgressIndicator(color: AppColors.sokoInk)),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 60),
    child: Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: AppTheme.body(fontSize: 16, color: AppColors.sokoInk),
      ),
    ),
  );
}
