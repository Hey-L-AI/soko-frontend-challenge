// DEV-ONLY visual harness for the memory-bio + "conta-nos sobre ti" UI.
//
// Not wired into the app router — run it as an alternate entrypoint:
//
//   flutter run -t lib/dev/memory_bio_preview.dart -d chrome
//
// Renders the two Phase-5 surfaces with FAKE data, so you can eyeball layout /
// copy / spacing without a backend or the feature flag:
//   1. The "What you like" card as it appears on the social profile — title,
//      chips, memory-bio prose, the "conta-nos sobre ti" pill, and (owner) the
//      "your bio evolved" accept banner.
//   2. The elaborate free-text "conta-nos sobre ti" card that lives at the top
//      of the Memory page (live, via the mock API).
// Use the state picker to switch scenarios; toggle EN / PT-PT for both copies.
//
// Throwaway: delete lib/dev/ before shipping if you don't want it in the tree.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/app_loading_stub.dart'
    if (dart.library.js_interop) '../core/utils/app_loading_web.dart';
import '../data/datasources/api/social_profile_api.dart';
import '../data/models/social/memory_bio_state.dart';
import '../features/memory/widgets/memory_tell_us_card.dart';
import '../features/profile/utils/profile_style.dart';
import '../features/profile/widgets/memory_bio_section.dart';
import '../l10n/generated/l10n.dart';
import '../providers/api_provider.dart';

const _sampleBio =
    'A curious cosmopolitan who gravitates to quiet, characterful cafés and '
    'live jazz. Vegetarian, usually out with a partner, and happiest at '
    'weekend markets and neighbourhood spots in Alvalade.';

const _samplePending =
    'A regular at cozy cafés and small live-music rooms — recently into natural '
    'wine bars and slow Sunday brunches. Still vegetarian, still exploring '
    'Alvalade and Anjos on foot.';

/// Fake so the pending banner's accept button doesn't hit the network.
class _FakeSocialProfileApi implements SocialProfileApi {
  @override
  Future<MemoryBioState> acceptMemoryBio() async =>
      const MemoryBioState(memoryBio: _sampleBio);

  @override
  Future<MemoryBioState> setMemoryBioHidden(bool hidden) async =>
      MemoryBioState(memoryBio: _sampleBio, memoryBioHidden: hidden);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Scenario {
  final String label;
  final bool isSelf;
  final String? bio;
  final String? pending;
  final String? note;
  const _Scenario(
    this.label, {
    required this.isSelf,
    this.bio,
    this.pending,
    this.note,
  });
}

final _scenarios = <_Scenario>[
  const _Scenario('Dono · bio + entrada', isSelf: true, bio: _sampleBio),
  const _Scenario(
    'Dono · versão pendente',
    isSelf: true,
    bio: _sampleBio,
    pending: _samplePending,
  ),
  const _Scenario(
    'Dono · memória vazia',
    isSelf: true,
    note:
        'Utilizador novo: sem chips nem bio, mas a entrada "conta-nos sobre '
        'ti" aparece na mesma.',
  ),
  const _Scenario('Visitante · com bio', isSelf: false, bio: _sampleBio),
  const _Scenario(
    'Visitante · sem bio',
    isSelf: false,
    note:
        'A pessoa que estás a ver ainda não tem bio — a secção mostra só os '
        'chips (ou nada).',
  ),
];

void main() {
  runApp(
    ProviderScope(
      overrides: [
        useMockApiProvider.overrideWith((ref) => true),
        socialProfileApiProvider.overrideWithValue(_FakeSocialProfileApi()),
      ],
      child: const _PreviewApp(),
    ),
  );
  hideAppLoading();
}

class _PreviewApp extends StatefulWidget {
  const _PreviewApp();

