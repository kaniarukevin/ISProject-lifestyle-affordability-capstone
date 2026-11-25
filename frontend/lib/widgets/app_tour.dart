import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

/// A short walk through the app (25 Nov: testers said setup is staged, but nothing shows them around the app
/// afterwards). Shown once, the first time Home opens on a device; "Take the tour" in Questions replays it.
class AppTour {
  /// Kept per device, not wiped at log out (cached figures use cache_v1_ keys).
  static const seenKey = 'app_tour_seen';

  static const _steps = <(IconData, String, String)>[
    (Icons.waving_hand_rounded, 'A quick look around',
        'Five places at the bottom of the screen (on the left on a wide screen). This takes about 30 seconds.'),
    (Icons.home_rounded, 'How you\'re doing',
        'Your money score out of 100, what it is based on, and any hard month coming up. Tap "Why this score?" to '
            'see what pushes it up or down.'),
    (Icons.verified_user_rounded, 'Can I afford it?',
        'Try a decision before you make it: a phone on credit, moving house, a loan, school fees. Tosha shows your '
            'months before and after, and what to change if it does not fit.'),
    (Icons.bar_chart_rounded, 'Budget and the next 3 months',
        'This month\'s budget, how much you can spend a day, and what the next three months look like.'),
    (Icons.calendar_month_rounded, 'Bills, debts and goals',
        'Rent, school fees, loans and what you are saving for. Anything here is set aside before everyday money.'),
    (Icons.receipt_long_rounded, 'Your records',
        'The button at the top right. Your payments: add a statement, sort what Tosha was not sure about, and tell it '
            'who you pay. The more is sorted, the better every answer.'),
    (Icons.help_outline_rounded, 'Stuck?',
        'The ? at the top of every page answers what the numbers mean and why Tosha asks what it asks. You can '
            'replay this tour from there.'),
  ];

  /// Shows the tour if it has never been seen on this device.
  static Future<void> showIfNew(BuildContext context) async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool(seenKey) ?? false) return;
    if (!context.mounted) return;
    await show(context);
  }

  static Future<void> show(BuildContext context) async {
    await showDialog<void>(context: context, builder: (_) => const _TourDialog());
    final p = await SharedPreferences.getInstance();
    await p.setBool(seenKey, true);
  }
}

class _TourDialog extends StatefulWidget {
  const _TourDialog();

  @override
  State<_TourDialog> createState() => _TourDialogState();
}

class _TourDialogState extends State<_TourDialog> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final (icon, title, text) = AppTour._steps[_i];
    final last = _i == AppTour._steps.length - 1;
    return AlertDialog(
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(radius: 24, backgroundColor: c.lime, child: Icon(icon, color: c.onLime)),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(text, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          Text('${_i + 1} of ${AppTour._steps.length}', style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
        ]),
      ),
      actions: [
        if (!last) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Skip')),
        if (_i > 0) TextButton(onPressed: () => setState(() => _i--), child: const Text('Back')),
        FilledButton(
          onPressed: last ? () => Navigator.pop(context) : () => setState(() => _i++),
          child: Text(last ? 'Done' : 'Next'),
        ),
      ],
    );
  }
}
