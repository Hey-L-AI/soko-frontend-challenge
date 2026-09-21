import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heyl_app/shared/widgets/soko_cta_button.dart';

import '../../helpers/large_font_harness.dart';

// PROD-2907 — regression guard: `SokoCtaButton` (fixed 44px height) must not
// clip or overflow its label at the app's max OS font scale (1.3×). In
// full-width (`expand`) mode a `Flexible` + `FittedBox(scaleDown)` auto-shrinks
// an over-long label to one line inside the pill, so even a pathologically long
// string (or Flutter's deliberately wide test font) does not overflow. In
// content-hugging (`expand: false`) mode the button sizes to the label's
// intrinsic width — callers keep those labels short — so it is tested with a
// realistic label at a comfortable width. Pumped at 1.3×; asserts no RenderFlex
// overflow AND the label still renders.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Deliberately longer than any real CTA label so the guard also survives
  // Flutter's wide test font + long locales at 1.3×.
  const veryLong = 'Eliminar a minha conta permanentemente';

  Future<void> expectNoOverflow(
    WidgetTester tester,
    Widget button,
    String label, {
    double width = 360,
  }) async {
    await tester.pumpWidget(largeFontHarness(button, width: width));
    await tester.pumpAndSettle();
    expect(find.text(label), findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  testWidgets('short label, expand:true (unchanged appearance)', (
    tester,
  ) async {
    await expectNoOverflow(
      tester,
      SokoCtaButton(label: 'OK', onPressed: () {}),
      'OK',
    );
  });

  testWidgets('very long label auto-shrinks to fit, expand:true, narrow', (
    tester,
  ) async {
    await expectNoOverflow(
      tester,
      SokoCtaButton(label: veryLong, onPressed: () {}),
      veryLong,
      width: 300,
    );
  });

  testWidgets('very long label with a leading icon, expand:true, narrow', (
    tester,
  ) async {
    await expectNoOverflow(
      tester,
      SokoCtaButton(
        label: veryLong,
        icon: LucideIcons.trash_2,
        variant: SokoCtaVariant.red,
        onPressed: () {},
      ),
      veryLong,
      width: 320,
    );
  });

  testWidgets('very long label, loading state, expand:true', (tester) async {
    // Loading label is present but transparent (opacity 0) behind the spinner;
    // the fixed 44px box + FittedBox must still accommodate it without overflow.
    await tester.pumpWidget(
      largeFontHarness(
        SokoCtaButton(label: veryLong, loading: true, onPressed: () {}),
        width: 300,
      ),
    );
    await tester
        .pump(); // don't settle — CircularProgressIndicator never settles
    expect(tester.takeException(), isNull);
  });

  testWidgets('very long label, disabled (onPressed null), expand:true', (
    tester,
  ) async {
    await expectNoOverflow(
      tester,
      const SokoCtaButton(label: veryLong, onPressed: null),
      veryLong,
      width: 300,
    );
  });

  testWidgets('realistic label, expand:false (content-hugging)', (
    tester,
  ) async {
    await expectNoOverflow(
      tester,
      SokoCtaButton(label: 'Guardar', expand: false, onPressed: () {}),
      'Guardar',
    );
  });
}