  @override
  State<_PreviewApp> createState() => _PreviewAppState();
}

class _PreviewAppState extends State<_PreviewApp> {
  Locale _locale = const Locale('pt');
  int _scenario = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: _locale,
      localizationsDelegates: const [
        Lt.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('pt')],
      theme: ThemeData(scaffoldBackgroundColor: AppColors.sokoPaper),
      home: Builder(
        builder: (context) {
          final s = _scenarios[_scenario];
          return Scaffold(
            appBar: AppBar(
              backgroundColor: AppColors.sokoPaper,
              elevation: 0,
              title: const Text(
                'Memory bio — preview',
                style: TextStyle(color: AppColors.sokoInk, fontSize: 16),
              ),
              actions: [
                Center(
                  child: Text(
                    _locale.languageCode.toUpperCase(),
                    style: const TextStyle(color: AppColors.sokoInk),
                  ),
                ),
                Switch(
                  value: _locale.languageCode == 'pt',
                  onChanged: (pt) =>
                      setState(() => _locale = Locale(pt ? 'pt' : 'en')),
                ),
              ],
            ),
            body: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              children: [
                const _Label('No perfil social: card "What you like"'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < _scenarios.length; i++)
                      ChoiceChip(
                        label: Text(_scenarios[i].label),
                        selected: _scenario == i,
                        onSelected: (_) => setState(() => _scenario = i),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (s.note != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      s.note!,
                      style: const TextStyle(
                        color: AppColors.sokoShade3,
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                _WhatYouLikeCard(key: ValueKey(_scenario), scenario: s),
                const SizedBox(height: 32),
                const _Label(
                  'Na página de memories: card elaborado (interativo)',
                ),
                const MemoryTellUsCard(),
                const SizedBox(height: 40),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A faithful mock of the profile's "What you like" section for the given
/// scenario (title → chips → bio → tell-us pill → pending banner).
class _WhatYouLikeCard extends StatelessWidget {
  final _Scenario scenario;
  const _WhatYouLikeCard({super.key, required this.scenario});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isSelf = scenario.isSelf;
    final bio = scenario.bio;
    final hasBio = bio != null && bio.isNotEmpty;
    final pending = scenario.pending;
    final hasPending = isSelf && pending != null && pending.isNotEmpty;
    final title = isSelf ? l10n.profileMemoryTitleSelf : 'A memória de João';

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.sokoInk8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  LucideIcons.brain,
                  size: 18,
                  color: AppColors.sokoInk,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: Pt.b1)),
                if (isSelf)
                  Icon(LucideIcons.chevron_right, size: 18, color: pInk30),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in const [
                  'Cafés tranquilos',
                  'Jazz ao vivo',
                  'Vegetariano',
                  'Mercados',
                ])
                  _FakeChip(c),
              ],
            ),
            if (hasBio) ...[
              const SizedBox(height: 10),
              MemoryBioProse(text: bio),
              if (isSelf) ...[
                const SizedBox(height: 6),
                Text(
                  l10n.memoryBioAutoUpdate,
                  style: Pt.b2.copyWith(color: pInk50, fontSize: 12),
                ),
              ],
            ] else if (isSelf) ...[
              const SizedBox(height: 10),
              Text(
                l10n.memoryBioPlaceholderSelf,
                style: Pt.b2.copyWith(color: pInk50, height: 1.4),
              ),
            ],
            if (isSelf) ...[
              const SizedBox(height: 12),
              _PreviewPill(l10n.memoryTellUsTitle),
            ],
            if (hasPending) ...[
              const SizedBox(height: 12),
              MemoryBioPendingBanner(handle: 'joao', pending: pending),
            ],
          ],
        ),
      ),
    );
  }
}

class _FakeChip extends StatelessWidget {
  final String label;
  const _FakeChip(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6.5),
      decoration: BoxDecoration(
        color: AppColors.sokoPink.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: Pt.b2),
    );
  }
}

/// Mirrors the real self-only "conta-nos sobre ti" pill; taps just flash a
/// snackbar here (in the app it routes to the Memory page).
class _PreviewPill extends StatelessWidget {
  final String label;
  const _PreviewPill(this.label);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.sokoPink.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('→ abriria a página de memories')),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              const Icon(
                LucideIcons.sparkles,
                size: 16,
                color: AppColors.sokoInk,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: Pt.b2.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Icon(LucideIcons.chevron_right, size: 16, color: pInk50),
            ],
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.sokoInk,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
