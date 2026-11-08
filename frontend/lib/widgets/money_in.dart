import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'format.dart';

double? _amount(String text) {
  final v = double.tryParse(text.replaceAll(',', '').trim());
  return v == null || !v.isFinite || v < 0 || v > 100000000 ? null : v;
}

/// "This month I really had…": the user's own figure for one month's money in. Shown with a way back to what
/// Tosha worked out.
Future<void> editMonthIncome(BuildContext context, int year, int month, num current, {bool setByYou = false}) async {
  final api = context.read<AppState>().api;
  final messenger = ScaffoldMessenger.of(context);
  final ctl = TextEditingController(text: current.round().toString());
  String? problem;
  final result = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final c = AppColors.of(ctx);
      return StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(24, 4, 24, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Money in, ${monthLong[month - 1]} $year', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text('Tosha sees only M-PESA. If more came in that month (an allowance paid to your bank, cash, a '
                'bonus), put the real total here. It changes this month only.', style: TextStyle(color: c.muted)),
            const SizedBox(height: 16),
            TextField(
              controller: ctl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'All the money that came in', prefixText: 'KES ', errorText: problem),
            ),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.lime, foregroundColor: c.onLime),
              onPressed: () {
                final v = _amount(ctl.text);
                if (v == null) {
                  setSheet(() => problem = 'Enter an amount in shillings.');
                  return;
                }
                Navigator.pop(ctx, v);
              },
              child: const Text('Save'),
            ),
            if (setByYou)
              TextButton(onPressed: () => Navigator.pop(ctx, 'clear'), child: const Text('Go back to what Tosha worked out')),
          ]),
        ),
      );
    },
  );
  try {
    if (result is double) {
      await api.setMonthIncome(year, month, result);
      messenger.showSnackBar(SnackBar(content: Text('${monthLong[month - 1]} now uses ${kesAmount(result)}')));
    } else if (result == 'clear') {
      await api.clearMonthIncome(year, month);
      messenger.showSnackBar(const SnackBar(content: Text('Back to what Tosha worked out')));
    }
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

/// Money that never touches M-PESA: roughly how much comes in and how much is spent by card or cash each month.
Future<bool> editOutsideMoney(BuildContext context, {num? income, num? spending}) async {
  final api = context.read<AppState>().api;
  final messenger = ScaffoldMessenger.of(context);
  final inCtl = TextEditingController(text: income == null || income == 0 ? '' : income.round().toString());
  final outCtl = TextEditingController(text: spending == null || spending == 0 ? '' : spending.round().toString());
  String? problem;
  final saved = await showModalBottomSheet<List<double>>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final c = AppColors.of(ctx);
      return StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(24, 4, 24, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Money outside M-PESA', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text('Rough monthly amounts are fine. Tosha adds them to every month your statement covers, marked as '
                'an estimate.', style: TextStyle(color: c.muted)),
            const SizedBox(height: 16),
            TextField(
              controller: inCtl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Comes in outside M-PESA, a month', prefixText: 'KES ',
                  helperText: 'For example an allowance paid to your bank'),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: outCtl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                  labelText: 'Spent by card or cash, a month', prefixText: 'KES ', errorText: problem,
                  helperText: 'So the extra money is not counted as if you saved it all'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.lime, foregroundColor: c.onLime),
              onPressed: () {
                final a = inCtl.text.trim().isEmpty ? 0.0 : _amount(inCtl.text);
                final b = outCtl.text.trim().isEmpty ? 0.0 : _amount(outCtl.text);
                if (a == null || b == null) {
                  setSheet(() => problem = 'Enter amounts in shillings.');
                  return;
                }
                Navigator.pop(ctx, [a, b]);
              },
              child: const Text('Save'),
            ),
          ]),
        ),
      );
    },
  );
  if (saved == null) return false;
  try {
    await api.setOutsideMoney(saved[0], saved[1]);
    messenger.showSnackBar(const SnackBar(content: Text('Saved. Your months now include it.')));
    return true;
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return false;
  }
}
