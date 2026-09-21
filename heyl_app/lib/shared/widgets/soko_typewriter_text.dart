import 'package:flutter/material.dart';

import 'soko_chat_timings.dart';

/// Reveals [text] one grapheme at a time (typewriter), used for freshly
/// delivered Soko lines so the chat "types" rather than snapping in whole.
/// Falls back to the full string instantly under reduce-motion.
///
/// Shared by the onboarding transcript and the main chat. [onComplete] fires
/// once when the type-out finishes (or immediately, next frame, under
/// reduce-motion) — the main chat uses it to reveal a reply's cards only after
/// its text has typed out.
class SokoTypewriterText extends StatefulWidget {
  const SokoTypewriterText({
    super.key,
    required this.text,
    required this.style,
    this.onComplete,
  });

  final String text;
  final TextStyle style;
  final VoidCallback? onComplete;

  @override
  State<SokoTypewriterText> createState() => _SokoTypewriterTextState();
}

class _SokoTypewriterTextState extends State<SokoTypewriterText>
    with SingleTickerProviderStateMixin {
  late final int _graphemeCount = widget.text.characters.length;
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: sokoTypewriterDuration(widget.text),
  );
  late final Animation<int> _revealed = StepTween(
    begin: 0,
    end: _graphemeCount,
  ).animate(_controller);

  bool _completed = false;
  bool _reduceMotionHandled = false;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) _finish();
    });
    _controller.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect the OS "reduce motion" setting (and the widget-test harness, which
    // sets disableAnimations): show the whole line at once and complete now,
    // rather than after the (silent) full type-out duration.
    if (!_reduceMotionHandled && MediaQuery.of(context).disableAnimations) {
      _reduceMotionHandled = true;
      _controller.stop();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _finish();
      });
    }
  }

  void _finish() {
    if (_completed) return;
    _completed = true;
    widget.onComplete?.call();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) {
      return Text(widget.text, style: widget.style);
    }
    return AnimatedBuilder(
      animation: _revealed,
      builder: (context, _) => Text(
        // Grapheme-safe slice so emoji / accented clusters never split.
        widget.text.characters.take(_revealed.value).toString(),
        style: widget.style,
      ),
    );
  }
}
