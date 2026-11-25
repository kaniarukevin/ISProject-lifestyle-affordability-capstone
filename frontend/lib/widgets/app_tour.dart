import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

/// A short walk through the app (25 Nov: testers said setup is staged, but nothing shows them around the app
/// afterwards, and a card that only describes places does not show where to tap). Each step moves the app to the
/// place it talks about, so its button lights up (the lime one) behind the card. Shown once, the first time Home
/// opens on a device; "Take the quick tour" in Questions replays it.
class AppTour {
  /// Kept per device, not wiped at log out (cached figures use cache_v1_ keys).
  static const seenKey = 'app_tour_seen';

  /// Where a step points: a tab index (0-4), [records], or [none] (stay where you are).
  static const none = -1;
  static const records = 99;

  /// Questions asks Home to replay the tour (Home owns the tabs the tour moves between).
  static final replay = ValueNotifier<int>(0);

  static const _steps = <(int, IconData, String, String)>[
    (none, Icons.waving_hand_rounded, 'A quick look around',
        'Tosha has five places, on the dark bar at the bottom of the screen (on the left on a wide screen). '
            'As you go through this tour, the place it talks about lights up in lime. About 30 seconds.'),
    (0, Icons.home_rounded, 'How you\'re doing',
        'You are here now: the lime house button. Your money score out of 100, what it is based on, and any hard '
            'month coming up. Tap "Why this score?" on the score card to see what pushes it up or down.'),
    (1, Icons.verified_user_rounded, 'Can I afford it?',
        'The second button, now lit up. Try a decision before you make it: a phone on credit, moving house, a loan, '
            'school fees. Pick one, fill in the amount, and Tosha shows your months before and after.'),
    (2, Icons.bar_chart_rounded, 'Budget and the next 3 months',
        'The third button. This month\'s budget line by line, how much you can spend a day, and what the next '
            'three months look like.'),
    (3, Icons.calendar_month_rounded, 'Bills, debts and goals',
        'The fourth button. Add rent, school fees, loans and what you are saving for. Anything here is set aside '
            'before everyday money.'),
    (records, Icons.receipt_long_rounded, 'Your records',
        'Opened from the receipt button at the top right of Home. Your payments month by month: add a statement, '
            'sort what Tosha was not sure about, and tell it who you pay. The more is sorted, the better every answer.'),
    (4, Icons.person_rounded, 'You',
        'The last button. Your household and income, money outside M-PESA, privacy, and signing out.'),
    (0, Icons.help_outline_rounded, 'Stuck?',
        'Back on Home. The ? at the top of every page answers what the numbers mean and why Tosha asks what it '
            'asks. You can replay this tour from there.'),
  ];

  /// Shows the tour if it has never been seen on this device.
  static Future<void> showIfNew(BuildContext context, {ValueChanged<int>? onStep}) async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool(seenKey) ?? false) return;
    if (!context.mounted) return;
    await show(context, onStep: onStep);
  }

  /// onStep moves the app to each step's place (a tab index, [records] or [none]).
  static Future<void> show(BuildContext context, {ValueChanged<int>? onStep}) async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.25),   // light, so the page and the lit button stay visible
      pageBuilder: (_, _, _) => _TourCard(onStep: onStep),
    );
    final p = await SharedPreferences.getInstance();
    await p.setBool(seenKey, true);
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

  void _to(int i) {
    setState(() => _i = i);
    final target = AppTour._steps[i].$1;
    if (target != AppTour.none) widget.onStep?.call(target);
  }

  void _close() {
    widget.onStep?.call(0);   // finish on Home
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final (_, icon, title, text) = AppTour._steps[_i];
    final last = _i == AppTour._steps.length - 1;
    // At the top of the screen, so the bottom bar (and its lit button) stays in view.
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Material(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(24),
              elevation: 8,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    CircleAvatar(radius: 20, backgroundColor: c.lime, child: Icon(icon, color: c.onLime, size: 20)),
                    const SizedBox(width: 12),
                    Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
                  ]),
                  const SizedBox(height: 10),
                  Text(text, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 6),
                  Row(children: [
                    Text('${_i + 1} of ${AppTour._steps.length}',
                        style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
                    const Spacer(),
                    if (!last) TextButton(onPressed: _close, child: const Text('Skip')),
                    if (_i > 0) TextButton(onPressed: () => _to(_i - 1), child: const Text('Back')),
                    FilledButton(
                      onPressed: last ? _close : () => _to(_i + 1),
                      child: Text(last ? 'Done' : 'Next'),
                    ),
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
