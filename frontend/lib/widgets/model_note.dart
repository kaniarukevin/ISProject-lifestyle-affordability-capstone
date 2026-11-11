import 'package:flutter/material.dart';

import '../screens/questions_screen.dart';
import '../theme/app_theme.dart';

/// The one-line reminder under every page of figures: estimates from a model, not financial advice, with a link
/// to the page that explains which models and data are behind them.
class ModelNote extends StatelessWidget {
  const ModelNote({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = AppColors.of(context).muted;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Wrap(alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('Estimates, not financial advice. ', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QuestionsScreen())),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('Questions about these numbers',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface, decoration: TextDecoration.underline, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }
}
