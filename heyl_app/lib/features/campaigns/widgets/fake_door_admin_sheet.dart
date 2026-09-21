import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/campaign.dart';
import '../../../providers/api_provider.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../providers/campaign_service.dart';
import '../utils/campaign_presenter.dart';

/// Opens the admin fake-door panel as a bottom sheet: toggle the Discovery
/// warm-up auto-surfacing, and manually trigger any eligible campaign to test
/// it on-device. Called from the `[admin] Fake-door` menu row.
///
/// The sheet returns the chosen [Campaign] via `Navigator.pop`; the caller
/// presents it *after* the sheet closes (so a `sheet`-presentation campaign
/// doesn't stack on this picker) in the campaign's OWN configured presentation
/// — surface is a per-campaign setting, not an admin choice.
Future<void> showFakeDoorAdminSheet(BuildContext context, WidgetRef ref) async {
  final campaign = await showBottomSheetWithHiddenNav<Campaign?>(
    context: context,
    ref: ref,
    builder: (_) => const _FakeDoorAdminSheet(),
  );
  if (campaign == null || !context.mounted) return;
  await presentCampaign(context, ref, campaign);
}

class _FakeDoorAdminSheet extends ConsumerStatefulWidget {
  const _FakeDoorAdminSheet();

  @override
  ConsumerState<_FakeDoorAdminSheet> createState() =>
      _FakeDoorAdminSheetState();
}

class _FakeDoorAdminSheetState extends ConsumerState<_FakeDoorAdminSheet> {
  late Future<List<Campaign>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  // Catalog read (`GET /campaigns`) so answered campaigns stay in the list
  // (each carries its prior `response`) and can be re-triggered — the POST is
  // an idempotent upsert, so re-answering overwrites.
  Future<List<Campaign>> _load() =>
      ref.read(campaignApiProvider).getCampaignsForUser();

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    final warmupOn = ref.watch(
      campaignServiceProvider.select((s) => s.warmupEnabled),
    );
    return DSSheetShell(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Fake-door (admin)',
                style: AppTheme.display(
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                  color: AppColors.sokoInk,
                ),
              ),
            ),
            IconButton(
              onPressed: _reload,
              icon: const Icon(
                LucideIcons.refresh_cw,
                size: 18,
                color: AppColors.sokoShade3,
              ),
              tooltip: 'Reload',
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _WarmupToggle(
              value: warmupOn,
              onChanged: (v) => ref
                  .read(campaignServiceProvider.notifier)
                  .setWarmupEnabled(v),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Trigger a campaign',
                style: AppTheme.display(
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                  color: AppColors.sokoInk,
                ),
              ),
            ),
            const SizedBox(height: 4),
            FutureBuilder<List<Campaign>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return _hint('Loading campaigns…');
                }
                if (snapshot.hasError) {
                  return _hint('Failed to load: ${snapshot.error}');
                }
                final campaigns = snapshot.data ?? const [];
                if (campaigns.isEmpty) {
                  return _hint('No eligible campaigns for this account.');
                }
                return Column(
                  children: [
                    for (final campaign in campaigns)
                      _CampaignRow(campaign: campaign),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      text,
      style: AppTheme.body(
        fontSize: 14,
        color: AppColors.sokoInk.withValues(alpha: 0.6),
      ),
    ),
  );
}

class _WarmupToggle extends StatelessWidget {
  const _WarmupToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      decoration: BoxDecoration(
        color: AppColors.sokoShade5,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Auto-surface on Discovery',
              style: AppTheme.body(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: AppColors.sokoInk,
              ),
            ),
          ),
          // Canonical Soko switch (matches notification_categories_section).
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.sokoPink,
            activeTrackColor: AppColors.sokoPink.withValues(alpha: 0.4),
          ),
        ],
      ),
    );
  }
}

class _CampaignRow extends StatelessWidget {
  const _CampaignRow({required this.campaign});

  final Campaign campaign;

  @override
  Widget build(BuildContext context) {
    // Each campaign gets its own trigger button. Pops the sheet returning
    // this campaign; `showFakeDoorAdminSheet` then presents it in the
    // campaign's OWN configured presentation (no surface choice here).
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        // Same shade5 rounded surround as the auto-surface toggle above.
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        decoration: BoxDecoration(
          color: AppColors.sokoShade5,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                campaign.key,
                style: AppTheme.body(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.sokoInk,
                ),
              ),
            ),
            const SizedBox(width: 12),
            SokoCtaButton(
              label: 'Trigger',
              expand: false,
              variant: SokoCtaVariant.pink,
              onPressed: () => Navigator.of(context).pop(campaign),
            ),
          ],
        ),
      ),
    );
  }
}
