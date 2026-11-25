import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

/// A short walk through the app (25 Nov testers: nothing showed them around, and describing a place did not show
/// where to tap). Each step opens its place and makes the button to tap pulse (see [TourGlow]). Shown once per
/// device, the first time Home opens; "Take the quick tour" in Questions replays it.
class AppTour {
  static const seenKey = 'app_tour_seen';

  /// Highlight targets besides the five tab indexes (0-4).
  static const records = 99;
  static const help = 98;
  static const none = -1;

  /// The button the current step points at; [TourGlow] widgets listen to it.
  static final highlight = ValueNotifier<int?>(null);

  /// Questions asks Home to replay the tour (Home owns the tabs the tour moves between).
  static final replay = ValueNotifier<int>(0);

  // (tab to open, button to highlight, title, text). Short on purpose: testers skim.
  static const _steps = <(int, int, String, String)>[
    (none, none, 'Quick tour', 'Five places on the dark bar. Watch for the glowing button. 30 seconds.'),
    (0, 0, 'Home', 'Your money score and what\'s coming up.'),
    (1, 1, 'Can I afford it?', 'Test a phone, a loan or a move before you commit.'),
    (2, 2, 'Budget', 'This month\'s budget and the next 3 months.'),
    (3, 3, 'Bills and goals', 'Rent, fees, loans and savings goals. Set aside first.'),
    (0, records, 'Your records', 'Tap here for your payments. Add a statement or sort them.'),
    (4, 4, 'You', 'Your household, income and privacy.'),
    (0, help, 'Stuck?', 'Tap ? on any page for answers, or to replay this tour.'),
  ];

  static Future<void> showIfNew(BuildContext context, {ValueChanged<int>? onStep}) async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool(seenKey) ?? false) return;
    if (!context.mounted) return;
    await show(context, onStep: onStep);
  }

  /// onStep opens each step's tab.
  static Future<void> show(BuildContext context, {ValueChanged<int>? onStep}) async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,   // nothing dimmed, so the glowing button is easy to see
      pageBuilder: (_, _, _) => _TourCard(onStep: onStep),
    );
    highlight.value = null;
    final p = await SharedPreferences.getInstance();
    await p.setBool(seenKey, true);
  }
}

/// Wraps a button the tour can point at: while the tour's current step targets [target], a lime ring pulses
/// around it with a small "Tap here" label.
class TourGlow extends StatefulWidget {
  const TourGlow({super.key, required this.target, required this.child, this.labelAbove = false});
  final int target;
  final Widget child;
  final bool labelAbove;   // nav bar at the bottom: label above; buttons at the top: label below

  @override
  State<TourGlow> createState() => _TourGlowState();
}

class _TourGlowState extends State<TourGlow> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ValueListenableBuilder<int?>(
      valueListenable: AppTour.highlight,
      child: widget.child,
      builder: (context, on, child) {
        if (on != widget.target) return child!;
        final label = Positioned(
          top: widget.labelAbove ? -30 : null,
          bottom: widget.labelAbove ? null : -30,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: c.lime, borderRadius: BorderRadius.circular(10)),
              child: Text('Tap here', style: TextStyle(color: c.onLime, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ),
        );
        return Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (_, inner) => DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: c.lime, blurRadius: 6 + 10 * _pulse.value, spreadRadius: 2 + 4 * _pulse.value)],
              ),
              child: inner,
            ),
            child: child,
          ),
          label,
        ]);
      },
    );
  }
}

class _TourCard extends StatefulWidget {
  const _TourCard({this.onStep});
  final ValueChanged<int>? onStep;

  @override
  State<_TourCard> createState() => _TourCardState();
}

class _TourCardState extends State<_TourCard> {
  int _i = 0;

  @override
  void initState() {
    super.initState();
    AppTour.highlight.value = AppTour._steps[0].$2;
  }

  void _to(int i) {
    setState(() => _i = i);
    final (tab, target, _, _) = AppTour._steps[i];
    if (tab != AppTour.none) widget.onStep?.call(tab);
    AppTour.highlight.value = target;
  }

  void _close() {
    AppTour.highlight.value = null;
    widget.onStep?.call(0);   // finish on Home
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final (_, _, title, text) = AppTour._steps[_i];
    final last = _i == AppTour._steps.length - 1;
    // In the middle of the screen: clear of the bar at the bottom and the buttons at the top.
    return SafeArea(
      child: Align(
        alignment: const Alignment(0, -0.15),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Material(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(22),
              elevation: 10,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text(text, style: theme.textTheme.bodyLarge),
                  Row(children: [
                    Text('${_i + 1}/${AppTour._steps.length}',
                        style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
                    const Spacer(),
                    if (!last) TextButton(onPressed: _close, child: const Text('Skip')),
                    if (_i > 0) TextButton(onPressed: () => _to(_i - 1), child: const Text('Back')),
                    FilledButton(onPressed: last ? _close : () => _to(_i + 1), child: Text(last ? 'Done' : 'Next')),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
