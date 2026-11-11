import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';
import 'panel.dart';

/// "Start here" for new users (10 Nov: testers did not know what to do after signing up). Four steps in the order
/// that makes the answers trustworthy; each ticks itself off. It hides when all are done or the user closes it.
class StartHere extends StatefulWidget {
  const StartHere({
    super.key,
    required this.hasStatement,
    required this.sorted,
    required this.checked,
    required this.onAddStatement,
    required this.onSort,
    required this.onBudget,
    required this.onCheck,
  });

  final bool hasStatement, sorted, checked;
  final VoidCallback onAddStatement, onSort, onBudget, onCheck;

  /// Kept per device, not wiped at log out like the cached figures (those keys start with cache_v1_).
  static const seenBudgetKey = 'start_seen_budget';
  static const hiddenKey = 'start_here_hidden';

  @override
  State<StartHere> createState() => _StartHereState();
}

class _StartHereState extends State<StartHere> {
  bool? _hidden;
  bool _seenBudget = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _hidden = p.getBool(StartHere.hiddenKey) ?? false;
        _seenBudget = p.getBool(StartHere.seenBudgetKey) ?? false;
      });
    });
  }

  Future<void> _set(String key) async => (await SharedPreferences.getInstance()).setBool(key, true);

  @override
  Widget build(BuildContext context) {
    final steps = [
      ('Add your M-PESA statement', 'A year of records gives the most accurate answers.', widget.hasStatement,
          widget.onAddStatement),
      ('Sort your payments', 'Say what each name you pay is, so your spending is split the right way.',
          widget.sorted, widget.onSort),
      ('Look at your budget', 'A plan for this month, built from how you actually spend.', _seenBudget, () {
        _set(StartHere.seenBudgetKey);
        setState(() => _seenBudget = true);
        widget.onBudget();
      }),
      ('Try "Can I afford it?"', 'Check a purchase, a loan or a move before you commit.', widget.checked, widget.onCheck),
    ];
    final done = steps.where((s) => s.$3).length;
    if (_hidden != false || done == steps.length) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final next = steps.indexWhere((s) => !s.$3);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('Start here', style: theme.textTheme.titleLarge)),
            Text('$done of ${steps.length} done', style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
            IconButton(
              tooltip: 'Hide this',
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: () {
                _set(StartHere.hiddenKey);
                setState(() => _hidden = true);
              },
            ),
          ]),
          Text('Tosha reads your M-PESA. It shows how your money is doing, plans your budget, and checks a big '
              'decision before you make it.',
              style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
          const SizedBox(height: 12),
          for (var i = 0; i < steps.length; i++)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: steps[i].$3 ? null : steps[i].$4,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(steps[i].$3 ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      color: steps[i].$3 ? theme.colorScheme.onSurface : c.muted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(steps[i].$1,
                          style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: i == next ? FontWeight.w700 : FontWeight.w500,
                              decoration: steps[i].$3 ? TextDecoration.lineThrough : null,
                              color: steps[i].$3 ? c.muted : null)),
                      if (!steps[i].$3) Text(steps[i].$2, style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
                    ]),
                  ),
                  if (i == next)
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: c.lime, foregroundColor: c.onLime),
                      onPressed: steps[i].$4,
                      child: const Text('Go'),
                    ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}
