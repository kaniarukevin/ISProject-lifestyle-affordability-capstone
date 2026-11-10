import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/panel.dart';

/// "About these numbers": which models make Tosha's figures, what they learned from, and what they cannot do.
/// Opened from You and from the note under every page of figures. The figures match backend/model_register.py.
class AboutNumbersScreen extends StatelessWidget {
  const AboutNumbersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: AppColors.of(context).muted);
    const gap = SizedBox(height: 16);
    return Scaffold(
      appBar: AppBar(title: const Text('About these numbers')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                Panel(
                  color: AppColors.of(context).warnBg,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Guidance, not financial advice', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text(
                      'Tosha\'s scores, budgets and forecasts are estimates from statistical models. They can be wrong, '
                      'and they only know what is in your records. Tosha is a student research project, not a licensed '
                      'financial adviser. Before a big decision, such as a loan, a move or a large purchase, check the real '
                      'terms with the lender or seller and, if you can, talk to a qualified adviser.',
                      style: theme.textTheme.bodyLarge,
                    ),
                  ]),
                ),
                gap,
                Text('What each number comes from', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                const _Model(
                  title: 'How you\'re doing (doing fine, stretched, struggling)',
                  text: 'A Random Forest model reads your recent months. On test households it agreed with the expected '
                      'state 80% of the time. When much of your spending is not sorted yet, a second model that uses only '
                      'totals from your statement takes over.',
                ),
                const _Model(
                  title: 'Affordability score (0 to 100)',
                  text: 'Gradient-boosting models give the chance your months look like doing fine or stretched, turned '
                      'into a score from 0 to 100. They are built so that a bigger cost never raises your score. "Why this score?" shows how '
                      'each part of your figures moved it.',
                ),
                const _Model(
                  title: 'Budget',
                  text: 'Bills, debts and at least 10% savings come first. The rest is shared across your categories by a '
                      'model of how stable households spend, moved towards how you actually spend as your own months '
                      'come in.',
                ),
                const _Model(
                  title: 'Forecast',
                  text: 'A model predicts this month and the next two from your own usual spending, including school-fee '
                      'months and December. The shaded band is the likely range: real months land inside it about 8 '
                      'times in 10, so it is not a promise.',
                ),
                const _Model(
                  title: 'Sorting your payments',
                  text: 'A list of Kenyan businesses and simple rules suggest what each payee is; your own choices always '
                      'win.',
                ),
                gap,
                Text('What the models learned from', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  'The Kenya Integrated Household Budget Survey 2015/16 (21,773 households) for how Kenyan households '
                  'spend, and simulated households built from it for month-by-month patterns. The models have not yet '
                  'been checked on many real households, so treat their answers as a careful second opinion.',
                  style: theme.textTheme.bodyLarge,
                ),
                gap,
                Text('Known limits', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                for (final l in const [
                  'Money that never passes through M-PESA is missing unless you add it.',
                  'The score looks mostly at your last 3 to 6 months; your year\'s track record is shown beside it.',
                  'The score is a fair warning for next month, and weaker after that. It shows where you are now; '
                      '"Can I afford it?" is how Tosha looks further ahead, by trying a change on your own months.',
                  'Savings goals are not part of the score; each check says what it does to them.',
                  'A few months of records give rougher answers than a full year.',
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Padding(padding: EdgeInsets.only(top: 2, right: 10), child: Icon(Icons.remove_rounded, size: 18)),
                      Expanded(child: Text(l, style: theme.textTheme.bodyLarge)),
                    ]),
                  ),
                gap,
                Text('Built by Kevin Kaniaru, Strathmore University, as a final-year project.', style: muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Model extends StatelessWidget {
  const _Model({required this.title, required this.text});
  final String title, text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(text, style: theme.textTheme.bodyMedium),
      ]),
    );
  }
}
