import 'package:flutter/material.dart';

import '../../../shared/widgets/scallop_divider.dart';

/// Scalloped section divider rendered between the Discovery chat card and
/// the action bar. Thin wrapper around [ScallopDivider] (defaulted to the
/// canonical Soko Ink tile from Figma `3932:1986`).
///
/// The discovery shell now caps content at 480 px on desktop, so the
/// divider naturally shares that width with the chat ask card and the
/// action bar — no per-component cap needed here.
class DiscoverySectionDivider extends StatelessWidget {
  const DiscoverySectionDivider({super.key});

  @override
  Widget build(BuildContext context) => const ScallopDivider();
}
