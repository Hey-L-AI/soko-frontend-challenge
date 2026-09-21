# Discovery Feature

The home page (PROD-1511 epic, scaffold = PROD-1526). Canonical at `/` for all viewers since PROD-1736 (the global app-shell cutover).

## Source-of-truth design doc

→ [`docs/designs/prod-1526-discovery-scaffold.md`](../../../../docs/designs/prod-1526-discovery-scaffold.md)

That doc explains: the strategy, route, bottom-nav item mapping, and desktop interim. **Read it before adding to this folder.**

For the navigation behaviour shipped to users, see [`docs/ui/app-navigation.md`](../../../../docs/ui/app-navigation.md) — the "Discovery Shell" section is kept in sync.

## Code conventions for this folder

These rules apply to every ticket landing inside `features/discovery/`:

### Fork-on-doubt

When introducing a widget that touches the new design language, **default to forking** rather than reusing existing widgets. Reuse is OK for pure design-system primitives (typography, buttons, card chrome, `AppColors.*`, layout utilities). Goal: the existing app must not regress while the new page is under construction.

### Desktop is interim

There are no desktop designs yet for Discovery. The mobile component tree is rendered inside a max-width container on desktop. Mark every desktop compromise with `// TODO(desktop-redesign):` so it's greppable when designs land.

### Localization

All user-facing strings via `intl_*.arb` (`lib/l10n/`). Use the `discovery*` prefix for new keys to keep them grouped (e.g. `discoveryNavSearch`, `discoveryCreateStubTitle`). Reuse existing keys when the value is identical (e.g. `navHome` for the Home label).

### Analytics

Discovery should fire its own page-open / interaction events so engagement is trackable separately from the old home. (Wiring lands in the section tickets, not the scaffold.)

## Folder layout

```
discovery/
├── screens/
│   └── discovery_screen.dart         # The empty page shell — sections land here
└── widgets/
    ├── discovery_shell.dart          # Canonical route shell wrapper (post-PROD-1736)
    ├── discovery_bottom_nav.dart     # 5-item bottom nav
    └── create_menu_sheet.dart        # Create-menu bottom sheet (PROD-1929)
```

## Downstream tickets

Sections will be filled in by:

- [PROD-1517](https://linear.app/heyl/issue/PROD-1517) — Header & Chat card / Barra
- [PROD-1518](https://linear.app/heyl/issue/PROD-1518) — Daily Drop & Weekly Bundle
- [PROD-1521](https://linear.app/heyl/issue/PROD-1521) — History grid
- [PROD-1522](https://linear.app/heyl/issue/PROD-1522) — Shelves (Tuas, Perto de ti, Mais seguidas, Editor Picks, Verificados, Recomendado)

All blocked by this scaffold ticket (PROD-1526).
